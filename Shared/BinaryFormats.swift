import Foundation

/// Фиксированный layout бинарной записи семпла IMU. Little-endian, packed.
/// 96 байт на семпл. При 100 Гц: 9.6 КБ/с ≈ 34 МБ/час.
struct IMUSampleBinary {
    var timestampNs: UInt64
    var userAccelX: Double
    var userAccelY: Double
    var userAccelZ: Double
    var rotationRateX: Double
    var rotationRateY: Double
    var rotationRateZ: Double
    var attitudeQW: Double
    var attitudeQX: Double
    var attitudeQY: Double
    var attitudeQZ: Double

    static let byteSize: Int = 96
}

/// Бинарная запись одного значения пульса.
/// 16 байт на запись: 8 ts + 8 bpm. Поток редкий (несколько записей в секунду).
struct HeartRateSampleBinary {
    var timestampNs: UInt64
    var bpm: Double

    static let byteSize: Int = 16
}

/// Запись бинарного семпла в поток без лишних аллокаций.
extension FileHandle {
    func writeIMUSample(_ sample: IMUSampleBinary) throws {
        var s = sample
        let data = withUnsafeBytes(of: &s) { Data($0) }
        try write(contentsOf: data)
    }

    func writeHeartRateSample(_ sample: HeartRateSampleBinary) throws {
        var s = sample
        let data = withUnsafeBytes(of: &s) { Data($0) }
        try write(contentsOf: data)
    }
}
