import Foundation
import CoreMotion

final class WatchIMURecorder {
    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "WatchIMURecorder.queue"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var fileHandle: FileHandle?
    private(set) var sampleCount: Int = 0
    private(set) var fileURL: URL?

    // Коллбэк для живого стрима в UI/связь с iPhone. Вызывается на внутренней
    // operation queue — переключать actor должен подписчик.
    var onLiveSample: ((CMDeviceMotion) -> Void)?

    static let sampleRateHz: Double = 100.0

    func start(sessionDirectory: URL) throws {
        guard motionManager.isDeviceMotionAvailable else {
            throw NSError(
                domain: "WatchIMURecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Device motion недоступен на этих часах"]
            )
        }
        let url = sessionDirectory.appendingPathComponent("watch_imu.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        fileHandle = handle
        fileURL = url
        sampleCount = 0

        motionManager.deviceMotionUpdateInterval = 1.0 / Self.sampleRateHz
        motionManager.showsDeviceMovementDisplay = false

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: queue
        ) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let sample = IMUSampleBinary(
                timestampNs: UInt64(Date().timeIntervalSince1970 * 1e9),
                userAccelX: motion.userAcceleration.x,
                userAccelY: motion.userAcceleration.y,
                userAccelZ: motion.userAcceleration.z,
                rotationRateX: motion.rotationRate.x,
                rotationRateY: motion.rotationRate.y,
                rotationRateZ: motion.rotationRate.z,
                attitudeQW: motion.attitude.quaternion.w,
                attitudeQX: motion.attitude.quaternion.x,
                attitudeQY: motion.attitude.quaternion.y,
                attitudeQZ: motion.attitude.quaternion.z
            )
            do {
                try self.fileHandle?.writeIMUSample(sample)
                self.sampleCount &+= 1
            } catch {
                // Пишем в фоне, UI уже не остановит поток — просто завершаем запись в файл.
                self.motionManager.stopDeviceMotionUpdates()
                try? self.fileHandle?.close()
                self.fileHandle = nil
            }
            self.onLiveSample?(motion)
        }
    }

    func stop() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        // Дожидаемся опустошения очереди, чтобы последние семплы попали в файл.
        queue.waitUntilAllOperationsAreFinished()
        try? fileHandle?.close()
        fileHandle = nil
    }
}
