import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var currentSessionID: UUID?
    @Published var lastError: String?
    @Published private(set) var watchConnected: Bool = false
    @Published private(set) var steeringAngleRadians: Double = 0

    private var timer: Timer?
    private var startedAt: Date?
    private var sessionURL: URL?

    #if os(iOS)
    private let imuRecorder = IMURecorder()
    private let audioRecorder = AudioRecorder()
    private let timingRecorder = TimingRecorder()
    private let voiceAnnouncer = VoiceAnnouncer()
    private var watchFilesReceived: Set<String> = []
    private var watchIMUSampleCount: Int?
    private var heartRateSampleCount: Int?
    private var audioStarted: Bool = false

    // Номер карта. 0 = не задан. Храним в UserDefaults, синкаем с часами
    // через applicationContext.
    @Published var kartNumber: Int {
        didSet {
            UserDefaults.standard.set(kartNumber, forKey: Self.kartNumberKey)
            if kartNumber > 0 {
                TimingClient.shared.kartNumber = String(kartNumber)
            } else {
                TimingClient.shared.kartNumber = nil
            }
            WatchConnection.shared.updateKartNumber(kartNumber)
        }
    }
    private static let kartNumberKey = "kartNumber"
    private static let driverIdKey = "driverId"

    // Стабильный ID пилота: генерируется один раз на устройство, живёт в
    // UserDefaults. Нужен чтобы сравнивать сессии одного пилота между
    // собой (в т.ч. в будущем через Supabase).
    static var persistentDriverID: UUID {
        if let s = UserDefaults.standard.string(forKey: Self.driverIdKey),
           let uuid = UUID(uuidString: s) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: Self.driverIdKey)
        return fresh
    }

    // Голосовое оповещение времени круга. true по умолчанию, в UserDefaults.
    @Published var voiceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: Self.voiceEnabledKey)
            if !voiceEnabled { voiceAnnouncer.stopAll() }
        }
    }
    private static let voiceEnabledKey = "voiceEnabled"

    // Подписки на TimingClient
    private var timingLastLapObserver: AnyCancellable?
    private var timingChaserObserver: AnyCancellable?

    // Debounce для watchConnected: isReachable щёлкает true/false при каждом
    // подъёме/опускании запястья быстрее чем за секунду. В UI показываем
    // только устойчивые смены состояния (prolonged ≥ 1 сек).
    private var pendingWatchReachabilityWork: DispatchWorkItem?
    #endif

    init() {
        #if os(iOS)
        self.kartNumber = UserDefaults.standard.integer(forKey: Self.kartNumberKey)
        // Голос по умолчанию включен — иначе toggle не нужен был бы сделан.
        self.voiceEnabled = UserDefaults.standard.object(forKey: Self.voiceEnabledKey) as? Bool ?? true
        let connection = WatchConnection.shared
        connection.delegate = self
        connection.activate()
        self.watchConnected = connection.isReachable
        // Применяем сохранённый номер в TimingClient сразу, чтобы при подключении
        // к SignalR фильтр уже работал.
        if kartNumber > 0 {
            TimingClient.shared.kartNumber = String(kartNumber)
        }
        // Шлём на часы при старте — пользователь мог поменять там, пока связи не было.
        WatchConnection.shared.updateKartNumber(kartNumber)
        subscribeToTiming()
        #endif
    }

    #if os(iOS)
    private func subscribeToTiming() {
        // Каждый новый lastLapMs — на часы, в голосовое оповещение (если
        // включено), и в lapHistory TimingRecorder (сам подписан отдельно).
        timingLastLapObserver = TimingClient.shared.$lastLapMs
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] ms in
                WatchConnection.shared.sendLastLap(ms)
                guard let self else { return }
                Task { @MainActor in
                    if self.voiceEnabled {
                        self.voiceAnnouncer.announceLap(ms: ms)
                    }
                }
            }
        // Дельта до преследователя приходит через несколько секунд после
        // нашего круга (когда следующий карт пересекает отсечку).
        timingChaserObserver = TimingClient.shared.$chaserGapMs
            .compactMap { $0 }
            .sink { [weak self] gap in
                guard let self else { return }
                Task { @MainActor in
                    if self.voiceEnabled {
                        self.voiceAnnouncer.announceChaser(gapMs: gap)
                    }
                }
            }
    }
    #endif

    func start() {
        guard !isRecording else { return }
        #if os(iOS)
        Task { @MainActor in
            await self.startIOS(externalSessionID: nil, externalStart: nil)
        }
        #else
        self.startElapsedOnly()
        #endif
    }

    func stop() {
        guard isRecording else { return }
        #if os(iOS)
        Task { @MainActor in
            await self.stopIOS(notifyWatch: true)
        }
        #else
        self.stopElapsedOnly()
        #endif
    }

    private func startElapsedOnly() {
        let id = UUID()
        currentSessionID = id
        startedAt = Date()
        isRecording = true
        elapsedSeconds = 0
        startTimer()
    }

    private func stopElapsedOnly() {
        timer?.invalidate()
        timer = nil
        isRecording = false
        startedAt = nil
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }

    #if os(iOS)
    private func startIOS(externalSessionID: UUID?, externalStart: Date?) async {
        let granted = await AudioRecorder.requestPermission()
        guard granted else {
            self.lastError = "Доступ к микрофону не разрешён"
            return
        }
        guard !isRecording else { return }

        let id = externalSessionID ?? UUID()
        let now = externalStart ?? Date()
        let sessionURL: URL
        do {
            sessionURL = try SessionStorage.shared.createSessionDirectory(id: id, startedAt: now)
        } catch {
            self.lastError = "Не удалось создать директорию сессии: \(error.localizedDescription)"
            return
        }

        let imuURL = sessionURL.appendingPathComponent("iphone_imu.bin")
        let audioURL = sessionURL.appendingPathComponent("iphone_audio.wav")

        do {
            try imuRecorder.start(fileURL: imuURL)
        } catch {
            self.lastError = "IMU не доступен: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: sessionURL)
            return
        }

        // Audio опционален: если iOS не отдал микрофон (background-cold start),
        // пишем сессию без аудио — IMU и часы всё равно соберут полезное.
        self.audioStarted = false
        do {
            try audioRecorder.start(fileURL: audioURL)
            self.audioStarted = true
        } catch {
            self.lastError = "Аудио не стартовало: \(error.localizedDescription). Пишу без звука."
        }

        self.sessionURL = sessionURL
        self.currentSessionID = id
        self.startedAt = now
        self.isRecording = true
        self.elapsedSeconds = 0
        self.watchFilesReceived = []
        self.watchIMUSampleCount = nil
        self.heartRateSampleCount = nil

        // Поднимаем SignalR-соединение к RaceMann если номер карта задан,
        // и запускаем сбор timing-ивентов в session dir.
        timingRecorder.start(sessionURL: sessionURL)
        if kartNumber > 0 {
            Task { await TimingClient.shared.connect() }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        startTimer()

        // Команду на часы шлём только когда стартуем сами (не когда это watch попросил).
        // Статус соединения с часами отображается через watchConnected badge в UI,
        // поэтому отсутствие связи не считаем ошибкой — просто шлём в очередь.
        if externalSessionID == nil {
            let connection = WatchConnection.shared
            if connection.isReachable {
                connection.sendStart(sessionID: id, startedAt: now, reply: nil)
            } else if connection.isCompanionInstalled {
                connection.sendStart(sessionID: id, startedAt: now, reply: nil)
            }
        }
    }

    private func stopIOS(notifyWatch: Bool) async {
        timer?.invalidate()
        timer = nil

        let sessionID = currentSessionID
        if notifyWatch, let sessionID {
            WatchConnection.shared.sendStop(sessionID: sessionID, reply: nil)
        }

        let imuCount: Int = await withCheckedContinuation { cont in
            imuRecorder.stop { count in cont.resume(returning: count) }
        }
        let audioFrames: Int = await withCheckedContinuation { cont in
            audioRecorder.stop { frames in cont.resume(returning: frames) }
        }

        let endedAt = Date()
        // Финализируем timing-артефакт ДО manifest, чтобы файл был на диске
        // когда сканер директории включает его в sources.
        timingRecorder.finalize()
        if let url = sessionURL, let id = currentSessionID, let started = startedAt {
            if !audioStarted {
                let audioURL = url.appendingPathComponent("iphone_audio.wav")
                try? FileManager.default.removeItem(at: audioURL)
            }
            writeManifest(
                sessionURL: url,
                id: id,
                startedAt: started,
                endedAt: endedAt,
                imuSampleCount: imuCount,
                audioFrameCount: audioStarted ? audioFrames : nil
            )
        }

        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        startedAt = nil
        sessionURL = nil

        // Отключаемся от RaceMann чтобы не держать WS впустую между заездами.
        TimingClient.shared.disconnect()
    }

    private func writeManifest(
        sessionURL: URL,
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        imuSampleCount: Int,
        audioFrameCount: Int?
    ) {
        let deviceName = UIDevice.current.name
        let deviceModel = UIDevice.current.model
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

        var sources: [DataSourceEntry] = [
            DataSourceEntry(
                kind: .iPhoneIMU,
                filename: "iphone_imu.bin",
                sampleCount: imuSampleCount,
                sampleRateHz: 100.0,
                format: "imu_v1"
            )
        ]
        if let audioFrameCount {
            sources.append(DataSourceEntry(
                kind: .iPhoneAudio,
                filename: "iphone_audio.wav",
                sampleCount: audioFrameCount,
                sampleRateHz: 44_100.0,
                format: "wav_pcm16_44100_mono"
            ))
        }

        // Прочие источники (часы, HR) всегда определяем по наличию файлов на диске.
        // Из-за асинхронности transferFile они могут прийти как до stop, так и после;
        // всегда сканируем реальную директорию, чтобы manifest не отставал.
        appendWatchSourcesFromDisk(to: &sources, sessionURL: sessionURL)

        let manifest = SessionManifest(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            deviceName: deviceName,
            deviceModel: deviceModel,
            appVersion: appVersion,
            sources: sources,
            driverId: Self.persistentDriverID,
            kartNumber: kartNumber > 0 ? kartNumber : nil,
            timingRaceID: TimingClient.shared.currentRaceID,
            trackName: nil  // UI выбора трека появится позже; пока nil
        )

        do {
            try SessionStorage.shared.writeManifest(manifest, sessionURL: sessionURL)
        } catch {
            self.lastError = "Не удалось записать manifest: \(error.localizedDescription)"
        }
    }

    private func appendWatchSourcesFromDisk(to sources: inout [DataSourceEntry], sessionURL: URL) {
        let fm = FileManager.default
        let watchIMUURL = sessionURL.appendingPathComponent("watch_imu.bin")
        if fm.fileExists(atPath: watchIMUURL.path),
           !sources.contains(where: { $0.filename == "watch_imu.bin" }) {
            sources.append(DataSourceEntry(
                kind: .watchIMU,
                filename: "watch_imu.bin",
                sampleCount: watchIMUSampleCount,
                sampleRateHz: 100.0,
                format: "imu_v1"
            ))
        }
        let hrURL = sessionURL.appendingPathComponent("heart_rate.bin")
        if fm.fileExists(atPath: hrURL.path),
           !sources.contains(where: { $0.filename == "heart_rate.bin" }) {
            sources.append(DataSourceEntry(
                kind: .heartRate,
                filename: "heart_rate.bin",
                sampleCount: heartRateSampleCount,
                sampleRateHz: nil,
                format: "hr_v1"
            ))
        }
        let timingURL = sessionURL.appendingPathComponent("timing.json")
        if fm.fileExists(atPath: timingURL.path),
           !sources.contains(where: { $0.filename == "timing.json" }) {
            sources.append(DataSourceEntry(
                kind: .timing,
                filename: "timing.json",
                sampleCount: nil,
                sampleRateHz: nil,
                format: "timing_v1"
            ))
        }
    }

    private func mergeIncomingWatchFile(url: URL, filename: String, sessionID: UUID) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url) }

        let targetDir: URL
        if let currentID = currentSessionID, currentID == sessionID, let active = sessionURL {
            targetDir = active
        } else if let existing = findSessionDirectory(forID: sessionID) {
            targetDir = existing
        } else {
            // Watch писал без iPhone — создаём для него директорию, манифест будет минимальным.
            let created: URL
            do {
                created = try SessionStorage.shared.createSessionDirectory(id: sessionID, startedAt: Date())
            } catch {
                self.lastError = "Не удалось создать директорию для часов: \(error.localizedDescription)"
                return
            }
            targetDir = created
            writeStandaloneWatchManifestIfNeeded(dir: created, id: sessionID)
        }

        let dest = targetDir.appendingPathComponent(filename)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
        } catch {
            self.lastError = "Не удалось сохранить файл с часов: \(error.localizedDescription)"
            return
        }

        if let currentID = currentSessionID, currentID == sessionID {
            watchFilesReceived.insert(filename)
        } else {
            appendWatchSourceToExistingManifest(dir: targetDir, filename: filename)
        }
    }

    private func findSessionDirectory(forID id: UUID) -> URL? {
        guard let sessions = try? SessionStorage.shared.listSessions() else { return nil }
        for dir in sessions {
            if let manifest = try? SessionStorage.shared.loadManifest(sessionURL: dir), manifest.id == id {
                return dir
            }
        }
        return nil
    }

    private func appendWatchSourceToExistingManifest(dir: URL, filename: String) {
        guard var manifest = try? SessionStorage.shared.loadManifest(sessionURL: dir) else {
            self.lastError = "Не удалось обновить manifest: не читается существующий"
            return
        }
        // Пересканируем директорию целиком — так же как при stop. Это закрывает
        // гонку когда файлы часов приходят после того как iPhone уже закрыл сессию.
        appendWatchSourcesFromDisk(to: &manifest.sources, sessionURL: dir)
        do {
            try SessionStorage.shared.writeManifest(manifest, sessionURL: dir)
        } catch {
            self.lastError = "Не удалось обновить manifest: \(error.localizedDescription)"
        }
    }

    private func writeStandaloneWatchManifestIfNeeded(dir: URL, id: UUID) {
        if (try? SessionStorage.shared.loadManifest(sessionURL: dir)) != nil { return }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let manifest = SessionManifest(
            id: id,
            startedAt: Date(),
            endedAt: Date(),
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model,
            appVersion: appVersion,
            sources: [],
            driverId: Self.persistentDriverID,
            kartNumber: kartNumber > 0 ? kartNumber : nil,
            timingRaceID: nil,
            trackName: nil
        )
        try? SessionStorage.shared.writeManifest(manifest, sessionURL: dir)
    }
    #endif
}

