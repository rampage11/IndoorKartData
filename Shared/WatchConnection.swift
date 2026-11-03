import Foundation
import WatchConnectivity

enum WatchMessageKey {
    static let command = "command"
    static let sessionID = "sessionID"
    static let startedAt = "startedAt"
    static let filename = "filename"
    static let ack = "ack"
    static let error = "error"
    static let steeringAngle = "steeringAngleRad"
    static let watchWristRateY = "watchWristRateY"
    static let lastLapMs = "lastLapMs"
    static let kartNumber = "kartNumber"
}

enum WatchCommand {
    static let start = "start"
    static let stop = "stop"
    static let watchStart = "watchStart"
    static let watchStop = "watchStop"
    static let steering = "steering"
    static let lastLap = "lastLap"
    // Регулярный ping каждые 2 сек когда app открыт — опора для индикатора
    // "связь жива" на основе last-heard-from, а не flaky isReachable.
    static let heartbeat = "heartbeat"
}

protocol WatchConnectionDelegate: AnyObject {
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveStart sessionID: UUID, startedAt: Date)
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveStop sessionID: UUID)
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveFile url: URL, filename: String, sessionID: UUID)
    @MainActor func watchConnection(_ connection: WatchConnection, reachabilityChanged isReachable: Bool)
    @MainActor func watchConnection(_ connection: WatchConnection, steeringAngleChanged radians: Double, wristRateY: Double)
    @MainActor func watchConnection(_ connection: WatchConnection, lastLapReceivedMs ms: Int)
    @MainActor func watchConnection(_ connection: WatchConnection, kartNumberChanged number: Int)
    // Любое входящее сообщение (включая heartbeat). Используется для
    // last-heard-from индикатора, не привязанного к flaky isReachable.
    @MainActor func watchConnectionDidReceiveAnyMessage(_ connection: WatchConnection)
    // Входящий бинарный батч raw watch IMU (Wave 2 live-compare). iPhone
    // форвардит его на katahub-бэкенд через отдельный WS.
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveImuBatch data: Data)
}

extension WatchConnectionDelegate {
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveStart sessionID: UUID, startedAt: Date) {}
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveStop sessionID: UUID) {}
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveFile url: URL, filename: String, sessionID: UUID) {}
    @MainActor func watchConnection(_ connection: WatchConnection, reachabilityChanged isReachable: Bool) {}
    @MainActor func watchConnection(_ connection: WatchConnection, steeringAngleChanged radians: Double, wristRateY: Double = 0) {}
    @MainActor func watchConnection(_ connection: WatchConnection, lastLapReceivedMs ms: Int) {}
    @MainActor func watchConnection(_ connection: WatchConnection, kartNumberChanged number: Int) {}
    @MainActor func watchConnectionDidReceiveAnyMessage(_ connection: WatchConnection) {}
    @MainActor func watchConnection(_ connection: WatchConnection, didReceiveImuBatch data: Data) {}
}

final class WatchConnection: NSObject {
    static let shared = WatchConnection()

    weak var delegate: WatchConnectionDelegate?

