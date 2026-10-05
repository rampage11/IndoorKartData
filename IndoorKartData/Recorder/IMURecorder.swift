import Foundation
import CoreMotion

final class IMURecorder {
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.indoorkartdata.imu.motion"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let writeQueue = DispatchQueue(label: "com.indoorkartdata.imu.write", qos: .utility)

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var sampleCount: Int = 0

    // Коллбэк для живой подписки на поток CMDeviceMotion. Нужен для steering-
    // виджета: iPhone yaw используется как референс "тело пилота" чтобы
    // вычислить wrist-relative yaw. Вызывается на motion queue.
    var onLiveSample: ((CMDeviceMotion) -> Void)?

    // Привязка CMDeviceMotion.timestamp (сек. с момента boot) к абсолютному времени
    // нужна только если потребуется кросс-коррелировать с другими источниками;
    // внутри файла сохраняем монотонный ns от boot, этого достаточно для анализа.

    var isRunning: Bool { motionManager.isDeviceMotionActive }
    var currentSampleCount: Int { sampleCount }
    var sampleRateHz: Double { 100.0 }

    enum IMUError: Error {
        case deviceMotionUnavailable
        case fileOpenFailed
    }

    func start(fileURL: URL) throws {
        guard motionManager.isDeviceMotionAvailable else {
            throw IMUError.deviceMotionUnavailable
        }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw IMUError.fileOpenFailed
        }
        self.fileHandle = handle
        self.fileURL = fileURL
        self.sampleCount = 0

        motionManager.deviceMotionUpdateInterval = 0.01
        motionManager.showsDeviceMovementDisplay = false

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: motionQueue
        ) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let sample = IMUSampleBinary(
                timestampNs: UInt64((motion.timestamp * 1_000_000_000.0).rounded()),
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
            self.writeQueue.async { [weak self] in
                guard let self, let handle = self.fileHandle else { return }
                do {
                    try handle.writeIMUSample(sample)
                    self.sampleCount &+= 1
                } catch {
                    // Молча пропускаем сбой записи одного семпла, чтобы не рушить поток.
                }
            }
            self.onLiveSample?(motion)
        }
    }

    func stop(completion: @escaping (Int) -> Void) {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        // Дожидаемся дренажа очереди записи, иначе sampleCount может отстать от файла.
        writeQueue.async { [weak self] in
            guard let self else {
                completion(0)
                return
            }
            try? self.fileHandle?.synchronize()
            try? self.fileHandle?.close()
            self.fileHandle = nil
            let count = self.sampleCount
            completion(count)
        }
    }
}
