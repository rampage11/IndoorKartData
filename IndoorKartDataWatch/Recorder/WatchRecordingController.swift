import Foundation
import Combine
import HealthKit
import WatchKit

@MainActor
final class WatchRecordingController: NSObject, ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var currentSessionID: UUID?
    @Published var lastError: String?
    @Published private(set) var currentBPM: Double?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    private let imuRecorder = WatchIMURecorder()
    private lazy var hrRecorder = HeartRateRecorder(healthStore: healthStore)

    private var sessionDirectory: URL?
    private var startedAt: Date?
    private var timer: Timer?

    func start() {
        guard !isRecording else { return }
        lastError = nil

        Task { @MainActor in
            do {
                try await requestAuthorizationIfNeeded()
                try beginRecording()
            } catch {
                lastError = error.localizedDescription
                await cleanupOnFailure()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
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

    private func beginRecording() throws {
        let id = UUID()
        let now = Date()
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
        elapsedSeconds = 0

        hrRecorder.onBPMUpdate = { [weak self] bpm in
            self?.currentBPM = bpm
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

    private func finalizeRecording() async {
        timer?.invalidate()
        timer = nil

        let endDate = Date()

        imuRecorder.stop()
        hrRecorder.stop()

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

        if let directory = sessionDirectory,
           let id = currentSessionID,
           let started = startedAt {
            do {
                try writeManifest(id: id, started: started, ended: endDate, directory: directory)
            } catch {
                lastError = "Не удалось записать manifest: \(error.localizedDescription)"
            }
        }

        isRecording = false
        startedAt = nil
        sessionDirectory = nil
        workoutSession = nil
        workoutBuilder = nil
        currentBPM = nil
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
    }

    private func writeManifest(id: UUID, started: Date, ended: Date, directory: URL) throws {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
        let device = WKInterfaceDevice.current()
        let imuEntry = DataSourceEntry(
            kind: .watchIMU,
            filename: "watch_imu.bin",
            sampleCount: imuRecorder.sampleCount,
            sampleRateHz: WatchIMURecorder.sampleRateHz,
            format: "imu_v1"
        )
        let hrEntry = DataSourceEntry(
            kind: .heartRate,
            filename: "heart_rate.bin",
            sampleCount: hrRecorder.sampleCount,
            sampleRateHz: nil,
            format: "hr_v1"
        )
        let manifest = SessionManifest(
            id: id,
            startedAt: started,
            endedAt: ended,
            deviceName: device.name,
            deviceModel: device.model,
            appVersion: appVersion,
            sources: [imuEntry, hrEntry]
        )
        try SessionStorage.shared.writeManifest(manifest, sessionURL: directory)
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
