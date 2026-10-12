import Foundation

/// Qué se anota en el registro (R22–R23).
public enum LogKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case carbs, rapidInsulin, longInsulin, exercise, fingerstick, note

    public var id: String { rawValue }

    /// Rango aceptado para `LogEntry.value`; `nil` = no lleva valor.
    /// Insulina en U, carbohidratos en g, ejercicio en min, glucómetro en mg/dL.
    public var valueRange: ClosedRange<Double>? {
        switch self {
        case .carbs: 1...500
        case .rapidInsulin, .longInsulin: 0.5...150
        case .exercise: 1...600
        case .fingerstick: 20...600
        case .note: nil
        }
    }
}

/// Una anotación: comida, insulina, ejercicio, pinchazo con glucómetro o comentario.
public struct LogEntry: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public var date: Date
    public var kind: LogKind
    public var value: Double?
    public var note: String

    public init(id: UUID = UUID(), date: Date, kind: LogKind, value: Double? = nil, note: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.value = value
        self.note = note
    }

    /// Lleva valor si el tipo lo pide y está en rango, o es una nota con texto.
    public var isValid: Bool {
        if let range = kind.valueRange { return value.map(range.contains) ?? false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Momento del día de una comida, para agrupar el análisis.
public enum MealSlot: Int, Sendable, CaseIterable, Identifiable {
    case breakfast, lunch, snack, dinner

    public var id: Int { rawValue }

    /// Desayuno 5–11 h, almuerzo 11–15 h, merienda 15–19 h, cena 19–5 h.
    public init(_ date: Date, calendar: Calendar = .current) {
        switch calendar.component(.hour, from: date) {
        case 5..<11: self = .breakfast
        case 11..<15: self = .lunch
        case 15..<19: self = .snack
        default: self = .dinner
        }
    }
}

/// Qué pasó con la glucosa después de una comida anotada.
public struct MealResponse: Sendable, Equatable {
    public let entry: LogEntry
    /// Glucosa al comer (mg/dL).
    public let start: Double
    public let peak: Double
    public let peakAt: Date
    /// Si superó el rango objetivo y cuándo volvió; `nil` en `backInRangeAt` = no volvió en la ventana.
    public let leftRange: Bool
    public let backInRangeAt: Date?

    public var rise: Double { peak - start }
    public var timeToPeak: TimeInterval { peakAt.timeIntervalSince(entry.date) }
    public var timeToBackInRange: TimeInterval? { backInRangeAt?.timeIntervalSince(entry.date) }
}

/// Diferencia entre un pinchazo con glucómetro y el sensor en ese momento.
public struct FingerstickComparison: Sendable, Equatable {
    public let entry: LogEntry
    public let meter: Double
    public let sensor: Double

    /// Sensor − glucómetro, en mg/dL.
    public var difference: Double { sensor - meter }
    public var relativeDifference: Double { difference / meter }
    /// Criterio 15/15: ±15 mg/dL si el glucómetro da < 100, si no ±15 %.
    public var withinFifteen: Bool {
        meter < 100 ? abs(difference) <= 15 : abs(relativeDifference) <= 0.15
    }
}

public enum Logbook {
    /// Hasta cuándo se mira el pico después de comer.
    public static let peakWindow: TimeInterval = 3 * 3600
    /// Hasta cuándo se espera que vuelva al rango.
    public static let recoveryWindow: TimeInterval = 5 * 3600
    /// Distancia máxima entre la anotación y una lectura del sensor para usarla.
    public static let maxDistance: TimeInterval = 15 * 60

    /// Glucosa del sensor en `date`, interpolada entre las dos lecturas vecinas (o la más
    /// cercana si solo hay una a menos de `maxDistance`).
    /// - Parameter readings: ordenadas por fecha.
    public static func sensorValue(at date: Date, readings: [GlucoseMeasurement]) -> Double? {
        let index = readings.firstIndex { $0.date >= date } ?? readings.endIndex
        let after = index < readings.endIndex ? readings[index] : nil
        let before = index > readings.startIndex ? readings[index - 1] : nil
        if let after, after.date == date { return after.mgdL }
        if let before, let after, after.date.timeIntervalSince(before.date) <= 2 * maxDistance,
           date.timeIntervalSince(before.date) <= maxDistance || after.date.timeIntervalSince(date) <= maxDistance {
            let x = date.timeIntervalSince(before.date) / after.date.timeIntervalSince(before.date)
            return before.mgdL + (after.mgdL - before.mgdL) * x
        }
        let nearest = [before, after].compactMap { $0 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        guard let nearest, abs(nearest.date.timeIntervalSince(date)) <= 5 * 60 else { return nil }
        return nearest.mgdL
    }

    /// Pico y vuelta al rango tras cada comida. Se descartan las que no tienen lecturas
    /// suficientes (al comer y durante la ventana del pico).
    public static func mealResponses(
        _ entries: [LogEntry],
        readings: [GlucoseMeasurement],
        target: ClosedRange<Double>
    ) -> [MealResponse] {
        entries.filter { $0.kind == .carbs }.compactMap { entry in
            guard let start = sensorValue(at: entry.date, readings: readings) else { return nil }
            let window = readings.filter {
                $0.date > entry.date && $0.date <= entry.date.addingTimeInterval(peakWindow)
            }
            // Al menos dos horas cubiertas para que el pico signifique algo.
            guard let last = window.last, last.date.timeIntervalSince(entry.date) >= 2 * 3600,
                  let peak = window.max(by: { $0.mgdL < $1.mgdL }) else { return nil }
            let leftRange = peak.mgdL > target.upperBound
            let backInRange = leftRange
                ? readings.first {
                    $0.date > peak.date && $0.date <= entry.date.addingTimeInterval(recoveryWindow)
                        && $0.mgdL <= target.upperBound
                }?.date
                : nil
            return MealResponse(
                entry: entry, start: start, peak: max(peak.mgdL, start), peakAt: peak.mgdL >= start ? peak.date : entry.date,
                leftRange: leftRange, backInRangeAt: backInRange
            )
        }
    }

    public static func fingerstickComparisons(
        _ entries: [LogEntry],
        readings: [GlucoseMeasurement]
    ) -> [FingerstickComparison] {
        entries.compactMap { entry in
            guard entry.kind == .fingerstick, let meter = entry.value,
                  let sensor = sensorValue(at: entry.date, readings: readings) else { return nil }
            return FingerstickComparison(entry: entry, meter: meter, sensor: sensor)
        }
    }
}

/// Resumen de las comidas de un momento del día.
public struct MealSummary: Sendable, Equatable {
    public let slot: MealSlot
    public let count: Int
    public let averageRise: Double
    public let averageTimeToPeak: TimeInterval
    /// De las que salieron del rango, cuánto tardaron en volver (promedio de las que volvieron).
    public let averageTimeToBackInRange: TimeInterval?
    public let leftRange: Int

    public static func compute(_ responses: [MealResponse], calendar: Calendar = .current) -> [MealSummary] {
        let groups = Dictionary(grouping: responses) { MealSlot($0.entry.date, calendar: calendar) }
        return MealSlot.allCases.compactMap { slot in
            guard let group = groups[slot], !group.isEmpty else { return nil }
            let n = Double(group.count)
            let recoveries = group.compactMap(\.timeToBackInRange)
            return MealSummary(
                slot: slot,
                count: group.count,
                averageRise: group.map(\.rise).reduce(0, +) / n,
                averageTimeToPeak: group.map(\.timeToPeak).reduce(0, +) / n,
                averageTimeToBackInRange: recoveries.isEmpty ? nil : recoveries.reduce(0, +) / Double(recoveries.count),
                leftRange: group.filter(\.leftRange).count
            )
        }
    }
}

/// Error personal del sensor respecto del glucómetro.
public struct FingerstickSummary: Sendable, Equatable {
    public let count: Int
    /// Promedio de sensor − glucómetro (mg/dL): positivo = el sensor marca más.
    public let averageDifference: Double
    /// Diferencia relativa absoluta media (MARD).
    public let mard: Double
    /// Fracción dentro del criterio 15/15.
    public let withinFifteen: Double

    public init?(_ comparisons: [FingerstickComparison]) {
        guard !comparisons.isEmpty else { return nil }
        let n = Double(comparisons.count)
        count = comparisons.count
        averageDifference = comparisons.map(\.difference).reduce(0, +) / n
        mard = comparisons.map { abs($0.relativeDifference) }.reduce(0, +) / n
        withinFifteen = Double(comparisons.filter(\.withinFifteen).count) / n
    }
}
