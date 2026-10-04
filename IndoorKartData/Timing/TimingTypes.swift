import Foundation

// MARK: - Negotiate

struct SignalRNegotiateResponse: Decodable {
    let ConnectionToken: String
    let ConnectionId: String
    let TryWebSockets: Bool
    let ProtocolVersion: String
    let KeepAliveTimeout: Double?
    let DisconnectTimeout: Double?
    let TransportConnectTimeout: Double?
}

struct SignalRStartResponse: Decodable {
    let Response: String
}

// MARK: - WS envelopes

// Входящий envelope: {C, M: [HubCall]} либо {I, R}/{I, E} в ответ на Invoke,
// либо просто {} как keep-alive. Делаем все поля опциональными, чтобы один тип
// покрывал все три случая без лишних перегрузок декодера.
struct SignalRIncoming: Decodable {
    let C: String?
    let M: [SignalRHubCall]?
    let I: SignalRInvocationID?
    let R: AnyCodable?
    let E: String?
}

struct SignalRHubCall: Decodable {
    let H: String
    let M: String
    let A: [AnyCodable]
}

enum SignalRInvocationID: Decodable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .int(i); return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s); return
        }
        throw DecodingError.typeMismatch(
            SignalRInvocationID.self,
            .init(codingPath: decoder.codingPath, debugDescription: "I is not Int or String")
        )
    }

    var stringValue: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
}

// Исходящий invoke: {H, M, A, I}
struct SignalRInvoke: Encodable {
    let H: String
    let M: String
    let A: [AnyCodable]
    let I: Int
}

// MARK: - AnyCodable (минимальный)

// Нужен, чтобы прокидывать произвольные JSON-значения как аргументы hub-методов
// и как payload входящих команд, не плодя десятки конкретных типов.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map { $0.value }; return
        }
        if let obj = try? c.decode([String: AnyCodable].self) {
            self.value = obj.mapValues { $0.value }; return
        }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try c.encodeNil()
        case let b as Bool:
            try c.encode(b)
        case let i as Int:
            try c.encode(i)
        case let d as Double:
            try c.encode(d)
        case let s as String:
            try c.encode(s)
        case let arr as [Any]:
            try c.encode(arr.map { AnyCodable($0) })
        case let obj as [String: Any]:
            try c.encode(obj.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsupported value")
            )
        }
    }
}

// MARK: - RaceMann payloads

struct NewCommandEnvelope: Decodable {
    let Time: Int
    let Method: String
    let Command: AnyCodable
    let IsWideSpread: Bool?
}

struct HeartbeatCommand: Decodable {
    let tg: Int?
    let lg: Int?
    let lc: Int?
    let schl: Int?
    let fl: String?
}

struct CompetitorCommand: Decodable {
    let fn: String?
    let rn: String?
    let nn: String?
    let ll: Int?
    let bl: Int?
    let bs1: Int?
    let bs2: Int?
    let bs3: Int?
    let lc: Int?
    let pos: Int?
    let pd: GapInfo?
    let ld: GapInfo?
    let fd: Int?
    let S1: Int?
    let S2: Int?
    let S3: Int?
    let vl: Int?
    let vms: Int?
    let vlc: Int?
    let vpt: Int?
    let pt: Int?
    let pc: Int?
    let pdc: Int?
    let drv: String?
    let drv_ex_id: String?
    let mgr: String?
    let Car: String?
    // InPit может быть null или объектом — опускаем декодирование, достаточно факта наличия
}

struct GapInfo: Decodable {
    let Laps: Int
    let Time: Int
}

struct LastRaceIdPayload: Decodable {
    let id: String
    let raceTime: Double
}
