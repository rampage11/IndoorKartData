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
    // method добавлен чтобы потребитель мог различить ответ на `GetLastRaceId`
    // от ответов на `SubscribeRace`/`UnsubscribeRace` — SignalR 2.x возвращает
    // результат вызова через I/R envelope без указания метода, поэтому ведём
    // маппинг id→method внутри клиента.
    var onInvocationResult: (@Sendable (_ id: String, _ method: String?, _ result: AnyCodable?, _ error: String?) -> Void)?
    var onStateChange: (@Sendable (_ state: String, _ isConnected: Bool) -> Void)?

    // MARK: - State

    private let config: Config
    private var session: URLSession!
    private let logger = Logger(subsystem: "com.indoorkartdata.app", category: "SignalRClient")

    private var ws: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionToken: String?
    // Ждём пока сервер завершит WS upgrade прежде чем звать /signalr/start.
    private var openContinuation: CheckedContinuation<Void, Error>?

    private var nextInvokeID: Int = 1
    private let invokeLock = NSLock()
    // id → method name; нужен чтобы при приходе {I, R} понять что это был за вызов.
    // Доступ строго под invokeLock.
    private var pendingInvocations: [Int: String] = [:]

    // Timestamp последнего входящего WS-сообщения (включая keep-alive {}).
    // Используется наружным watchdog'ом чтобы детектить "тихо повисшее" соединение,
    // когда URLSessionWebSocketTask не выдал ни error ни didCloseWith.
    private let lastMessageLock = NSLock()
    private var _lastMessageAt: Date?
    var lastMessageAt: Date? {
        lastMessageLock.lock(); defer { lastMessageLock.unlock() }
        return _lastMessageAt
    }
    private func touchLastMessage() {
        lastMessageLock.lock()
        _lastMessageAt = Date()
        lastMessageLock.unlock()
    }

    private(set) var isConnected: Bool = false {
        didSet { onStateChange?(isConnected ? "connected" : "disconnected", isConnected) }
    }

    override init() {
        self.config = Config(baseURL: URL(string: "about:blank")!, hub: "")
        super.init()
    }

    init(config: Config) {
        self.config = config
        super.init()
        let configuration = URLSessionConfiguration.default
        // В фоне iOS склонен тихо душить сокет; НЕ ждём восстановления сети на уровне
        // URLSession — пусть падает быстро, watchdog в TimingClient поднимет заново.
        configuration.waitsForConnectivity = false
        // Таймауты по умолчанию 60/60; снижаем чтобы negotiate/start не висели на мёртвой сети
        // пока записывается заезд.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
        // Ждём пока сервер завершит WS handshake (urlSession:webSocketTask:didOpenWithProtocol:).
        // Без этого /signalr/start приходит до того как токен привязан к WS и возвращает 400.
        try await waitForOpen()
        startReceiveLoop()

        onStateChange?("starting", false)
        try await start(token: negotiate.ConnectionToken)

        isConnected = true
    }

    private func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.openContinuation = cont
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        connectionToken = nil
        isConnected = false
        invokeLock.lock()
        pendingInvocations.removeAll()
        invokeLock.unlock()
        lastMessageLock.lock()
        _lastMessageAt = nil
        lastMessageLock.unlock()
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
            pendingInvocations[v] = method
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
        comps.percentEncodedQuery = Self.encodeQuery([
            "transport": "webSockets",
            "clientProtocol": config.clientProtocol,
            "connectionToken": token,
            "connectionData": connectionDataJSON(),
            "_": String(Int(Date().timeIntervalSince1970 * 1000))
        ])
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
        // Руками формируем percentEncodedQuery — URLQueryItem по умолчанию
        // не эскейпит '+' и '/', а SignalR connectionToken содержит именно
        // эти символы (base64). Сервер интерпретирует '+' как пробел и
        // возвращает невалидный ответ при WS handshake.
        comps.percentEncodedQuery = Self.encodeQuery([
            "transport": "webSockets",
            "clientProtocol": config.clientProtocol,
            "connectionToken": token,
            "connectionData": connectionDataJSON(),
            "tid": String(Int.random(in: 0...10))
        ])
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
        // Транзиентные ошибки receive (например, кратковременные ошибки EINTR при
        // переключении сетей на iOS) не должны мгновенно убивать сокет: в прошлом
        // мы наблюдали что одна осечка приёма уходила в silent exit и TimingClient
        // не замечал потери до истечения 90-секундного WS-watchdog'а. Разрешаем
        // пару подряд идущих ошибок прежде чем помечать клиент disconnected.
        var consecutiveErrors = 0
        while !Task.isCancelled {
            guard let ws else { return }
            do {
                let message = try await ws.receive()
                consecutiveErrors = 0
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
                consecutiveErrors += 1
                // Если сокет уже закрыт делегатом (didCloseWith/didCompleteWithError),
                // ws.state != .running — тогда повторные receive будут бесполезны,
                // выходим сразу чтобы watchdog поднял заново.
                let stateRunning = ws.state == .running
                logger.error("WS receive error (#\(consecutiveErrors, privacy: .public), state=\(ws.state.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                if !stateRunning || consecutiveErrors >= 2 {
                    await MainActor.run { [weak self] in
                        self?.isConnected = false
                    }
                    return
                }
                // Небольшая пауза перед повторной попыткой — не крутим в tight loop'е.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        // ЛЮБОЕ сообщение (включая keep-alive {}) обновляет lastMessageAt —
        // watchdog в TimingClient опирается на это чтобы детектить мёртвый WS.
        touchLastMessage()
        // Пустой keep-alive {} валиден и регулярно прилетает — просто ничего не делаем.
        guard let data = text.data(using: .utf8) else { return }
        guard let decoded = try? JSONDecoder().decode(SignalRIncoming.self, from: data) else {
            logger.debug("WS: non-decodable frame \(text, privacy: .public)")
            return
        }

        if let id = decoded.I {
            // Поднимаем method name из таблицы ожидающих вызовов.
            // Для .int id, который SignalR echo-ит обратно как string — приводим.
            let intID: Int? = {
                switch id {
                case .int(let i): return i
                case .string(let s): return Int(s)
                }
            }()
            var method: String?
            if let intID {
                invokeLock.lock()
                method = pendingInvocations.removeValue(forKey: intID)
                invokeLock.unlock()
            }
            onInvocationResult?(id.stringValue, method, decoded.R, decoded.E)
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

    // Процент-кодируем значения RFC 3986-way: включая '+' и '/' которые URLQueryItem
    // по умолчанию оставляет литеральными. SignalR connectionToken это base64 с '+' и '/',
    // сервер без эскейпа интерпретирует '+' как пробел.
    static func encodeQuery(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+/=&?#")
        return params
            .map { (k, v) -> String in
                let kEnc = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let vEnc = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(kEnc)=\(vEnc)"
            }
            .joined(separator: "&")
    }
}

extension SignalRClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // WS handshake завершён — теперь можно звать /signalr/start.
        if let cont = openContinuation {
            openContinuation = nil
            cont.resume()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let cont = openContinuation {
            openContinuation = nil
            cont.resume(throwing: ClientError.transport(NSError(domain: "SignalR", code: Int(closeCode.rawValue), userInfo: [NSLocalizedDescriptionKey: "WS закрылся до handshake (code \(closeCode.rawValue))"])))
            return
        }
        // Соединение закрылось уже ПОСЛЕ handshake — помечаем клиент как
        // disconnected, чтобы watchdog поднял его заново.
        logger.error("WS closed after handshake, code=\(closeCode.rawValue, privacy: .public)")
        if isConnected {
            isConnected = false
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let cont = openContinuation {
            openContinuation = nil
            if let error {
                cont.resume(throwing: ClientError.transport(error))
            } else {
                cont.resume(throwing: ClientError.transport(NSError(domain: "SignalR", code: -1, userInfo: [NSLocalizedDescriptionKey: "WS task завершилось без ошибки до handshake"])))
            }
            return
        }
        if let error {
            logger.error("WS task failed after handshake: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.error("WS task completed after handshake with no error")
        }
        if isConnected {
            isConnected = false
        }
    }
}
