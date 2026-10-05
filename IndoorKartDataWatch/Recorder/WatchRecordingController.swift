import Foundation
import Combine
import HealthKit
import WatchKit
import CoreMotion

@MainActor
final class WatchRecordingController: NSObject, ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var currentSessionID: UUID?
    @Published var lastError: String?
    @Published private(set) var currentBPM: Double?
    @Published private(set) var phoneConnected: Bool = false

    // Номер карта: 0 = ещё не задан. Хранится в UserDefaults, чтобы при запуске
    // часов до спаривания с телефоном гонщик мог сразу выставить номер.
    @Published var kartNumber: Int {
        didSet {
            UserDefaults.standard.set(kartNumber, forKey: Self.kartNumberKey)
            WatchConnection.shared.updateKartNumber(kartNumber)
        }
    }

    // Последнее время круга в миллисекундах — пушит iPhone по WCSession.
    // Храним опционально: nil = ещё ни одного круга в этой сессии.
    @Published var currentLastLapMs: Int?

    // Лучшее время за историю (опционально; iPhone может обновлять по мере заездов).
    @Published var bestLapMs: Int?

    private static let kartNumberKey = "kartNumber"

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    private let imuRecorder = WatchIMURecorder()
    private lazy var hrRecorder = HeartRateRecorder(healthStore: healthStore)

    private var sessionDirectory: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var startedByPhone: Bool = false

    // Для живого стрима руля: интегрируем rotationRate.x (твист запястья) и
    // раз в N семплов отправляем на iPhone.
    private var steeringAccumRad: Double = 0
    private var steeringLastSampleTs: TimeInterval?
    private var steeringSampleCounter: Int = 0
    private let steeringDownsample: Int = 5  // 100Hz → 20Hz

    // Антидрейф: собираем окно семплов РЕАЛЬНО неподвижной руки для bias.
    // Если пилот нажал Старт в движении (например на светофоре с подкатом),
    // "первая секунда" содержит реальное движение → bias ложный → весь интеграл
    // дрейфует. Поэтому ждём пока |rate| останется ниже стационарного порога
    // steeringStationaryThreshold на steeringBiasWindow семплов подряд.
    private var steeringBiasSamples: [Double] = []
    private var steeringBias: Double = 0
    private var steeringBiasReady: Bool = false
    private let steeringBiasWindow: Int = 100  // ~1 сек при 100Гц
    private let steeringStationaryThreshold: Double = 0.05  // rad/s (~2.9°/с) — выше → не статика
    // Мёртвая зона в rad/s: шум ниже этого порога (~1.1°/с) не копим.
    private let steeringDeadZone: Double = 0.02

    override init() {
        self.kartNumber = UserDefaults.standard.integer(forKey: Self.kartNumberKey)
        super.init()
        let connection = WatchConnection.shared
        connection.delegate = self
        connection.activate()
        self.phoneConnected = connection.isReachable
    }

    /// Публичный сеттер для последнего круга — вызывается с iPhone через WCSession.
    /// Здесь — просто обновляем @Published; wiring приёма сообщения добавит оркестратор.
    func setLastLap(_ ms: Int) {
        currentLastLapMs = ms
        if let best = bestLapMs {
            if ms < best { bestLapMs = ms }
        } else {
            bestLapMs = ms
        }
    }

    func start() {
        guard !isRecording else { return }
        lastError = nil
        startedByPhone = false

        let id = UUID()
        let now = Date()

        Task { @MainActor in
            do {
                try await requestAuthorizationIfNeeded()
                try beginRecording(id: id, startDate: now)
                WatchConnection.shared.sendWatchStart(sessionID: id, startedAt: now)
            } catch {
                lastError = error.localizedDescription
                await cleanupOnFailure()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        let id = currentSessionID
        let wasByPhone = startedByPhone
        Task { @MainActor in
            await finalizeRecording()
            // Если старт инициировал телефон, он сам пришлёт watchStop/stop; дублировать не нужно.
            if let id, !wasByPhone {
                WatchConnection.shared.sendWatchStop(sessionID: id)
            }
        }
    }

    private func startFromPhone(sessionID: UUID, startedAt: Date) {
        guard !isRecording else { return }
        lastError = nil
        startedByPhone = true

        Task { @MainActor in
            do {
                try await requestAuthorizationIfNeeded()
                try beginRecording(id: sessionID, startDate: startedAt)
            } catch {
                lastError = error.localizedDescription
                await cleanupOnFailure()
            }
        }
    }

    private func stopFromPhone(sessionID: UUID) {
        guard isRecording, currentSessionID == sessionID else { return }
        Task { @MainActor in
            await finalizeRecording()
        }
    }

    private func requestAuthorizationIfNeeded() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(
                domain: "WatchRecordingController",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "HealthKit недоступен"]
            )
        }
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        try await healthStore.requestAuthorization(toShare: share, read: read)
    }

    private func beginRecording(id: UUID, startDate now: Date) throws {
        let directory = try SessionStorage.shared.createSessionDirectory(id: id, startedAt: now)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self

        // Сессию стартуем раньше датчиков: она переводит часы в режим workout и не даёт заснуть.
        session.startActivity(with: now)
        builder.beginCollection(withStart: now) { _, _ in }

        workoutSession = session
        workoutBuilder = builder
        sessionDirectory = directory
        startedAt = now
        currentSessionID = id
        currentBPM = nil
        currentLastLapMs = nil
        elapsedSeconds = 0

        hrRecorder.onBPMUpdate = { [weak self] bpm in
            self?.currentBPM = bpm
        }

        // Сбрасываем интегратор руля на нуле и чистим калибровку bias.
        steeringAccumRad = 0
        steeringLastSampleTs = nil
        steeringSampleCounter = 0
        steeringBiasSamples = []
        steeringBias = 0
        steeringBiasReady = false
        imuRecorder.onLiveSample = { [weak self] motion in
            self?.processLiveSample(motion)
        }

        try hrRecorder.start(sessionDirectory: directory, startDate: now)
        try imuRecorder.start(sessionDirectory: directory)

        isRecording = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }

    // Вызывается из imuRecorder.onLiveSample (на его operation queue).
    // Делаем всю логику nonisolated: только простые numeric операции и
    // отправку по WatchConnection (thread-safe).
    private nonisolated func processLiveSample(_ motion: CMDeviceMotion) {
        // К self.steeringAccumRad и т.д. обращаемся по сути из одного
        // producer-thread (operation queue recorder-а). Это даёт нам
        // консистентность без замка. @MainActor-свойства не трогаем.
        // Так как мы nonisolated — читаем через Task hop только когда нужно.
        Task { @MainActor in
            self.integrateAndMaybeSendSteering(motion)
        }
    }

    private func integrateAndMaybeSendSteering(_ motion: CMDeviceMotion) {
        guard isRecording else { return }
        let now = motion.timestamp
        // Используем Y — пронация запястья (ось strap-а часов). Проверено
        // на реальной сессии вождения (05.10.2026): gy swing ~95° совпал с
        // физической реальностью "руль не крутился больше 180°", тогда как
        // gx и gz накопили >1000° дрейфа.
        let rate = motion.rotationRate.y

        // Калибровка bias только когда рука РЕАЛЬНО неподвижна.
        // Если пилот стартанул в движении, "первая секунда" не подходит —
        // ждём пока |rate| опустится ниже steeringStationaryThreshold на
        // steeringBiasWindow подряд.
        if !steeringBiasReady {
            if abs(rate) < steeringStationaryThreshold {
                steeringBiasSamples.append(rate)
                if steeringBiasSamples.count >= steeringBiasWindow {
                    steeringBias = steeringBiasSamples.reduce(0, +) / Double(steeringBiasSamples.count)
                    steeringBiasReady = true
                }
            } else {
                // Движение — сбрасываем накопление, начинаем ждать статику заново.
                steeringBiasSamples.removeAll(keepingCapacity: true)
            }
            steeringLastSampleTs = now
            return
        }

        // Основная ветка: вычитаем bias и игнорируем шум в мёртвой зоне.
        let adjusted = rate - steeringBias
        if let last = steeringLastSampleTs {
            let dt = now - last
            if abs(adjusted) > steeringDeadZone {
                steeringAccumRad += adjusted * dt
            }
        }
        steeringLastSampleTs = now
        steeringSampleCounter += 1
        if steeringSampleCounter >= steeringDownsample {
            steeringSampleCounter = 0
            WatchConnection.shared.sendSteeringAngle(steeringAccumRad)
        }
    }

    private func finalizeRecording() async {
        timer?.invalidate()
        timer = nil

        let endDate = Date()

        imuRecorder.onLiveSample = nil
        imuRecorder.stop()
        hrRecorder.stop()
        // Сброс колеса в ноль на телефоне — опционально.
        WatchConnection.shared.sendSteeringAngle(0)

        if let session = workoutSession {
            session.end()
        }
        if let builder = workoutBuilder {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                builder.endCollection(withEnd: endDate) { _, _ in
                    builder.finishWorkout { _, _ in
                        continuation.resume()
                    }
                }
            }
        }

        let directory = sessionDirectory
        let id = currentSessionID

        if let directory, let id {
            // Манифест теперь владеет телефон; часы отправляют только бинари.
            transferArtifactsToPhone(directory: directory, sessionID: id)
        }

        isRecording = false
        startedAt = nil
        sessionDirectory = nil
        workoutSession = nil
        workoutBuilder = nil
        currentBPM = nil
        startedByPhone = false
    }

    private func cleanupOnFailure() async {
        timer?.invalidate()
        timer = nil
        imuRecorder.stop()
        hrRecorder.stop()
        if let session = workoutSession {
            session.end()
        }
        workoutSession = nil
        workoutBuilder = nil
        isRecording = false
        startedAt = nil
        sessionDirectory = nil
        currentSessionID = nil
        currentBPM = nil
        startedByPhone = false
    }

    private func transferArtifactsToPhone(directory: URL, sessionID: UUID) {
        let connection = WatchConnection.shared
        let imuURL = directory.appendingPathComponent("watch_imu.bin")
        let hrURL = directory.appendingPathComponent("heart_rate.bin")
        if FileManager.default.fileExists(atPath: imuURL.path) {
            connection.transferSessionFile(imuURL, filename: "watch_imu.bin", sessionID: sessionID)
        }
        if FileManager.default.fileExists(atPath: hrURL.path) {
            connection.transferSessionFile(hrURL, filename: "heart_rate.bin", sessionID: sessionID)
        }
    }
}

extension WatchRecordingController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
        }
    }
}

extension WatchRecordingController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        // Пульс пишем сами через HKAnchoredObjectQuery; builder нужен только чтобы часы держали датчики активными.
    }
}

extension WatchRecordingController: WatchConnectionDelegate {
    func watchConnection(_ connection: WatchConnection, didReceiveStart sessionID: UUID, startedAt: Date) {
        startFromPhone(sessionID: sessionID, startedAt: startedAt)
    }

    func watchConnection(_ connection: WatchConnection, didReceiveStop sessionID: UUID) {
        stopFromPhone(sessionID: sessionID)
    }

    func watchConnection(_ connection: WatchConnection, reachabilityChanged isReachable: Bool) {
        self.phoneConnected = isReachable
    }

    func watchConnection(_ connection: WatchConnection, lastLapReceivedMs ms: Int) {
        setLastLap(ms)
    }

    func watchConnection(_ connection: WatchConnection, kartNumberChanged number: Int) {
        // Пришло с iPhone — применяем без ретрансляции обратно (didSet сам
        // ретранслирует, но applicationContext дубликаты не доставит).
        if self.kartNumber != number {
            self.kartNumber = number
        }
    }
}
