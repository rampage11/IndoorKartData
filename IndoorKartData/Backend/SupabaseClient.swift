import Foundation
import os

/// Клиент Supabase. На данный момент — заглушка без сетевого слоя:
/// проверяет конфиг из Info.plist и логирует намерения. Когда появится
/// проект Supabase, тело методов будет заменено на реальные вызовы URLSession.
///
/// SDK Supabase намеренно не подключаем, чтобы не тащить SPM-зависимости
/// до того, как решим финальную архитектуру синхронизации.
final class SupabaseClient {
    static let shared = SupabaseClient()

    // MARK: - Config

    struct Config {
        let url: URL
        let anonKey: String

        /// Пытаемся собрать конфиг из Info.plist. Если ключей нет или они
        /// пустые — считаем, что клиент работает в офлайн-режиме.
        static func fromInfoPlist(bundle: Bundle = .main) -> Config? {
            guard
                let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
                let anonKey = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
                !urlString.isEmpty,
                !anonKey.isEmpty,
                let url = URL(string: urlString)
            else {
                return nil
            }
            return Config(url: url, anonKey: anonKey)
        }
    }

    enum ClientError: Error, LocalizedError {
        case notConfigured
        case notImplemented
        case sessionDirectoryUnreadable(URL)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Supabase не сконфигурирован (нет SUPABASE_URL/SUPABASE_ANON_KEY в Info.plist)."
            case .notImplemented:
                return "Метод ещё не реализован: ждём подключения backend."
            case .sessionDirectoryUnreadable(let url):
                return "Не удалось прочитать директорию сессии: \(url.path)."
            }
        }
    }

    // MARK: - State

    let config: Config?
    private let logger = Logger(subsystem: "com.indoorkartdata.app", category: "SupabaseClient")

    var isConfigured: Bool { config != nil }

    private init(config: Config? = Config.fromInfoPlist()) {
        self.config = config
        if config == nil {
            logger.notice("SupabaseClient запущен в офлайн-режиме: ключи в Info.plist не найдены.")
        } else {
            logger.notice("SupabaseClient сконфигурирован, URL задан через Info.plist.")
        }
    }

    // MARK: - Auth (stubs)

    func signIn(email: String, password: String) async throws {
        guard isConfigured else { throw ClientError.notConfigured }
        // Планируется: POST {url}/auth/v1/token?grant_type=password
        logger.debug("signIn заглушка: email=\(email, privacy: .private(mask: .hash))")
        throw ClientError.notImplemented
    }

    func signUp(email: String, password: String) async throws {
        guard isConfigured else { throw ClientError.notConfigured }
        // Планируется: POST {url}/auth/v1/signup
        logger.debug("signUp заглушка: email=\(email, privacy: .private(mask: .hash))")
        throw ClientError.notImplemented
    }

    func signOut() async throws {
        guard isConfigured else { throw ClientError.notConfigured }
        // Планируется: POST {url}/auth/v1/logout + очистка локального токена
        logger.debug("signOut заглушка")
        throw ClientError.notImplemented
    }

    // MARK: - Session upload (stub)

    /// Логирует предполагаемый план загрузки сессии и возвращает её UUID из manifest.json.
    /// Реальная загрузка (Storage upload + вставка строк в sessions/session_sources) будет
    /// добавлена, когда появится настоящий Supabase-проект.
    @discardableResult
    func uploadSession(_ sessionURL: URL) async throws -> UUID {
        guard isConfigured else { throw ClientError.notConfigured }

        let manifestURL = sessionURL.appendingPathComponent("manifest.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ClientError.sessionDirectoryUnreadable(sessionURL)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionManifest.self, from: data)

        logger.notice("uploadSession план: id=\(manifest.id.uuidString, privacy: .public), sources=\(manifest.sources.count, privacy: .public)")
        for source in manifest.sources {
            logger.notice("  -> \(source.kind.rawValue, privacy: .public) файл \(source.filename, privacy: .public)")
        }

        throw ClientError.notImplemented
    }
}
