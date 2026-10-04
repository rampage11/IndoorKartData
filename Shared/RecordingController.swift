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

    private var timer: Timer?
    private var startedAt: Date?
    private var sessionURL: URL?

    #if os(iOS)
    private let imuRecorder = IMURecorder()
    private let audioRecorder = AudioRecorder()
    #endif

    func start() {
        guard !isRecording else { return }
        #if os(iOS)
        Task { @MainActor in
            await self.startIOS()
        }
        #else
        self.startElapsedOnly()
        #endif
    }

    func stop() {
        guard isRecording else { return }
        #if os(iOS)
        Task { @MainActor in
            await self.stopIOS()
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
    private func startIOS() async {
        let granted = await AudioRecorder.requestPermission()
        guard granted else {
            self.lastError = "Доступ к микрофону не разрешён"
            return
        }
        guard !isRecording else { return }

        let id = UUID()
        let now = Date()
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
        UIApplication.shared.isIdleTimerDisabled = true
        startTimer()
    }

    private func stopIOS() async {
        timer?.invalidate()
        timer = nil

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
                audioFrameCount: audioFrames
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
        audioFrameCount: Int
    ) {
        let deviceName = UIDevice.current.name
        let deviceModel = UIDevice.current.model
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

        let sources: [DataSourceEntry] = [
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
    #endif
}