    private let session: WCSession?

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
        startHeartbeat()
    }

    private var heartbeatTimer: Timer?

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }

    private func sendHeartbeat() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let payload: [String: Any] = [WatchMessageKey.command: WatchCommand.heartbeat]
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    var isReachable: Bool {
        session?.isReachable ?? false
    }

    var isCompanionInstalled: Bool {
        guard let session else { return false }
        #if os(iOS)
        return session.isPaired && session.isWatchAppInstalled
        #else
        return session.isCompanionAppInstalled
        #endif
    }

    @discardableResult
    func sendStart(sessionID: UUID, startedAt: Date, reply: ((Bool, String?) -> Void)? = nil) -> Bool {
        let payload: [String: Any] = [
            WatchMessageKey.command: WatchCommand.start,
            WatchMessageKey.sessionID: sessionID.uuidString,
            WatchMessageKey.startedAt: startedAt.timeIntervalSince1970
        ]
        return send(payload: payload, reply: reply)
    }

    @discardableResult
    func sendStop(sessionID: UUID, reply: ((Bool, String?) -> Void)? = nil) -> Bool {
        let payload: [String: Any] = [
            WatchMessageKey.command: WatchCommand.stop,
            WatchMessageKey.sessionID: sessionID.uuidString
        ]
        // Критичная команда — дублируем через оба канала (см. sendWatchStop).
        guard let session, session.activationState == .activated else {
            reply?(false, "WCSession не активна")
            return false
        }
        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        reply?(true, nil)
        return true
    }

    @discardableResult
    func sendWatchStart(sessionID: UUID, startedAt: Date) -> Bool {
        let payload: [String: Any] = [
            WatchMessageKey.command: WatchCommand.watchStart,
            WatchMessageKey.sessionID: sessionID.uuidString,
            WatchMessageKey.startedAt: startedAt.timeIntervalSince1970
        ]
        return send(payload: payload, reply: nil)
    }

    @discardableResult
    func sendWatchStop(sessionID: UUID) -> Bool {
        let payload: [String: Any] = [
            WatchMessageKey.command: WatchCommand.watchStop,
            WatchMessageKey.sessionID: sessionID.uuidString
        ]
        // Критичная команда — отправляем ОБОИМИ путями одновременно.
        // sendMessage быстрый (мгновенно если iPhone в foreground), но когда
        // iPhone backgrounded — iOS считает что доставила, а приложение
        // обработает только при next wake, задержка 10-30с.
        // transferUserInfo гарантирован, может быть немного медленнее при
        // foreground, но доставит даже в suspended состоянии через 1-2с.
        // iPhone-сторона идемпотентна — дубликат stop = no-op.
        guard let session, session.activationState == .activated else { return false }
        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        return true
    }

    // Живой стрим: raw attitude.yaw + текущая rotationRate.y (для детектора
    // неподвижности запястья на iPhone-стороне). Шлём только если reachable;
    // устаревшие значения не нужны.
    func sendSteeringAngle(_ yawRadians: Double, wristRateY: Double = 0) {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let payload: [String: Any] = [
            WatchMessageKey.command: WatchCommand.steering,
            WatchMessageKey.steeringAngle: yawRadians,
            WatchMessageKey.watchWristRateY: wristRateY
        ]
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    // iPhone → Watch: последнее время круга из RaceMann (мс). Если часы не
    // reachable, кладём в очередь transferUserInfo — пилот увидит с задержкой,
    // но увидит.
    func sendLastLap(_ ms: Int) {
        guard let session, session.activationState == .activated else { return }
        let payload: [String: Any] = [
            WatchMessageKey.command: WatchCommand.lastLap,
            WatchMessageKey.lastLapMs: ms
        ]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                session.transferUserInfo(payload)
            })
        } else {
            session.transferUserInfo(payload)
        }
    }

    // Эагерная синхронизация номера карта через applicationContext.
    // iOS сам доставит последнее значение, дубликаты не шлёт.
    func updateKartNumber(_ number: Int) {
        guard let session, session.activationState == .activated else { return }
        let payload: [String: Any] = [WatchMessageKey.kartNumber: number]
        try? session.updateApplicationContext(payload)
    }

    private func send(payload: [String: Any], reply: ((Bool, String?) -> Void)?) -> Bool {
        guard let session, session.activationState == .activated else {
            reply?(false, "WCSession не активна")
            return false
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { response in
                let ack = response[WatchMessageKey.ack] as? Bool ?? false
                let err = response[WatchMessageKey.error] as? String
                reply?(ack, err)
            }, errorHandler: { error in
                // Если sendMessage упал, пробуем очередь: команда дойдёт, когда часы оживут.
                session.transferUserInfo(payload)
                reply?(false, error.localizedDescription)
            })
            return true
        } else if isCompanionInstalled {
            session.transferUserInfo(payload)
            reply?(false, "Компаньон не на связи, команда поставлена в очередь")
            return false
        } else {
            reply?(false, "Компаньон не установлен")
            return false
        }
    }

    func transferSessionFile(_ url: URL, filename: String, sessionID: UUID) {
        guard let session, session.activationState == .activated else { return }
        let metadata: [String: Any] = [
            WatchMessageKey.sessionID: sessionID.uuidString,
            WatchMessageKey.filename: filename
        ]
        session.transferFile(url, metadata: metadata)
    }

    // Watch → iPhone: 1-секундный батч raw IMU в бинарном формате
    // WatchIMUBatchFormat. Используется sendMessageData (не JSON) чтобы
    // не раздувать трафик base64-кодированием. Батч шлётся только когда
    // iPhone reachable; дропнутые батчи не ретраятся — живой стрим это
    // advisory, authoritative остаётся watch_imu.bin.
    func sendImuBatch(_ data: Data) {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }
}

