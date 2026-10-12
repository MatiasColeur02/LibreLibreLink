import Foundation

/// Flecha de tendencia tal como la manda LibreLinkUp (`TrendArrow`).
public enum Trend: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case fallingQuickly = 1
    case falling = 2
    case stable = 3
    case rising = 4
    case risingQuickly = 5

    public var arrow: String {
        switch self {
        case .unknown: "?"
        case .fallingQuickly: "↓"
        case .falling: "↘"
        case .stable: "→"
        case .rising: "↗"
        case .risingQuickly: "↑"
        }
    }

    public var label: String {
        switch self {
        case .unknown: String(localized: "Tendencia no disponible")
        case .fallingQuickly: String(localized: "Bajando rápido")
        case .falling: String(localized: "Bajando")
        case .stable: String(localized: "Estable")
        case .rising: String(localized: "Subiendo")
        case .risingQuickly: String(localized: "Subiendo rápido")
        }
    }
}

public struct GlucoseMeasurement: Sendable, Hashable, Codable {
    /// Momento de la medición (de `FactoryTimestamp`, que viene en UTC).
    public let date: Date
    public let mgdL: Double
    /// Solo la medición actual trae tendencia; el historial no.
    public let trend: Trend?
    public let isHigh: Bool
    public let isLow: Bool

    public init(date: Date, mgdL: Double, trend: Trend?, isHigh: Bool = false, isLow: Bool = false) {
        self.date = date
        self.mgdL = mgdL
        self.trend = trend
        self.isHigh = isHigh
        self.isLow = isLow
    }
}

public struct Patient: Sendable, Hashable, Identifiable {
    public let id: String
    public let firstName: String
    public let lastName: String

    public var displayName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct SensorInfo: Sendable, Hashable, Codable {
    public let serial: String
    public let activation: Date

    public init(serial: String, activation: Date) {
        self.serial = serial
        self.activation = activation
    }

    /// Fin esperado asumiendo vida de Libre 2 Plus (15 días).
    public var expectedEnd: Date { activation.addingTimeInterval(GlucoseStatus.sensorLifetime) }
}

public struct GraphResult: Sendable {
    public let current: GlucoseMeasurement?
    /// ~12 h de historial, ordenado por fecha ascendente.
    public let history: [GlucoseMeasurement]
    public let sensor: SensorInfo?
}
