import Foundation
import Combine
import os

@MainActor
final class TimingClient: ObservableObject {

    static let shared = TimingClient()

    // MARK: - Config

    var baseURL: URL = URL(string: "https://miks.racemann.com")!

    // MARK: - Published state

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionState: String = "disconnected"
    @Published private(set) var currentRaceID: String?
    @Published private(set) var currentFlag: String?
    @Published private(set) var timeToGoMs: Int?

    @Published private(set) var lastLapMs: Int?
    @Published private(set) var bestLapMs: Int?
    @Published private(set) var lapCount: Int?
    @Published private(set) var position: Int?
    @Published private(set) var gapToLeaderMs: Int?

    struct LapEvent: Identifiable {
        let id = UUID()
        let raceTimeMs: Int
        let wallTime: Date
        let lapMs: Int
        let lapNumber: Int
        let position: Int
        let bestLapMs: Int
    }
    @Published private(set) var lapHistory: [LapEvent] = []

    // MARK: - Filter

    // При смене номера карта чистим агрегированный state, но соединение не трогаем —
    // пользователь мог ошибиться номером и исправить его во время заезда.
    var kartNumber: String? {
        didSet {
            if oldValue != kartNumber {
                resetMySelfState()
            }
        }
    }

    // MARK: - Internals

    private var client: SignalRClient?
    private let logger = Logger(subsystem: "com.indoorkartdata.app", category: "TimingClient")

    nonisolated init() {}

    // MARK: - Public API

