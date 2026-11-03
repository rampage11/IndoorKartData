#if os(iOS)
import Foundation

// Клиент загрузки сессий на katahub (kart.katahub.ru). Создаёт zip из
// директории сессии и шлёт multipart-free POST с Content-Type: application/zip —
// бэкенд читает тело как сырой zip и достаёт manifest.json изнутри.
//
// Загрузка идёт по UUID из manifest: повторный upload того же sessionID на
// бэкенде делает UPSERT и перезаписывает payload.zip. Это удобно для
// late-arriving Watch-файлов — после merge-а можно просто перезалить.
@MainActor
final class KatahubClient: ObservableObject {
    static let shared = KatahubClient()

    @Published private(set) var isUploading: Bool = false
    @Published private(set) var lastResult: String?
    // reachable отражает доступность сервера по /healthz. Проверяется при
    // старте приложения и периодически — badge зеленеет сразу, а не только
    // после первой удачной загрузки.
    @Published private(set) var isReachable: Bool = false
    @Published var hostURL: String {
        didSet {
            UserDefaults.standard.set(hostURL, forKey: Keys.host)
            Task { await pingHealth() }
        }
    }
    @Published var autoUpload: Bool {
        didSet { UserDefaults.standard.set(autoUpload, forKey: Keys.autoUpload) }
    }

    private enum Keys {
        static let host = "katahub.hostURL"
        static let autoUpload = "katahub.autoUpload"
    }

    private var healthTimer: Timer?

    private init() {
        self.hostURL = UserDefaults.standard.string(forKey: Keys.host) ?? "https://kart.katahub.ru"
        self.autoUpload = UserDefaults.standard.object(forKey: Keys.autoUpload) as? Bool ?? true
        // Первая проверка сразу, затем каждые 30с. На cold-start это
        // гарантирует что badge отразит реальный статус до первой сессии.
        Task { await pingHealth() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await KatahubClient.shared.pingHealth() }
        }
    }

    func pingHealth() async {
        guard let base = URL(string: hostURL),
              let url = URL(string: "/healthz", relativeTo: base) else {
            isReachable = false
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                isReachable = true
                return
            }
        } catch {
            // Молча — обновим флаг
        }
        isReachable = false
    }

    func uploadSession(at sessionURL: URL) async {
        guard autoUpload else { return }
        isUploading = true
        defer { isUploading = false }

        do {
            let zipURL = try SessionArchive.makeZip(of: sessionURL)
            defer { try? FileManager.default.removeItem(at: zipURL) }

            guard let base = URL(string: hostURL) else {
                lastResult = "katahub: некорректный host URL"
                return
            }
            let endpoint = base.appendingPathComponent("sessions")
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            req.setValue(sessionURL.lastPathComponent, forHTTPHeaderField: "X-Katahub-Session-Dir")
            req.timeoutInterval = 120

            let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: zipURL)
            let http = resp as? HTTPURLResponse
            if let http, (200..<300).contains(http.statusCode) {
                lastResult = "katahub: загружено (\(http.statusCode))"
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                lastResult = "katahub: HTTP \(http?.statusCode ?? -1) \(body.prefix(120))"
            }
        } catch {
            lastResult = "katahub: \(error.localizedDescription)"
        }
    }
}
#endif
