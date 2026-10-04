import Foundation
import HealthKit

final class HeartRateRecorder {
    private let healthStore: HKHealthStore
    private var query: HKAnchoredObjectQuery?
    private var fileHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "HeartRateRecorder.write")

    private(set) var sampleCount: Int = 0
    private(set) var fileURL: URL?
    private(set) var latestBPM: Double?

    var onBPMUpdate: ((Double) -> Void)?

    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())
    private let heartRateType = HKQuantityType(.heartRate)

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func start(sessionDirectory: URL, startDate: Date) throws {
        let url = sessionDirectory.appendingPathComponent("heart_rate.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        fileHandle = handle
        fileURL = url
        sampleCount = 0
        latestBPM = nil

        // Берём только семплы, пришедшие после старта сессии.
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let anchoredQuery = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.handle(samples: samples)
        }
        anchoredQuery.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handle(samples: samples)
        }
        query = anchoredQuery
        healthStore.execute(anchoredQuery)
    }

    func stop() {
        if let query {
            healthStore.stop(query)
        }
        query = nil
        writeQueue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func handle(samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
            return
        }
        writeQueue.async { [weak self] in
            guard let self, let handle = self.fileHandle else { return }
            for sample in quantitySamples {
                let bpm = sample.quantity.doubleValue(for: self.bpmUnit)
                let record = HeartRateSampleBinary(
                    timestampNs: UInt64(sample.startDate.timeIntervalSince1970 * 1e9),
                    bpm: bpm
                )
                do {
                    try handle.writeHeartRateSample(record)
                    self.sampleCount &+= 1
                    self.latestBPM = bpm
                    if let cb = self.onBPMUpdate {
                        DispatchQueue.main.async { cb(bpm) }
                    }
                } catch {
                    return
                }
            }
        }
    }
}