    func connect() async {
        if client != nil { disconnect() }
        let cfg = SignalRClient.Config(baseURL: baseURL, hub: "racehub")
        let c = SignalRClient(config: cfg)
        self.client = c
        wireCallbacks(c)
        connectionState = "connecting"
        do {
            try await c.connect()
            isConnected = true
            connectionState = "connected"
            // Автоподписка: без этого вызова сервер шлёт только heartbeat.
            // handler lastRaceId вызовет SubscribeRace с правильным ID.
            await fetchCurrentRaceAndSubscribe()
        } catch {
            logger.error("TimingClient connect failed: \(error.localizedDescription, privacy: .public)")
            isConnected = false
            connectionState = "error: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        isConnected = false
        connectionState = "disconnected"
    }

    func fetchCurrentRaceAndSubscribe() async {
        guard let client else { return }
        do {
            _ = try await client.invoke(method: "GetLastRaceId", args: [])
            // На lastRaceId повесим auto-subscribe в onHubCall; здесь ничего больше делать не нужно.
        } catch {
            logger.error("GetLastRaceId failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Wiring

    private func wireCallbacks(_ c: SignalRClient) {
        c.onStateChange = { [weak self] state, connected in
            Task { @MainActor [weak self] in
                self?.connectionState = state
                self?.isConnected = connected
            }
        }
        c.onHubCall = { [weak self] call in
            Task { @MainActor [weak self] in
                self?.handleHubCall(call)
            }
        }
        c.onInvocationResult = { [weak self] id, result, error in
            Task { @MainActor [weak self] in
                self?.logger.debug("Invocation \(id) result=\(String(describing: result?.value), privacy: .public) err=\(error ?? "nil", privacy: .public)")
            }
        }
    }

    private func handleHubCall(_ call: SignalRHubCall) {
        switch call.M {
        case "newCommand":
            guard let arg0 = call.A.first else { return }
            if let envelope = decode(NewCommandEnvelope.self, from: arg0) {
                dispatchNewCommand(envelope)
            }
        case "lastRaceId":
            guard let arg0 = call.A.first else { return }
            if let payload = decode(LastRaceIdPayload.self, from: arg0) {
                currentRaceID = payload.id
                Task { [weak self, raceID = payload.id] in
                    await self?.subscribe(raceID: raceID)
                }
            }
        case "monitorSettings", "allMonitorMessages":
            logger.debug("Hub call \(call.M, privacy: .public) ignored (secondary)")
        default:
            logger.debug("Hub call \(call.M, privacy: .public) unhandled")
        }
    }

    private func dispatchNewCommand(_ env: NewCommandEnvelope) {
        switch env.Method {
        case "hb":
            if let hb = decode(HeartbeatCommand.self, from: env.Command) {
                if let fl = hb.fl { currentFlag = fl }
                if let tg = hb.tg { timeToGoMs = tg }
            }
        case "Comp":
            if let comp = decode(CompetitorCommand.self, from: env.Command) {
                applyCompetitorIfMatches(comp, raceTimeMs: env.Time)
            }
        default:
            break
        }
    }

    private func applyCompetitorIfMatches(_ comp: CompetitorCommand, raceTimeMs: Int) {
        guard let kart = kartNumber, !kart.isEmpty else { return }
        if !isOurKart(comp, kart: kart) { return }

        if let ll = comp.ll { lastLapMs = ll }
        if let bl = comp.bl { bestLapMs = bl }
        if let lc = comp.lc { lapCount = lc }
        if let pos = comp.pos { position = pos }
        if let ld = comp.ld { gapToLeaderMs = ld.Time }

        // Фиксируем в историю только настоящий пассаж круга: ll > 0 и lc > 0,
        // иначе получим фейковый "нулевой круг" из стартового Comp.
        if let ll = comp.ll, ll > 0, let lc = comp.lc, lc > 0 {
            let last = lapHistory.last
            let isDuplicate = last?.lapNumber == lc && last?.lapMs == ll
            if !isDuplicate {
                lapHistory.append(LapEvent(
                    raceTimeMs: raceTimeMs,
                    wallTime: Date(),
                    lapMs: ll,
                    lapNumber: lc,
                    position: comp.pos ?? 0,
                    bestLapMs: comp.bl ?? ll
                ))
            }
        }
    }

    private func isOurKart(_ comp: CompetitorCommand, kart: String) -> Bool {
        let kartTrimmed = kart.trimmingCharacters(in: .whitespaces)
        if comp.rn == kartTrimmed { return true }
        if comp.nn == kartTrimmed { return true }
        // Сервер зачастую зануляет rn/nn до 2 цифр, а пользователь может ввести "6" вместо "06".
        if let rn = comp.rn, Int(rn) != nil, Int(kartTrimmed) == Int(rn) { return true }
        if let nn = comp.nn, Int(nn) != nil, Int(kartTrimmed) == Int(nn) { return true }
        if let fn = comp.fn {
            if fn.caseInsensitiveCompare("KART \(kartTrimmed)") == .orderedSame { return true }
            if let kartNum = Int(kartTrimmed), fn.caseInsensitiveCompare("KART \(kartNum)") == .orderedSame { return true }
        }
        return false
    }

    private func subscribe(raceID: String) async {
        guard let client else { return }
        do {
            _ = try await client.invoke(method: "SubscribeRace", args: [AnyCodable(raceID)])
        } catch {
            logger.error("SubscribeRace failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resetMySelfState() {
        lastLapMs = nil
        bestLapMs = nil
        lapCount = nil
        position = nil
        gapToLeaderMs = nil
        lapHistory = []
    }

    // MARK: - Codable helpers

    private func decode<T: Decodable>(_ type: T.Type, from any: AnyCodable) -> T? {
        do {
            let data = try JSONEncoder().encode(any)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.debug("decode \(String(describing: T.self), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

#if DEBUG
extension TimingClient {
    // Используется автономно (без сети) для верификации парсинга фрагмента newCommand/Comp.
    struct ParsedComp {
        let fn: String?
        let rn: String?
        let nn: String?
        let ll: Int?
        let bl: Int?
        let lc: Int?
        let pos: Int?
        let gapToLeaderMs: Int?
        let raceTimeMs: Int
    }

    static func parseForTests(_ json: String) -> ParsedComp? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let incoming = try? JSONDecoder().decode(SignalRIncoming.self, from: data) else { return nil }
        guard let call = incoming.M?.first(where: { $0.M == "newCommand" }),
              let arg0 = call.A.first else { return nil }

        let argData: Data
        do {
            argData = try JSONEncoder().encode(arg0)
        } catch { return nil }

        guard let env = try? JSONDecoder().decode(NewCommandEnvelope.self, from: argData),
              env.Method == "Comp" else { return nil }

        let cmdData: Data
        do {
            cmdData = try JSONEncoder().encode(env.Command)
        } catch { return nil }

        guard let comp = try? JSONDecoder().decode(CompetitorCommand.self, from: cmdData) else {
            return nil
        }

        return ParsedComp(
            fn: comp.fn,
            rn: comp.rn,
            nn: comp.nn,
            ll: comp.ll,
            bl: comp.bl,
            lc: comp.lc,
            pos: comp.pos,
            gapToLeaderMs: comp.ld?.Time,
            raceTimeMs: env.Time
        )
    }
}
#endif
