import Foundation
import CoreMotion

/// Формат бинарного батча Watch→iPhone→Katahub для live-стрима raw IMU.
///
/// Header (8 байт, little-endian):
///   [0..2)  magic = 0x494D ('IM')
///   [2..3)  version = 1 (uint8)
///   [3..4)  reserved = 0 (uint8)
///   [4..8)  count: uint32 — количество IMU-сэмплов в батче
///
/// Затем count × 88 байт = IMUSampleBinary (как в watch_imu.bin).
///
/// 1-секундный батч @ 100 Гц = 8 + 100×88 = 8808 байт ≈ 8.6 КБ/с ≈ 70 кбит/с.
/// Это выше теоретических 1.5 КБ/с из спеки, но даёт идеальную точность на
/// backend (laps/N.bin пишется прямым concatenate без переквантизации).
enum WatchIMUBatchFormat {
    static let magic: UInt16 = 0x494D  // 'IM' little-endian: 0x49='I', 0x4D='M'
    static let version: UInt8 = 1
    static let headerSize: Int = 8
}

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

    // Коллбэк на готовый 1-секундный батч raw IMU для live-отправки.
    // Вызывается на той же operation queue; получатель должен быстро
    // переложить Data и вернуться (мы его не ждём).
    var onBatchReady: ((Data) -> Void)?

    // Накопитель для текущего батча. Отсекаем по длительности, а не по кол-ву
    // сэмплов, чтобы при пропадании CoreMotion-апдейтов отправить что есть.
    private var batchBuffer: [IMUSampleBinary] = []
    private var batchStartTsNs: UInt64 = 0
    private let batchWindowNs: UInt64 = 1_000_000_000  // 1 секунда

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
            self.accumulateForBatch(sample)
            self.onLiveSample?(motion)
        }
    }

    func stop() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        // Дожидаемся опустошения очереди, чтобы последние семплы попали в файл.
        queue.waitUntilAllOperationsAreFinished()
        // Остатки батча отправляем последним кадром (может быть <1с).
        flushBatch()
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func accumulateForBatch(_ sample: IMUSampleBinary) {
        if batchBuffer.isEmpty {
            batchStartTsNs = sample.timestampNs
        }
        batchBuffer.append(sample)
        if sample.timestampNs - batchStartTsNs >= batchWindowNs {
            flushBatch()
        }
    }

    private func flushBatch() {
        guard !batchBuffer.isEmpty, let callback = onBatchReady else {
            batchBuffer.removeAll(keepingCapacity: true)
            return
        }
        let count = UInt32(batchBuffer.count)
        var payload = Data()
        payload.reserveCapacity(WatchIMUBatchFormat.headerSize + batchBuffer.count * IMUSampleBinary.byteSize)
        var magic = WatchIMUBatchFormat.magic.littleEndian
        var version = WatchIMUBatchFormat.version
        var reserved: UInt8 = 0
        var cnt = count.littleEndian
        payload.append(Data(bytes: &magic, count: 2))
        payload.append(Data(bytes: &version, count: 1))
        payload.append(Data(bytes: &reserved, count: 1))
        payload.append(Data(bytes: &cnt, count: 4))
        for var s in batchBuffer {
            payload.append(Data(bytes: &s, count: IMUSampleBinary.byteSize))
        }
        batchBuffer.removeAll(keepingCapacity: true)
        callback(payload)
    }
}
