import Foundation

/// Resumen de un período (R24). Ponderado por tiempo: el historial de LibreLinkUp
/// viene cada 5 min y las lecturas en vivo cada 1 min, así que contar puntos sesgaría.
public struct GlucoseStatistics: Sendable, Equatable {
    public let period: DateInterval
    public let readingCount: Int
    /// Promedio ponderado por tiempo, en mg/dL.
    public let mean: Double
    public let standardDeviation: Double
    /// Fracción de tiempo en cada zona (suma 1).
    public let zoneFractions: [GlucoseZone: Double]
    /// Episodios < 70 mg/dL de al menos 15 min.
    public let lowEvents: Int
    /// Fracción del período cubierta por lecturas.
    public let coverage: Double
    /// Días con al menos una lectura.
    public let daysWithData: Int

    /// Coeficiente de variación (%). Se considera estable por debajo de 36 %.
    public var coefficientOfVariation: Double { mean > 0 ? standardDeviation / mean * 100 : 0 }

    /// Indicador de manejo de glucosa (GMI, %), equivalente estimado de HbA1c.
    public var gmi: Double { 3.31 + 0.02392 * mean }

    /// Cuánto se extiende una lectura hasta la siguiente, como máximo.
    public static let maxGap: TimeInterval = 15 * 60
    public static let lowEventThreshold = 70.0
    public static let lowEventMinimum: TimeInterval = 15 * 60

    /// - Parameter readings: ordenadas por fecha; se ignoran las que caen fuera de `period`.
    public static func compute(
        _ readings: [GlucoseMeasurement],
        period: DateInterval,
        display: DisplaySettings,
        calendar: Calendar = .current
    ) -> GlucoseStatistics? {
        let points = readings.filter { period.contains($0.date) }
        guard !points.isEmpty else { return nil }

        var weights: [TimeInterval] = []
        weights.reserveCapacity(points.count)
        for (i, point) in points.enumerated() {
            let next = i + 1 < points.count ? points[i + 1].date : min(period.end, point.date.addingTimeInterval(5 * 60))
            weights.append(min(max(next.timeIntervalSince(point.date), 0), maxGap))
        }
        let total = max(weights.reduce(0, +), 1)

        var sum = 0.0
        var zones: [GlucoseZone: Double] = [:]
        for (point, weight) in zip(points, weights) {
            sum += point.mgdL * weight
            zones[display.zone(point.mgdL), default: 0] += weight
        }
        let mean = sum / total
        let variance = zip(points, weights).reduce(0) { $0 + pow($1.0.mgdL - mean, 2) * $1.1 } / total

        // Episodios de baja: tramos seguidos (sin huecos > maxGap) por debajo de 70.
        var lowEvents = 0
        var runStart: Date?
        var runEnd: Date?
        func closeRun() {
            if let start = runStart, let end = runEnd, end.timeIntervalSince(start) >= lowEventMinimum { lowEvents += 1 }
            runStart = nil
            runEnd = nil
        }
        for (point, weight) in zip(points, weights) {
            if point.mgdL < lowEventThreshold {
                if let end = runEnd, point.date.timeIntervalSince(end) > maxGap { closeRun() }
                if runStart == nil { runStart = point.date }
                runEnd = point.date.addingTimeInterval(weight)
            } else {
                closeRun()
            }
        }
        closeRun()

        let days = Set(points.map { calendar.startOfDay(for: $0.date) }).count
        return GlucoseStatistics(
            period: period,
            readingCount: points.count,
            mean: mean,
            standardDeviation: variance.squareRoot(),
            zoneFractions: zones.mapValues { $0 / total },
            lowEvents: lowEvents,
            coverage: min(total / max(period.duration, 1), 1),
            daysWithData: days
        )
    }
}

/// Patrón de un día típico (AGP): percentiles por hora del día, en mg/dL.
public struct DailyPatternPoint: Sendable, Equatable {
    /// Minutos desde la medianoche (centro del tramo).
    public let minute: Int
    public let p10, p25, p50, p75, p90: Double
}

public enum DailyPattern {
    /// Días con datos necesarios para que el patrón signifique algo (R24).
    public static let minimumDays = 5

    /// Tramos de 30 min; cada uno usa las lecturas de ±30 min alrededor de su centro.
    public static func compute(_ readings: [GlucoseMeasurement], calendar: Calendar = .current) -> [DailyPatternPoint] {
        let minutes = readings.map { reading -> (Int, Double) in
            let parts = calendar.dateComponents([.hour, .minute], from: reading.date)
            return ((parts.hour ?? 0) * 60 + (parts.minute ?? 0), reading.mgdL)
        }
        return stride(from: 0, through: 24 * 60, by: 30).compactMap { center in
            let values = minutes.filter { minute, _ in
                let distance = abs(minute - center)
                return min(distance, 24 * 60 - distance) <= 30
            }.map(\.1).sorted()
            guard values.count >= 5 else { return nil }
            return DailyPatternPoint(
                minute: center,
                p10: percentile(values, 0.10), p25: percentile(values, 0.25), p50: percentile(values, 0.50),
                p75: percentile(values, 0.75), p90: percentile(values, 0.90)
            )
        }
    }

    /// Percentil con interpolación lineal; `sorted` no puede estar vacío.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