extension WatchConnection: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.delegate?.watchConnection(self, reachabilityChanged: reachable)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.delegate?.watchConnection(self, reachabilityChanged: reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleIncoming(message, replyHandler: replyHandler)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message, replyHandler: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(userInfo, replyHandler: nil)
    }

    // Бинарные данные: только Wave-2 raw IMU батчи с часов. Любой приём
    // обновляет last-heard-from (как и обычные сообщения).
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        let data = messageData
        Task { @MainActor in
            self.delegate?.watchConnectionDidReceiveAnyMessage(self)
            self.delegate?.watchConnection(self, didReceiveImuBatch: data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let data = messageData
        Task { @MainActor in
            self.delegate?.watchConnectionDidReceiveAnyMessage(self)
            self.delegate?.watchConnection(self, didReceiveImuBatch: data)
        }
        replyHandler(Data())
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let number = applicationContext[WatchMessageKey.kartNumber] as? Int {
            Task { @MainActor in
                self.delegate?.watchConnection(self, kartNumberChanged: number)
            }
        }
    }

    private nonisolated func handleIncoming(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        let command = message[WatchMessageKey.command] as? String

        // Любое входящее сообщение обновляет last-heard-from. Это основа
        // индикатора связи, не привязанного к flaky isReachable.
        Task { @MainActor in
            self.delegate?.watchConnectionDidReceiveAnyMessage(self)
        }

        // Heartbeat — отдельный no-op для просто обновления last-heard-from.
        if command == WatchCommand.heartbeat {
            return
        }

        // steering: не требует sessionID, прилетает 20Гц, обрабатываем отдельно без ack.
        if command == WatchCommand.steering {
            if let angle = message[WatchMessageKey.steeringAngle] as? Double {
                let wristRate = message[WatchMessageKey.watchWristRateY] as? Double ?? 0
                Task { @MainActor in
                    self.delegate?.watchConnection(self, steeringAngleChanged: angle, wristRateY: wristRate)
                }
            }
            return
        }

        // lastLap: iPhone → Watch, без sessionID.
        if command == WatchCommand.lastLap {
            if let ms = message[WatchMessageKey.lastLapMs] as? Int {
                Task { @MainActor in
                    self.delegate?.watchConnection(self, lastLapReceivedMs: ms)
                }
            }
            replyHandler?([WatchMessageKey.ack: true])
            return
        }

        let sessionIDString = message[WatchMessageKey.sessionID] as? String
        let startedAtEpoch = message[WatchMessageKey.startedAt] as? Double

        guard let command, let sessionIDString, let uuid = UUID(uuidString: sessionIDString) else {
            replyHandler?([WatchMessageKey.ack: false, WatchMessageKey.error: "Некорректный пакет"])
            return
        }

        let startedAt: Date? = startedAtEpoch.map { Date(timeIntervalSince1970: $0) }

        Task { @MainActor in
            switch command {
            case WatchCommand.start:
                self.delegate?.watchConnection(self, didReceiveStart: uuid, startedAt: startedAt ?? Date())
            case WatchCommand.stop:
                self.delegate?.watchConnection(self, didReceiveStop: uuid)
            case WatchCommand.watchStart:
                self.delegate?.watchConnection(self, didReceiveStart: uuid, startedAt: startedAt ?? Date())
            case WatchCommand.watchStop:
                self.delegate?.watchConnection(self, didReceiveStop: uuid)
            default:
                break
            }
        }

        replyHandler?([WatchMessageKey.ack: true])
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let filename = (metadata[WatchMessageKey.filename] as? String) ?? file.fileURL.lastPathComponent
        let sessionIDString = metadata[WatchMessageKey.sessionID] as? String
        let sessionID = sessionIDString.flatMap { UUID(uuidString: $0) }

        // Файл WatchConnectivity удалит после возврата из этого колбэка; копируем во временное место синхронно.
        let fm = FileManager.default
        let tempURL = fm.temporaryDirectory.appendingPathComponent("wc_\(UUID().uuidString)_\(filename)")
        do {
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            try fm.copyItem(at: file.fileURL, to: tempURL)
        } catch {
            return
        }

        guard let sessionID else { return }

        Task { @MainActor in
            self.delegate?.watchConnection(self, didReceiveFile: tempURL, filename: filename, sessionID: sessionID)
        }
    }
}
