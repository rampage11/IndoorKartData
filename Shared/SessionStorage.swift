import Foundation

/// Управляет директориями сессий на устройстве.
/// Структура:
///   Documents/sessions/<timestamp>_<id-prefix>/
///       manifest.json
///       iphone_imu.bin
///       iphone_audio.wav
///       watch_imu.bin
///       heart_rate.bin
final class SessionStorage {
    static let shared = SessionStorage()

    private let fileManager = FileManager.default

    var rootURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("sessions", isDirectory: true)
    }

    func ensureRoot() throws {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    func createSessionDirectory(id: UUID, startedAt: Date) throws -> URL {
        try ensureRoot()
        let name = SessionDirectoryName.make(id: id, startedAt: startedAt)
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func listSessions() throws -> [URL] {
        try ensureRoot()
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lDate > rDate
            }
    }

    func loadManifest(sessionURL: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: sessionURL.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: data)
    }

    func writeManifest(_ manifest: SessionManifest, sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: sessionURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func deleteSession(sessionURL: URL) throws {
        try fileManager.removeItem(at: sessionURL)
    }

    /// Эффективный список источников: manifest + файлы на диске.
    /// Needed because transferFile с часов приходит асинхронно и иногда
    /// позже чем мы успели записать manifest при stop.
    func effectiveSources(for sessionURL: URL, manifestSources: [DataSourceEntry]) -> [DataSourceEntry] {
        var out = manifestSources
        let fm = FileManager.default

        func addIfPresent(filename: String, kind: DataSourceKind, rateHz: Double?, format: String) {
            guard fm.fileExists(atPath: sessionURL.appendingPathComponent(filename).path) else { return }
            if out.contains(where: { $0.filename == filename }) { return }
            out.append(DataSourceEntry(kind: kind, filename: filename, sampleCount: nil, sampleRateHz: rateHz, format: format))
        }

        addIfPresent(filename: "watch_imu.bin", kind: .watchIMU, rateHz: 100.0, format: "imu_v1")
        addIfPresent(filename: "heart_rate.bin", kind: .heartRate, rateHz: nil, format: "hr_v1")
        addIfPresent(filename: "timing.json", kind: .timing, rateHz: nil, format: "timing_v1")
        return out
    }

    /// Если на диске есть источники, которых нет в manifest.json — дописывает их.
    /// Возвращает обновлённый manifest. No-op если ничего нового не нашлось.
    func healManifest(sessionURL: URL) throws -> SessionManifest {
        var manifest = try loadManifest(sessionURL: sessionURL)
        let effective = effectiveSources(for: sessionURL, manifestSources: manifest.sources)
        if effective.count != manifest.sources.count {
            manifest.sources = effective
            try writeManifest(manifest, sessionURL: sessionURL)
        }
        return manifest
    }
}
