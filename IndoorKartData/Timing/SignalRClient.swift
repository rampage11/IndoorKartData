import Foundation
import os

// Низкоуровневый клиент SignalR 2.2 поверх URLSessionWebSocketTask.
// Знает только про transport/protocol и hub invocations; про RaceMann-специфику
// ничего не знает — высокий уровень живёт в TimingClient.
final class SignalRClient: NSObject {

    // MARK: - Config

    struct Config {
        let baseURL: URL
        let hub: String
        let clientProtocol: String

        init(baseURL: URL, hub: String, clientProtocol: String = "1.5") {
            self.baseURL = baseURL
            self.hub = hub
            self.clientProtocol = clientProtocol
        }
    }

    // MARK: - Types

    enum ClientError: Error, LocalizedError {
        case badNegotiateResponse
        case webSocketsNotSupported
        case notConnected
        case startFailed(String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .badNegotiateResponse: return "SignalR negotiate: невалидный ответ."
            case .webSocketsNotSupported: return "SignalR negotiate: сервер отключил WebSockets."
            case .notConnected: return "SignalR: нет открытого WS."
            case .startFailed(let s): return "SignalR start: \(s)"
            case .transport(let e): return "SignalR transport: \(e.localizedDescription)"
            }
        }
    }

    // Callbacks: nonisolated — вызываются с receive-луп, подписчик сам хопает на MainActor.
    var onHubCall: (@Sendable (SignalRHubCall) -> Void)?
    var onInvocationResult: (@Sendable (_ id: String, _ result: AnyCodable?, _ error: String?) -> Void)?
    var onStateChange: (@Sendable (_ state: String, _ isConnected: Bool) -> Void)?

    // MARK: - State

    private let config: Config
    private let session: URLSession
    private let logger = Logger(subsystem: "com.indoorkartdata.app", category: "SignalRClient")

    private var ws: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionToken: String?

    private var nextInvokeID: Int = 1
    private let invokeLock = NSLock()

    private(set) var isConnected: Bool = false {
        didSet { onStateChange?(isConnected ? "connected" : "disconnected", isConnected) }
    }

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Public API

    func connect() async throws {
        onStateChange?("negotiating", false)
        let negotiate = try await negotiate()

        guard negotiate.TryWebSockets else {
            throw ClientError.webSocketsNotSupported
        }
        connectionToken = negotiate.ConnectionToken

        onStateChange?("connecting", false)
        try openWebSocket(token: negotiate.ConnectionToken)
        startReceiveLoop()

        onStateChange?("starting", false)
        try await start(token: negotiate.ConnectionToken)

        isConnected = true
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        connectionToken = nil
        isConnected = false
    }

    @discardableResult
    func invoke(method: String, args: [AnyCodable]) async throws -> Int {
        guard let ws, isConnected || ws.state == .running else {
            throw ClientError.notConnected
        }
        let id: Int = {
            invokeLock.lock(); defer { invokeLock.unlock() }
            let v = nextInvokeID
            nextInvokeID += 1
            return v
        }()

        let payload = SignalRInvoke(H: config.hub, M: method, A: args, I: id)
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientError.transport(NSError(domain: "SignalR", code: -1))
        }
        try await ws.send(.string(text))
        return id
    }

    // MARK: - Negotiate

    private func negotiate() async throws -> SignalRNegotiateResponse {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent("signalr/negotiate"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "clientProtocol", value: config.clientProtocol),
            URLQueryItem(name: "connectionData", value: connectionDataJSON()),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.badNegotiateResponse
        }
        do {
            return try JSONDecoder().decode(SignalRNegotiateResponse.self, from: data)
        } catch {
            throw ClientError.badNegotiateResponse
        }
    }

    // MARK: - Start

    private func start(token: String) async throws {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent("signalr/start"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "transport", value: "webSockets"),
            URLQueryItem(name: "clientProtocol", value: config.clientProtocol),
            URLQueryItem(name: "connectionToken", value: token),
            URLQueryItem(name: "connectionData", value: connectionDataJSON()),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.startFailed("HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded = try JSONDecoder().decode(SignalRStartResponse.self, from: data)
        guard decoded.Response == "started" else {
            throw ClientError.startFailed(decoded.Response)
        }
    }

    // MARK: - WebSocket

    private func openWebSocket(token: String) throws {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.transport(NSError(domain: "SignalR", code: -2))
        }
        // https → wss, http → ws
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        default: break
        }
        comps.path = "/signalr/connect"
        comps.queryItems = [
            URLQueryItem(name: "transport", value: "webSockets"),
            URLQueryItem(name: "clientProtocol", value: config.clientProtocol),
            URLQueryItem(name: "connectionToken", value: token),
            URLQueryItem(name: "connectionData", value: connectionDataJSON()),
            URLQueryItem(name: "tid", value: String(Int.random(in: 0...10)))
        ]
        guard let url = comps.url else {
            throw ClientError.transport(NSError(domain: "SignalR", code: -3))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let task = session.webSocketTask(with: req)
        self.ws = task
        task.resume()
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let ws else { return }
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let s):
                    handleIncomingText(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        handleIncomingText(s)
                    }
                @unknown default:
                    break
                }
            } catch {
                logger.error("WS receive error: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.isConnected = false
                }
                return
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        // Пустой keep-alive {} валиден и регулярно прилетает — просто ничего не делаем.
        guard let data = text.data(using: .utf8) else { return }
        guard let decoded = try? JSONDecoder().decode(SignalRIncoming.self, from: data) else {
            logger.debug("WS: non-decodable frame \(text, privacy: .public)")
            return
        }

        if let id = decoded.I {
            onInvocationResult?(id.stringValue, decoded.R, decoded.E)
        }
        if let calls = decoded.M {
            for call in calls {
                onHubCall?(call)
            }
        }
    }

    // MARK: - Helpers

    private func connectionDataJSON() -> String {
        // Руками кодируем, чтобы гарантировать совместимость с .NET SignalR сервером:
        // он парсит именно вид [{"name":"<hub>"}], пробелы недопустимы.
        return "[{\"name\":\"\(config.hub)\"}]"
    }
}
