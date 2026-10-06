import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// Транспортер для всей директории sessions/ (все записи сразу).
// Используется в SessionsListScreen для massively удобного экспорта.
struct AllSessionsArchive: Transferable {
    let rootURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { archive in
            let zipURL = try AllSessionsArchive.makeZip(of: archive.rootURL)
            return SentTransferredFile(zipURL)
        }
        .suggestedFileName { _ in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            let stamp = formatter.string(from: Date())
            return "indoorkart_all_\(stamp).zip"
        }
    }

    static func makeZip(of directoryURL: URL) throws -> URL {
        let fm = FileManager.default
        let destURL = fm.temporaryDirectory
            .appendingPathComponent("indoorkart_all_\(UUID().uuidString.prefix(8)).zip")
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: directoryURL,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: destURL)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return destURL
    }
}
