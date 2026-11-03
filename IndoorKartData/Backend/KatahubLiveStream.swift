#if os(iOS)
import Foundation

// Лёгкий WS-стример живой телеметрии на katahub. iPhone открывает WS на
// старте сессии, шлёт один payload в 500 мс (= 2 Гц): a_long, a_lat, |a_h|,
// yaw rate, текущий круг. Этого достаточно чтобы admin dashboard оживал
// на реальной сессии без заливки сырого 100 Гц IMU по сети.
//
// Поток идёт через URLSessionWebSocketTask. Dropped-frames не ретраятся —
// при реальной нагрузке важнее актуальность текущих показателей чем
// гарантированная доставка каждого фрейма.
@MainActor
final class KatahubLiveStream {
    static let shared = KatahubLiveStream()

    private var task: URLSessionWebSocketTask?
    // Второй WS специально для raw watch IMU: бинарные фреймы ~8.8 КБ/с,
    // отдельно от JSON-канала чтобы два потока не блокировали друг друга.
    private var watchImuTask: URLSessionWebSocketTask?
    private var sessionID: UUID?
    private var hostURLBase: String?
    private var urlSession: URLSession = URLSession(configuration: .default)

    func start(sessionID: UUID, hostURL: String) {
        guard self.sessionID != sessionID else { return }
        stop()
        guard let base = URL(string: hostURL) else { return }
        self.hostURLBase = hostURL
        // https:// → wss://, http:// → ws://
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        let scheme = comps.scheme
        comps.scheme = (scheme == "https") ? "wss" : "ws"
        comps.path = "/live/\(sessionID.uuidString.lowercased())/publish"
        guard let wsURL = comps.url else { return }

        self.sessionID = sessionID
        let t = urlSession.webSocketTask(with: wsURL)
        t.resume()
        self.task = t
        receiveLoop()
        // Watch IMU WS открываем лениво на первом батче — Watch может так
        // и не прислать ни одного (например, пилот без часов), не держим
        // идле-коннекшн зря.
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        watchImuTask?.cancel(with: .goingAway, reason: nil)
        watchImuTask = nil
        sessionID = nil
        hostURLBase = nil
    }

    // Публикация одного фрейма телеметрии. Все числа опциональны — пропущенные
    // поля dashboard просто игнорит.
    func publishTelemetry(aLong: Double?, aLat: Double?, ah: Double?,
                          yawRateDeg: Double?, yawRad: Double? = nil,
                          phase: String? = nil, slipStrength: Double? = nil,
                          lap: Int?) {
        guard let task else { return }
        var payload: [String: Any] = [:]
        if let v = aLong { payload["aLong"] = v }
        if let v = aLat { payload["aLat"] = v }
        if let v = ah { payload["ah"] = v }
        if let v = yawRateDeg { payload["yawRateDeg"] = v }
        if let v = yawRad { payload["yawRad"] = v }
        if let v = phase { payload["phase"] = v }
        if let v = slipStrength { payload["slip"] = v }
        if let v = lap { payload["lap"] = v }
        let event: [String: Any] = [
            "kind": "telemetry",
            "wallNs": Int(Date().timeIntervalSince1970 * 1_000_000_000),
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        task.send(.data(data)) { _ in /* drop silently */ }
    }

    // События помечающие важные моменты (новый круг, срыв, т.д.).
    func publishEvent(kind: String, payload: [String: Any]) {
        guard let task else { return }
        let event: [String: Any] = [
            "kind": kind,
            "wallNs": Int(Date().timeIntervalSince1970 * 1_000_000_000),
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        task.send(.data(data)) { _ in }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            // Нам не присылают ничего обратно, но URLSession требует, чтобы
            // мы потребляли входящий поток, иначе соединение закроется.
            switch result {
            case .success:
                Task { @MainActor in self.receiveLoop() }
            case .failure:
                return
            }
        }
    }

    // Публикация бинарного батча raw watch IMU на отдельный WS эндпоинт.
    // Открывает соединение лениво на первом вызове; дропнутые батчи не
    // ретраятся (advisory поток, authoritative — watch_imu.bin).
    func publishWatchImuBatch(_ data: Data) {
        guard let sessionID else { return }
        if watchImuTask == nil {
            openWatchImuWS(sessionID: sessionID)
        }
        guard let task = watchImuTask else { return }
        task.send(.data(data)) { [weak self] err in
            guard err != nil else { return }
            // При ошибке дропаем сокет, следующий батч попробует переоткрыть.
            Task { @MainActor in
                self?.watchImuTask?.cancel(with: .goingAway, reason: nil)
                self?.watchImuTask = nil
            }
        }
    }

    private func openWatchImuWS(sessionID: UUID) {
        guard let base = hostURLBase, let baseURL = URL(string: base) else { return }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/live/\(sessionID.uuidString.lowercased())/watch-imu"
        guard let wsURL = comps.url else { return }
        let t = urlSession.webSocketTask(with: wsURL)
        t.resume()
        watchImuTask = t
        // Receive loop — чтобы соединение не упало по idle. Backend нам
        // ничего не шлёт, просто читаем в пустоту.
        receiveWatchImuLoop()
    }

    private func receiveWatchImuLoop() {
        watchImuTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Task { @MainActor in self.receiveWatchImuLoop() }
            case .failure:
                Task { @MainActor in
                    self.watchImuTask = nil
                }
            }
        }
    }
}
#endif
