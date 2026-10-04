import Foundation

enum DataSourceKind: String, Codable {
    case iPhoneIMU = "iphone_imu"
    case iPhoneAudio = "iphone_audio"
    case watchIMU = "watch_imu"
    case heartRate = "heart_rate"
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
}

enum SessionDirectoryName {
    static func make(id: UUID, startedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        return "\(timestamp)_\(id.uuidString.prefix(8))"
    }
}
