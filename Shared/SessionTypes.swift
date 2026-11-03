import Foundation

enum DataSourceKind: String, Codable {
    case iPhoneIMU = "iphone_imu"
    case iPhoneAudio = "iphone_audio"
    case watchIMU = "watch_imu"
    case heartRate = "heart_rate"
    case timing = "timing"
}

struct DataSourceEntry: Codable {
    let kind: DataSourceKind
    let filename: String
    let sampleCount: Int?
    let sampleRateHz: Double?
    let format: String
}

struct SessionManifest: Codable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    let deviceName: String
    let deviceModel: String
    let appVersion: String
    var sources: [DataSourceEntry]
    // Контекст для post-session анализа и будущих сравнений между сессиями.
    // Все optional чтобы не ломать decode старых манифестов.
    var driverId: UUID?
    var kartNumber: Int?
    var timingRaceID: String?
    var trackName: String?
    // Shake-sync: пик suspected shake, записанный пилотом перед выездом.
    // v3 pipeline использует это для alignment между iPhone и Watch.
    // iPhone-only запись → shakeSyncIphoneAtMs, если Watch тоже поймал пик
    // (сообщает по WCSession) → shakeSyncWatchAtMs. Offset = watch - phone.
    var shakeSyncIphoneAtMs: Int64?
    var shakeSyncWatchAtMs: Int64?
}

enum SessionDirectoryName {
    static func make(id: UUID, startedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        return "\(timestamp)_\(id.uuidString.prefix(8))"
    }
}