#if os(iOS)
extension RecordingController: WatchConnectionDelegate {
    func watchConnection(_ connection: WatchConnection, didReceiveStart sessionID: UUID, startedAt: Date) {
        guard !isRecording else { return }
        Task { @MainActor in
            await self.startIOS(externalSessionID: sessionID, externalStart: startedAt)
        }
    }

    func watchConnection(_ connection: WatchConnection, didReceiveStop sessionID: UUID) {
        guard isRecording, currentSessionID == sessionID else { return }
        Task { @MainActor in
            await self.stopIOS(notifyWatch: false)
        }
    }

    func watchConnection(_ connection: WatchConnection, didReceiveFile url: URL, filename: String, sessionID: UUID) {
        mergeIncomingWatchFile(url: url, filename: filename, sessionID: sessionID)
    }

    func watchConnection(_ connection: WatchConnection, reachabilityChanged isReachable: Bool) {
        // true → применяем сразу (пилоту важно знать что связь появилась).
        // false → откладываем на 1 сек; если за это время прилетит true обратно,
        // badge не мигает.
        pendingWatchReachabilityWork?.cancel()
        pendingWatchReachabilityWork = nil
        if isReachable {
            self.watchConnected = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.watchConnected = false
        }
        pendingWatchReachabilityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func watchConnection(_ connection: WatchConnection, steeringAngleChanged radians: Double) {
        self.steeringAngleRadians = radians
    }

    func watchConnection(_ connection: WatchConnection, kartNumberChanged number: Int) {
        // Прилетело с часов (изменил пилот). Защита от эхо: didSet не ретранслирует
        // то же значение, applicationContext сам де-дуплицирует одинаковые.
        if self.kartNumber != number {
            self.kartNumber = number
        }
    }
}
#endif
