import Foundation

@MainActor
final class SessionsStore: ObservableObject {
    struct Item: Identifiable {
        let id: UUID
        let url: URL
        let manifest: SessionManifest
        var durationSeconds: TimeInterval?
    }

    @Published private(set) var items: [Item] = []

    func reload() {
        do {
            let urls = try SessionStorage.shared.listSessions()
            let loaded: [Item] = urls.compactMap { url in
                guard let manifest = try? SessionStorage.shared.loadManifest(sessionURL: url) else {
                    return nil
                }
                let duration: TimeInterval? = manifest.endedAt.map { $0.timeIntervalSince(manifest.startedAt) }
                return Item(id: manifest.id, url: url, manifest: manifest, durationSeconds: duration)
            }
            // listSessions уже сортирует по дате создания папки; доверяем ему.
            items = loaded
        } catch {
            items = []
        }
    }

    func delete(url: URL) {
        try? SessionStorage.shared.deleteSession(sessionURL: url)
        items.removeAll { $0.url == url }
    }

    func deleteAll() {
        for item in items {
            try? SessionStorage.shared.deleteSession(sessionURL: item.url)
        }
        items.removeAll()
    }
}
