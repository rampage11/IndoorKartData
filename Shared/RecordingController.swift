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

    private var timer: Timer?
    private var startedAt: Date?
    private var sessionURL: URL?

    #if os(iOS)
    private let imuRecorder = IMURecorder()
    private let audioRecorder = AudioRecorder()
    private var watchFilesReceived: Set<String> = []
    private var watchIMUSampleCount: Int?
    private var heartRateSampleCount: Int?
    #endif

    init() {
        #if os(iOS)
        let connection = WatchConnection.shared
        connection.delegate = self
        connection.activate()
        self.watchConnected = connection.isReachable
        #endif
    }

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

        do {
            try audioRecorder.start(fileURL: audioURL)
        } catch {
            // Откатываем IMU, иначе он останется включённым без аудио-пары.
            imuRecorder.stop { _ in }
            self.lastError = "Аудио не стартовало: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: sessionURL)
            return
        }

        self.sessionURL = sessionURL
        self.currentSessionID = id
        self.startedAt = now
        self.isRecording = true
        self.elapsedSeconds = 0
        self.watchFilesReceived = []
        self.watchIMUSampleCount = nil
        self.heartRateSampleCount = nil
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
        if let url = sessionURL, let id = currentSessionID, let started = startedAt {
            writeManifest(
                sessionURL: url,
                id: id,
                startedAt: started,
                endedAt: endedAt,
                imuSampleCount: imuCount,
                audioFrameCount: audioFrames,
                includeWatch: watchFilesReceived.contains("watch_imu.bin"),
                includeHR: watchFilesReceived.contains("heart_rate.bin")
            )
        }

        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        startedAt = nil
        sessionURL = nil
    }

    private func writeManifest(
        sessionURL: URL,
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        imuSampleCount: Int,
        audioFrameCount: Int,
        includeWatch: Bool,
        includeHR: Bool
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
            ),
            DataSourceEntry(
                kind: .iPhoneAudio,
                filename: "iphone_audio.wav",
                sampleCount: audioFrameCount,
                sampleRateHz: 44_100.0,
                format: "wav_pcm16_44100_mono"
            )
        ]

        if includeWatch {
            sources.append(DataSourceEntry(
                kind: .watchIMU,
                filename: "watch_imu.bin",
                sampleCount: watchIMUSampleCount,
                sampleRateHz: 100.0,
                format: "imu_v1"
            ))
        }
        if includeHR {
            sources.append(DataSourceEntry(
                kind: .heartRate,
                filename: "heart_rate.bin",
                sampleCount: heartRateSampleCount,
                sampleRateHz: nil,
                format: "hr_v1"
            ))
        }

        let manifest = SessionManifest(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            deviceName: deviceName,
            deviceModel: deviceModel,
            appVersion: appVersion,
            sources: sources
        )

        do {
            try SessionStorage.shared.writeManifest(manifest, sessionURL: sessionURL)
        } catch {
            self.lastError = "Не удалось записать manifest: \(error.localizedDescription)"
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
        guard var manifest = try? SessionStorage.shared.loadManifest(sessionURL: dir) else { return }
        let kind: DataSourceKind
        let format: String
        let rate: Double?
        switch filename {
        case "watch_imu.bin":
            kind = .watchIMU; format = "imu_v1"; rate = 100.0
        case "heart_rate.bin":
            kind = .heartRate; format = "hr_v1"; rate = nil
        default:
            return
        }
        if !manifest.sources.contains(where: { $0.filename == filename }) {
            manifest.sources.append(DataSourceEntry(
                kind: kind,
                filename: filename,
                sampleCount: nil,
                sampleRateHz: rate,
                format: format
            ))
            try? SessionStorage.shared.writeManifest(manifest, sessionURL: dir)
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
            sources: []
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
        self.watchConnected = isReachable
    }
}
#endif
