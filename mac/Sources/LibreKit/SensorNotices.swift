import Foundation

/// Avisos del ciclo de vida del sensor (R19): nuevo, listo tras el calentamiento, termina
/// en 3 días / 1 día / 1 hora y terminado. Como en LibreLink (`SensorNotificationType`).
public enum SensorNotice: String, Codable, Sendable, CaseIterable {
    case newSensor, ready, endsIn3Days, endsIn1Day, endsIn1Hour, ended

    /// Cuándo corresponde; `nil` para `newSensor`, que depende de ver otro número de serie.
    public func date(for sensor: SensorInfo) -> Date? {
        switch self {
        case .newSensor: nil
        case .ready: sensor.readyAt
        case .endsIn3Days: sensor.expectedEnd.addingTimeInterval(-3 * 86_400)
        case .endsIn1Day: sensor.expectedEnd.addingTimeInterval(-86_400)
        case .endsIn1Hour: sensor.expectedEnd.addingTimeInterval(-3600)
        case .ended: sensor.expectedEnd
        }
    }

    /// Pasado este tiempo ya no tiene sentido avisar ("listo" horas después no sirve).
    var maxDelay: TimeInterval? {
        self == .ready ? 3600 : nil
    }
}

/// Decide qué aviso del sensor mandar. Cada aviso sale una sola vez por sensor; si pasaron
/// varios juntos (la app estuvo cerrada), solo el más reciente. Guardarlo entre reinicios.
public struct SensorNoticeEngine: Codable, Sendable, Equatable {
    public private(set) var serial: String?
    public private(set) var notified: Set<SensorNotice> = []

    public init() {}

    /// - Returns: el aviso a mostrar ahora, si hay.
    public mutating func update(sensor: SensorInfo?, now: Date) -> SensorNotice? {
        guard let sensor else { return nil }
        let passed = Set(SensorNotice.allCases.filter { notice in
            notice.date(for: sensor).map { $0 <= now } ?? false
        })
        guard serial == sensor.serial else {
            // El primer sensor que se ve se adopta en silencio; uno distinto es un cambio.
            let isChange = serial != nil
            serial = sensor.serial
            notified = passed
            return isChange ? .newSensor : nil
        }
        let due = passed.subtracting(notified)
        notified.formUnion(due)
        return due
            .compactMap { notice in notice.date(for: sensor).map { (notice, $0) } }
            .filter { notice, date in notice.maxDelay.map { now.timeIntervalSince(date) <= $0 } ?? true }
            .max { $0.1 < $1.1 }?.0
    }
}
