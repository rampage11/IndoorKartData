import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// Обёртка для ShareLink: NSFileCoordinator с .forUploading создаёт zip из
// директории сессии; получатель видит обычный .zip, который корректно
// принимает AirDrop и Files.
struct SessionArchive: Transferable {
    let sessionURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { archive in
            let zipURL = try SessionArchive.makeZip(of: archive.sessionURL)
            return SentTransferredFile(zipURL)
        }
        .suggestedFileName { archive in
            "\(archive.sessionURL.lastPathComponent).zip"
        }
    }

    static func makeZip(of directoryURL: URL) throws -> URL {
        let fm = FileManager.default
        let destURL = fm.temporaryDirectory
            .appendingPathComponent("\(directoryURL.lastPathComponent).zip")
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
