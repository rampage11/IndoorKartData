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
        let s1Ms: Int?
        let s2Ms: Int?
        let s3Ms: Int?
    }
    @Published private(set) var lapHistory: [LapEvent] = []

    /// Любой Comp от любого карта. Нужен для post-session восстановления карты гонки,
    /// детекции обгонов, валидации chaser gap. Buffer ограничен чтобы не ела память.
    struct PassEvent: Identifiable {
        let id = UUID()
        let wallTime: Date
        let raceTimeMs: Int
        let kartNumber: String?
        let lapNumber: Int?
        let lastLapMs: Int?
        let bestLapMs: Int?
        let position: Int?
        let gapToLeaderMs: Int?
        // Секторные времена из RaceMann. Миллисекунды, nil если трасса не
        // размечена секторами или RaceMann не передал.
        let s1Ms: Int?
        let s2Ms: Int?
        let s3Ms: Int?
    }
    @Published private(set) var allPasses: [PassEvent] = []
    private let allPassesMax: Int = 5000

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
    private var watchdogTask: Task<Void, Never>?
    private var subscribedRaceID: String?

    // Снаружи (RecordingController) выставляется в true на старте записи и
    // в false на остановке. Активирует более агрессивные watchdog'и: при
    // активной сессии мы ОЖИДАЕМ Comp каждые ~33 сек (длина круга), и
    // любая более долгая тишина это аномалия.
    private(set) var isSessionActive: Bool = false
    func setSessionActive(_ active: Bool) {
        guard isSessionActive != active else { return }
        isSessionActive = active
        logger.notice("Session active=\(active, privacy: .public)")
        if active {
            // Сбрасываем метки тишины на старте — иначе watchdog сработает
            // мгновенно если TimingClient был disconnected долгое время.
            lastCompAt = Date()
            lastReconnectAt = nil
            lastSoftResubAt = nil
            lastSubscribeAttemptAt = nil
            lastSubscribeOkAt = nil
            startWatchdogLoop()
        } else {
            watchdogTask?.cancel()
            watchdogTask = nil
        }
    }

    // Timestamp последнего полученного Comp. Используется watchdog'ом.
    private var lastCompAt: Date?
    // Timestamp последнего soft re-subscribe (без тир-дауна WS). Чтобы не долбить сервер.
    private var lastSoftResubAt: Date?
    // Timestamp последнего успешно принятого ответа на SubscribeRace (I/R с E=nil).
    private var lastSubscribeOkAt: Date?
    // Timestamp последней попытки SubscribeRace (отправили invoke). Если ответа нет
    // слишком долго — сокет мёртвый, но WS keep-alive маскирует это.
    private var lastSubscribeAttemptAt: Date?
    // ID последнего отправленного SubscribeRace invoke (int echo'ится обратно от сервера).
    private var pendingSubscribeInvokeID: Int?
    // Защита от бесконечного reconnect-цикла: минимум 15 сек между попытками.
    private var lastReconnectAt: Date?
    // Пороги watchdog'а (единицы: секунды). Собраны в одном месте чтобы было легко
    // крутить при полевой отладке.
    private struct Thresholds {
        // Полная тишина на сокете (включая keep-alive) → WS мёртв, hard reconnect.
        static let wsSilenceHardReconnect: TimeInterval = 25
        // Тишина Comp → soft re-subscribe (не трогая WS).
        static let compSilenceSoftResub: TimeInterval = 20
        // Тишина Comp → hard reconnect всего WS (soft не помог).
        // 60 сек — безопаснее 45: наблюдаемый worst-case gap в хорошей сессии
        // был 44 сек (кратковременная backpressure iOS/сеть), reconnect во время
        // такого gap'а потерял бы очередь событий ждущих доставки. Soft resub
        // в 20-30 сек уже должен выдернуть большинство реальных подвисаний.
        static let compSilenceHardReconnect: TimeInterval = 60
        // Минимальный интервал между soft re-subscribe.
        static let softResubCooldown: TimeInterval = 15
        // Минимальный интервал между hard reconnect.
        static let hardReconnectCooldown: TimeInterval = 15
        // Если SubscribeRace invoke не получил ответ за это время — сокет зомби.
        static let subscribeAckTimeout: TimeInterval = 10
    }
    // Санитарные пределы для фильтрации артефактов "server catchup" lastLapMs:
    // после потери подписки сервер иногда шлёт первый Comp с lapMs = время с
    // момента последнего известного ему Comp (минуты). Любой lapMs вне этого
    // диапазона — артефакт, не кладём в lapHistory.
    private let sanelapMsRangeMs: ClosedRange<Int> = 10_000...180_000

    nonisolated init() {}

    // MARK: - Public API

    func connect() async {
        if client != nil { disconnect() }
        let cfg = SignalRClient.Config(baseURL: baseURL, hub: "racehub")
        let c = SignalRClient(config: cfg)
        self.client = c
        wireCallbacks(c)
        connectionState = "connecting"
        logger.notice("TimingClient connect: starting SignalR negotiate/connect")
        do {
            try await c.connect()
            isConnected = true
            connectionState = "connected"
            logger.notice("TimingClient connect: SignalR connected, fetching race id")
            // Автоподписка: без этого вызова сервер шлёт только heartbeat.
            // Ответ GetLastRaceId приходит как invocation result (I/R), а
            // также сервер может push-ить `lastRaceId` через hub call —
            // оба пути ведут в processNewRaceID.
            await fetchCurrentRaceAndSubscribe()
            startRaceRefreshLoop()
            if isSessionActive {
                startWatchdogLoop()
            }
        } catch {
            logger.error("TimingClient connect failed: \(error.localizedDescription, privacy: .public)")
            isConnected = false
            connectionState = "error: \(error.localizedDescription)"
            // Даже при фейле connect() запускаем watchdog если сессия активна —
            // иначе первый неудачный reconnect оставит нас совсем без self-healing.
            // Watchdog увидит isConnected=false, вызовет attemptReconnect через
            // hardReconnectCooldown сек.
            if isSessionActive {
                startWatchdogLoop()
            }
        }
    }

    func disconnect() {
        raceRefreshTask?.cancel()
        raceRefreshTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        subscribedRaceID = nil
        client?.disconnect()
        client = nil
        isConnected = false
        connectionState = "disconnected"
        // Сбрасываем всё состояние трекера подписки — иначе после hard reconnect
        // старые метки будут давать false-positive "ack не пришёл".
        lastSubscribeAttemptAt = nil
        lastSubscribeOkAt = nil
        pendingSubscribeInvokeID = nil
        lastSoftResubAt = nil
    }

    // Маршаллы иногда ресетают сессию прямо во время заезда. Периодически
    // опрашиваем GetLastRaceId — если ID сменился, processNewRaceID
    // переподписывает нас на новый заезд.
    //
    // Если клиент вдруг оказался в состоянии disconnected (например receive-луп
    // упал но watchdog ещё не успел среагировать), не трогаем — пусть watchdog
    // поднимает соединение. Отправка GetLastRaceId на мёртвый сокет только
    // засоряет логи ошибками.
    private func startRaceRefreshLoop() {
        raceRefreshTask?.cancel()
        raceRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                guard await self.isConnectedAndReady() else { continue }
                await self.fetchCurrentRaceAndSubscribe()
            }
        }
    }

    private func isConnectedAndReady() -> Bool {
        guard let client else { return false }
        return client.isConnected && isConnected
    }

    // Активный watchdog с эскалирующей лестницей действий:
    //   1) 20 сек нет Comp → soft re-subscribe (не трогая WS)
    //   2) 25 сек тишины на сокете (включая keep-alive) → hard reconnect WS
    //   3) 45 сек нет Comp → hard reconnect WS (soft явно не помог)
    //   4) SubscribeRace отправлен > 10 сек назад без ответа → hard reconnect (сокет-зомби)
    //
    // Watchdog тикает каждые 3 сек. Проверки по wall-clock Date (а не по счётчику
    // sleep'ов) чтобы throttling iOS в фоне не ломал логику: даже если Task.sleep
    // проспал 60 сек вместо 3, следующий тик всё равно корректно поймёт сколько
    // прошло с last*At и примет решение.
    private func startWatchdogLoop() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.watchdogTick()
            }
        }
    }

    private func watchdogTick() async {
        guard isSessionActive else { return }
        let now = Date()

        // --- 1. WS-level: сокет жив? ---
        if let client = client {
            let wsSilence: TimeInterval
            if let last = client.lastMessageAt {
                wsSilence = now.timeIntervalSince(last)
            } else {
                wsSilence = .infinity
            }

            // Жёсткое условие: сокет помечен disconnected (receive-луп упал
            // или delegate поймал close) — поднимаем сразу, без тайм-аута.
            if !client.isConnected {
                await attemptReconnect(reason: "WS помечен disconnected (silence \(Int(wsSilence)) сек)")
                return
            }

            // WS тих > N сек — даже keep-alive {} не прилетает. Сокет-зомби,
            // надо hard reconnect. Снижено с 90 до 25 сек — сервер MIKS шлёт
            // keep-alive каждые 2-3 сек, 25 сек тишины уже аномалия.
            if wsSilence > Thresholds.wsSilenceHardReconnect {
                await attemptReconnect(reason: "WS тишина \(Int(wsSilence)) сек > \(Int(Thresholds.wsSilenceHardReconnect))")
                return
            }

            // Проверка на subscribe-ack timeout: если invoke отправлен и
            // прошло > 10 сек без ответа, при этом WS якобы жив — классический
            // iOS BG зомби сокет, нужен hard reconnect.
            if let attempt = lastSubscribeAttemptAt {
                let ackAge = now.timeIntervalSince(attempt)
                let okAge: TimeInterval = {
                    if let ok = lastSubscribeOkAt { return now.timeIntervalSince(ok) }
                    return .infinity
                }()
                // Если был успешный ack ПОСЛЕ последней попытки — всё ок.
                if ackAge > Thresholds.subscribeAckTimeout && okAge > ackAge {
                    await attemptReconnect(reason: "SubscribeRace ack >\(Int(Thresholds.subscribeAckTimeout)) сек тишины (сокет-зомби)")
                    return
                }
            }
        } else {
            // Клиента нет вообще — пытаемся создать.
            await attemptReconnect(reason: "клиент отсутствует")
            return
        }

        // --- 2. Comp-level: подписка жива? ---
        // Отсчитываем от lastCompAt (момент последнего реально принятого Comp).
        // Если за эту сессию ни одного Comp не было — вместо lastCompAt используем
        // lastSubscribeOkAt (момент когда сервер подтвердил подписку): если прошло
        // > 20 сек с подтверждения подписки а Comp'ов нет — подписка мёртвая,
        // reconnect. Если и подписки не было — ещё рано делать выводы.
        let compSilenceAnchor: Date?
        if compCount > 0 {
            compSilenceAnchor = lastCompAt
        } else {
            compSilenceAnchor = lastSubscribeOkAt
        }
        guard let lastComp = compSilenceAnchor else { return }
        let compSilence = now.timeIntervalSince(lastComp)

        // 2a. Жёсткий порог: 45 сек нет Comp'ов → hard reconnect.
        //     Поля на MIKS обычно имеют 7-9 активных картов, Comp каждые ~4 сек от каждого,
        //     даже на пустом поле (1 карт) не должно быть > 40 сек тишины.
        if compSilence > Thresholds.compSilenceHardReconnect {
            await attemptReconnect(reason: "Comp тишина \(Int(compSilence)) сек > \(Int(Thresholds.compSilenceHardReconnect)) — soft не помог")
            return
        }

        // 2b. Мягкий порог: 20 сек нет Comp'ов → re-subscribe (без тир-дауна WS).
        //     Проверяем cooldown чтобы не долбить одно и то же каждые 3 сек.
        if compSilence > Thresholds.compSilenceSoftResub {
            let lastSoft = lastSoftResubAt ?? .distantPast
            if now.timeIntervalSince(lastSoft) >= Thresholds.softResubCooldown {
                lastSoftResubAt = now
                logger.warning("Comp silence \(Int(compSilence), privacy: .public) сек — soft re-subscribe (subscribedRaceID=\(self.subscribedRaceID ?? "nil", privacy: .public))")
                await fetchCurrentRaceAndSubscribe()
                // Безусловный re-subscribe как defense-in-depth: GetLastRaceId
                // может вернуть тот же id, и processNewRaceID решит что всё норм
                // и ничего не сделает — но реальная серверная подписка может быть мёртвой.
                if let raceID = subscribedRaceID ?? currentRaceID {
                    logger.notice("Force re-subscribe to \(raceID, privacy: .public)")
                    await subscribe(raceID: raceID)
                }
            }
        }
    }

    private func attemptReconnect(reason: String) async {
        if let last = lastReconnectAt, Date().timeIntervalSince(last) < Thresholds.hardReconnectCooldown {
            // Защита от циклов reconnect-а если сервер отдаёт стабильный refuse.
            // Короткий cooldown (15 сек) — важнее быстро пытаться чем экономить попытки.
            return
        }
        lastReconnectAt = Date()
        logger.error("Reconnecting SignalR: \(reason, privacy: .public)")
        // disconnect() обнуляет client, НО также отменяет watchdogTask —
        // а мы прямо сейчас выполняемся внутри него. Если мы awaitим connect()
        // здесь, cancellation protagated в URLSession вызовы может прервать negotiate
        // и мы останемся вообще без watchdog'а. Поэтому reconnect выполняем
        // в отдельной (detached) Task, которая не чувствительна к нашему cancel.
        let wasActive = isSessionActive
        // Discard current client немедленно, чтобы watchdog перестал реагировать
        // на старые метки (lastMessageAt) до того как новый клиент встанет.
        disconnect()
        isSessionActive = wasActive
        // Детач-таск — важно: он переживёт отмену watchdogTask из disconnect().
        Task { @MainActor [weak self] in
            await self?.connect()
        }
    }

    func fetchCurrentRaceAndSubscribe() async {
        guard let client else { return }
        do {
            _ = try await client.invoke(method: "GetLastRaceId", args: [])
            // Ответ придёт либо как I/R (invocation result) — обработан в
            // onInvocationResult → processNewRaceID — либо как hub call
            // `lastRaceId` через onHubCall → handleHubCall.
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
        c.onInvocationResult = { [weak self] id, method, result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error, !error.isEmpty {
                    self.logger.error("Invocation \(id, privacy: .public) method=\(method ?? "?", privacy: .public) failed: \(error, privacy: .public)")
                } else {
                    self.logger.debug("Invocation \(id, privacy: .public) method=\(method ?? "?", privacy: .public) ok")
                }
                // Критично: SignalR 2.x возвращает ответ GetLastRaceId
                // через {I, R}, а НЕ через `lastRaceId` hub-call. Старая версия
                // слушала только `lastRaceId` push, который сервер шлёт
                // непредсказуемо (мы наблюдали заезд где он не пришёл
                // вообще за 15 минут). Отсюда — обрабатываем RPC-ответ.
                if method == "GetLastRaceId", let result {
                    if let payload = self.decode(LastRaceIdPayload.self, from: result) {
                        self.processNewRaceID(payload.id)
                    } else {
                        self.logger.error("GetLastRaceId: не удалось декодировать ответ \(String(describing: result.value), privacy: .public)")
                    }
                }
                // SubscribeRace ack — важно для watchdog'а: если сервер молчит
                // > 10 сек в ответ на subscribe, это сокет-зомби (iOS BG особенно
                // любит оставлять живой FD без доставки данных). Фиксируем успех,
                // чтобы watchdog знал что подписка действительно подтверждена сервером.
                if method == "SubscribeRace" {
                    if let error, !error.isEmpty {
                        // Сервер отверг подписку (например, race ещё не стартовал
                        // или ID невалиден). Через 10 сек watchdog попробует snova.
                        self.logger.error("SubscribeRace отвергнут сервером: \(error, privacy: .public)")
                        self.pendingSubscribeInvokeID = nil
                    } else {
                        self.lastSubscribeOkAt = Date()
                        self.pendingSubscribeInvokeID = nil
                    }
                }
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
                processNewRaceID(payload.id)
            }
        case "monitorSettings", "allMonitorMessages":
            logger.debug("Hub call \(call.M, privacy: .public) ignored (secondary)")
        default:
            logger.debug("Hub call \(call.M, privacy: .public) unhandled")
        }
    }

    // Один путь обработки — независимо откуда (I/R RPC-ответ или
    // `lastRaceId` hub call) пришёл свежий raceID.
    private func processNewRaceID(_ newID: String) {
        currentRaceID = newID
        if subscribedRaceID == newID {
            logger.debug("Race id unchanged (\(newID, privacy: .public))")
            return
        }
        let old = subscribedRaceID
        logger.notice("Race id changed: \(old ?? "nil", privacy: .public) → \(newID, privacy: .public)")
        // Маршаллы сбросили сессию — старые метки больше не актуальны.
        resetMySelfState()
        Task { [weak self, oldID = old, newID] in
            if let oldID { await self?.unsubscribe(raceID: oldID) }
            await self?.subscribe(raceID: newID)
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
            // Любой Comp обновляет метку — watchdog ищет полную тишину.
            lastCompAt = Date()
            if compCount % 20 == 1 {
                logger.notice("Comp count=\(self.compCount, privacy: .public) mine=\(self.compMineCount, privacy: .public) raceID=\(self.subscribedRaceID ?? "nil", privacy: .public)")
            }
            if let comp = decode(CompetitorCommand.self, from: env.Command) {
                lastCompKartSeen = comp.rn ?? comp.nn ?? comp.fn
                recordPassEvent(comp, raceTimeMs: env.Time)
                // Порядок важен: сначала проверяем chaser против прежнего pending,
                // потом (если наш) ОБНОВЛЯЕМ pending этим пассажем. Иначе наш же
                // Comp попадёт в чaser-match (gap=0).
                checkChaserPass(comp, raceTimeMs: env.Time)
                applyCompetitorIfMatches(comp, raceTimeMs: env.Time)
            }
        default:
            break
        }
    }

    private func recordPassEvent(_ comp: CompetitorCommand, raceTimeMs: Int) {
        // Нормализованный номер карта: предпочитаем числовые rn/nn, fallback на fn (с префиксом).
        let kart: String? = {
            if let rn = comp.rn, !rn.isEmpty { return rn }
            if let nn = comp.nn, !nn.isEmpty { return nn }
            return comp.fn
        }()
        let event = PassEvent(
            wallTime: Date(),
            raceTimeMs: raceTimeMs,
            kartNumber: kart,
            lapNumber: comp.lc,
            lastLapMs: comp.ll,
            bestLapMs: comp.bl,
            position: comp.pos,
            gapToLeaderMs: comp.ld?.Time,
            s1Ms: comp.S1,
            s2Ms: comp.S2,
            s3Ms: comp.S3
        )
        allPasses.append(event)
        if allPasses.count > allPassesMax {
            allPasses.removeFirst(allPasses.count - allPassesMax)
        }
    }

    private func checkChaserPass(_ comp: CompetitorCommand, raceTimeMs: Int) {
        guard let ourTime = pendingOurRaceTimeMs else { return }
        // Себя не считаем — мы не можем быть сзади у самих себя.
        if let kart = kartNumber, isOurKart(comp, kart: kart) { return }
        // Любой карт пересекающий отсечку ПОСЛЕ нас в пределах минуты —
        // физически едет за нами по трассе. Standings/lap count не важны:
        // если он идёт на круг впереди но пересёк после нас — ему 0.8 сек
        // осталось до нас, что и нужно знать пилоту.
        let gap = raceTimeMs - ourTime
        guard gap > 0, gap < 60_000 else { return }
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
        // Catchup-артефакт (ll > 3 мин) НЕ обновляет pending — иначе chaser gap
        // будет посчитан относительно никогда-не-существовавшего прохождения.
        if let pos = comp.pos, let lc = comp.lc, let ll = comp.ll,
           sanelapMsRangeMs.contains(ll) {
            pendingOurRaceTimeMs = raceTimeMs
            pendingOurPos = pos
            pendingOurLap = lc
            chaserGapMs = nil
        }

        if let ll = comp.ll, sanelapMsRangeMs.contains(ll) { lastLapMs = ll }
        if let bl = comp.bl, bl > 0 { bestLapMs = bl }
        if let lc = comp.lc { lapCount = lc }
        if let pos = comp.pos { position = pos }
        if let ld = comp.ld { gapToLeaderMs = ld.Time }

        // Фиксируем в историю только настоящий пассаж круга: ll > 0 и lc > 0,
        // иначе получим фейковый "нулевой круг" из стартового Comp.
        //
        // Фильтруем "catchup артефакты" от сервера: после потери подписки первый
        // восстановленный Comp может прийти с lastLapMs = время с момента когда
        // сервер видел нас в последний раз (минуты, десятки минут). Любой lapMs
        // вне разумного диапазона (10 сек .. 3 мин для indoor-картинга) — это
        // точно артефакт, пропускаем. Голосовое объявление круга с таким lapMs
        // тоже отфильтруется потому что lapHistory не растёт.
        if let ll = comp.ll, ll > 0, let lc = comp.lc, lc > 0 {
            if !sanelapMsRangeMs.contains(ll) {
                logger.warning("Отбрасываю catchup-артефакт: lap=\(lc, privacy: .public) lapMs=\(ll, privacy: .public) вне диапазона \(self.sanelapMsRangeMs.lowerBound, privacy: .public)..\(self.sanelapMsRangeMs.upperBound, privacy: .public)")
            } else {
                // Dedup: сервер часто дублирует один и тот же Comp (ещё раз
                // перепосылая lap_number=N с идентичным lapMs). Отвергаем точный
                // повтор; но если lapNumber тот же а lapMs разный — всё равно
                // не кладём (это признак того что был артефакт и теперь пришло
                // "уточнение" с другим значением; первое вхождение считаем истиной).
                let last = lapHistory.last
                let isSameLap = last?.lapNumber == lc
                if !isSameLap {
                    lapHistory.append(LapEvent(
                        raceTimeMs: raceTimeMs,
                        wallTime: Date(),
                        lapMs: ll,
                        lapNumber: lc,
                        position: comp.pos ?? 0,
                        bestLapMs: comp.bl ?? ll,
                        s1Ms: comp.S1,
                        s2Ms: comp.S2,
                        s3Ms: comp.S3
                    ))
                }
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
        // Фиксируем момент попытки ДО invoke — watchdog по этой метке
        // поймает "ушёл запрос, ответ не пришёл" (сокет-зомби).
        lastSubscribeAttemptAt = Date()
        do {
            let id = try await client.invoke(method: "SubscribeRace", args: [AnyCodable(raceID)])
            pendingSubscribeInvokeID = id
            await MainActor.run { self.subscribedRaceID = raceID }
            logger.notice("SubscribeRace sent id=\(id, privacy: .public) raceID=\(raceID, privacy: .public)")
        } catch {
            // Если invoke упал на уровне транспорта — WS уже мёртвый,
            // ничего смысленного не сделаем без reconnect. Watchdog заметит
            // по compSilence/wsSilence и выполнит hard reconnect.
            logger.error("SubscribeRace failed: \(error.localizedDescription, privacy: .public)")
            pendingSubscribeInvokeID = nil
        }
    }

    private func unsubscribe(raceID: String) async {
        guard let client else { return }
        do {
            let id = try await client.invoke(method: "UnsubscribeRace", args: [AnyCodable(raceID)])
            logger.notice("UnsubscribeRace sent id=\(id, privacy: .public) raceID=\(raceID, privacy: .public)")
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
