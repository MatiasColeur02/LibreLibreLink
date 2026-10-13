import Foundation

/// Estimación de hacia dónde va la glucosa (R8): recta por mínimos cuadrados sobre las
/// lecturas recientes. LibreLink tiene "glucosa proyectada" pero desactivada en la build
/// regional (`NAIProjectedGlucose=false`); esto es propio y es solo una estimación.
public enum GlucoseForecast {
    /// Lecturas que se usan, hacia atrás desde la última.
    public static let window: TimeInterval = 15 * 60
    /// Cuánto hacia adelante se avisa (como el mensaje de tendencia de la guía, p. 32).
    public static let horizon: TimeInterval = 15 * 60
    /// Solo con caída clara: la flecha "bajando" de LibreLink empieza en −1 mg/dL/min.
    public static let minimumFall = -1.0
    /// "Bajando rápido": la flecha ↓ de LibreLink empieza en −2 mg/dL/min.
    public static let fastFall = -2.0

    /// Pendiente en mg/dL por minuto, o `nil` si hay menos de 3 lecturas o abarcan < 10 min.
    public static func slope(_ readings: [GlucoseMeasurement], latest: GlucoseMeasurement) -> Double? {
        let points = (readings + [latest])
            .filter { $0.date <= latest.date && latest.date.timeIntervalSince($0.date) <= window }
            .reduce(into: [Date: Double]()) { $0[$1.date] = $1.mgdL }
            .map { (x: $0.key.timeIntervalSince(latest.date) / 60, y: $0.value) }
        guard points.count >= 3,
              let first = points.map(\.x).min(), -first >= 10 else { return nil }
        let n = Double(points.count)
        let meanX = points.map(\.x).reduce(0, +) / n
        let meanY = points.map(\.y).reduce(0, +) / n
        let sxx = points.reduce(0) { $0 + pow($1.x - meanX, 2) }
        let sxy = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// Cuándo bajaría de `threshold` si sigue al ritmo actual, si es dentro del horizonte.
    public static func lowCrossing(
        below threshold: Double,
        readings: [GlucoseMeasurement],
        latest: GlucoseMeasurement,
        now: Date
    ) -> Date? {
        guard latest.mgdL >= threshold,
              let slope = slope(readings, latest: latest), slope <= minimumFall else { return nil }
        let crossing = max(latest.date.addingTimeInterval((latest.mgdL - threshold) / -slope * 60), now)
        return crossing.timeIntervalSince(now) <= horizon ? crossing : nil
    }

    /// Baja a −2 mg/dL/min o más rápido, según la flecha de LibreLinkUp o la pendiente reciente.
    public static func isFallingFast(_ readings: [GlucoseMeasurement], latest: GlucoseMeasurement) -> Bool {
        if latest.trend == .fallingQuickly { return true }
        return slope(readings, latest: latest).map { $0 <= fastFall } ?? false
    }
}
