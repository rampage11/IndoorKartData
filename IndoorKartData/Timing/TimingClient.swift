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

    // Диагностика: счётчики входящих событий. Помогает различить где застряло.
    @Published private(set) var heartbeatCount: Int = 0
    @Published private(set) var compCount: Int = 0
    @Published private(set) var compMineCount: Int = 0
    @Published private(set) var lastCompKartSeen: String?

    // Отрыв до преследователя (мс) на последнем прохождении отсечки.
    // Публикуется когда следующий карт после нашего пересекает финиш.
    @Published private(set) var chaserGapMs: Int?

    // Pending-состояние для вычисления отрыва: на нашем Comp сохраняем
    // raceTime+pos+lap, при следующем Comp от карта с pos=ourPos+1
    // считаем дельту и чистим pending (one-shot).
    private var pendingOurRaceTimeMs: Int?
    private var pendingOurPos: Int?
    private var pendingOurLap: Int?

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
    private var raceRefreshTask: Task<Void, Never>?
    private var subscribedRaceID: String?

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
            startRaceRefreshLoop()
        } catch {
            logger.error("TimingClient connect failed: \(error.localizedDescription, privacy: .public)")
            isConnected = false
            connectionState = "error: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        raceRefreshTask?.cancel()
        raceRefreshTask = nil
        subscribedRaceID = nil
        client?.disconnect()
        client = nil
        isConnected = false
        connectionState = "disconnected"
    }

    // Маршаллы иногда ресетают сессию прямо во время заезда. Периодически
    // опрашиваем GetLastRaceId — если ID сменился, handler lastRaceId
    // переподписывает нас на новый заезд.
    private func startRaceRefreshLoop() {
        raceRefreshTask?.cancel()
        raceRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.fetchCurrentRaceAndSubscribe()
            }
        }
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
                let newID = payload.id
                if subscribedRaceID == newID {
                    // Тот же заезд — ничего не делаем.
                    return
                }
                let old = subscribedRaceID
                currentRaceID = newID
                // Маршаллы сбросили сессию — старые метки больше не актуальны.
                resetMySelfState()
                Task { [weak self, oldID = old, newID] in
                    if let oldID { await self?.unsubscribe(raceID: oldID) }
                    await self?.subscribe(raceID: newID)
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
            heartbeatCount += 1
            if let hb = decode(HeartbeatCommand.self, from: env.Command) {
                if let fl = hb.fl { currentFlag = fl }
                if let tg = hb.tg { timeToGoMs = tg }
            }
        case "Comp":
            compCount += 1
            if let comp = decode(CompetitorCommand.self, from: env.Command) {
                lastCompKartSeen = comp.rn ?? comp.nn ?? comp.fn
                applyCompetitorIfMatches(comp, raceTimeMs: env.Time)
                // Любой Comp проверяем на статус «преследователь», даже если
                // не наш — именно так и ловится карт позади нас.
                checkChaserPass(comp, raceTimeMs: env.Time)
            }
        default:
            break
        }
    }

    private func checkChaserPass(_ comp: CompetitorCommand, raceTimeMs: Int) {
        guard let ourTime = pendingOurRaceTimeMs,
              let ourPos = pendingOurPos,
              let theirPos = comp.pos,
              theirPos == ourPos + 1,
              let theirLap = comp.lc,
              theirLap >= (pendingOurLap ?? 0) else { return }
        // Санитар: больше минуты назад — явно не "сразу за нами".
        let gap = raceTimeMs - ourTime
        guard gap >= 0, gap < 60_000 else { return }
        chaserGapMs = gap
        pendingOurRaceTimeMs = nil
        pendingOurPos = nil
        pendingOurLap = nil
    }

    private func applyCompetitorIfMatches(_ comp: CompetitorCommand, raceTimeMs: Int) {
        guard let kart = kartNumber, !kart.isEmpty else { return }
        if !isOurKart(comp, kart: kart) { return }
        compMineCount += 1

        // Это наш пассаж — ставим pending для следующего карта (преследователя).
        // Старый chaser gap обнуляем — он относился к предыдущему кругу.
        if let pos = comp.pos, let lc = comp.lc, let ll = comp.ll, ll > 0 {
            pendingOurRaceTimeMs = raceTimeMs
            pendingOurPos = pos
            pendingOurLap = lc
            chaserGapMs = nil
        }

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
        let kartInt = Int(kartTrimmed)
        if let rn = comp.rn, let r = Int(rn), r == kartInt { return true }
        if let nn = comp.nn, let n = Int(nn), n == kartInt { return true }
        if let fn = comp.fn {
            // На MIKS fn выглядит как "KINDER 29" или "KART 14" — префикс
            // модели карта варьируется между парками. Берём последний токен.
            let last = fn.split(separator: " ").last.map(String.init)
            if last == kartTrimmed { return true }
            if let last, let l = Int(last), l == kartInt { return true }
        }
        return false
    }

    private func subscribe(raceID: String) async {
        guard let client else { return }
        do {
            _ = try await client.invoke(method: "SubscribeRace", args: [AnyCodable(raceID)])
            await MainActor.run { self.subscribedRaceID = raceID }
        } catch {
            logger.error("SubscribeRace failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unsubscribe(raceID: String) async {
        guard let client else { return }
        do {
            _ = try await client.invoke(method: "UnsubscribeRace", args: [AnyCodable(raceID)])
        } catch {
            logger.error("UnsubscribeRace failed: \(error.localizedDescription, privacy: .public)")
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
