import Foundation

/// Unidad en que se muestran los valores (R20). Todo se guarda en mg/dL.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case mgdL
    case mmolL

    public static let mmolFactor = 18.0182

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .mgdL: "mg/dL"
        case .mmolL: "mmol/L"
        }
    }

    public func convert(_ mgdL: Double) -> Double {
        self == .mgdL ? mgdL : mgdL / Self.mmolFactor
    }

    /// Valor de una lectura: "LO" < 40 y "HI" > 500 (R2).
    public func reading(_ mgdL: Double) -> String {
        if mgdL < 40 { return "LO" }
        if mgdL > 500 { return "HI" }
        return number(mgdL)
    }

    /// Valor sin "LO"/"HI" (umbrales, promedios). mmol/L con un decimal y coma local.
    public func number(_ mgdL: Double) -> String {
        switch self {
        case .mgdL: "\(Int(mgdL.rounded()))"
        case .mmolL: convert(mgdL).formatted(.number.precision(.fractionLength(1)))
        }
    }

    /// Valor con unidad, p. ej. "70 mg/dL".
    public func withSymbol(_ mgdL: Double) -> String { "\(number(mgdL)) \(symbol)" }
}

/// Zona de una lectura respecto del rango objetivo (lo que define su color).
public enum GlucoseZone: Int, Sendable, CaseIterable, Comparable {
    case below
    case inTarget
    case above

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Preferencias de visualización: unidad y rango objetivo (R21, independiente de las alarmas).
public struct DisplaySettings: Codable, Sendable, Equatable {
    public var unit: GlucoseUnit = .mgdL
    public var targetLow = 70.0
    public var targetHigh = 180.0

    public static let targetLowRange = 60.0...120.0
    public static let targetHighRange = 140.0...250.0

    public init() {}

    public var target: ClosedRange<Double> { targetLow...max(targetLow, targetHigh) }

    public func zone(_ mgdL: Double) -> GlucoseZone {
        if mgdL < targetLow { return .below }
        if mgdL > targetHigh { return .above }
        return .inTarget
    }

    // Tolera claves faltantes para poder agregar preferencias sin perder las guardadas.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decodeIfPresent(GlucoseUnit.self, forKey: .unit) ?? .mgdL
        targetLow = try c.decodeIfPresent(Double.self, forKey: .targetLow) ?? 70
        targetHigh = try c.decodeIfPresent(Double.self, forKey: .targetHigh) ?? 180
    }
}
