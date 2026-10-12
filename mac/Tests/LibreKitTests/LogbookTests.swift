import Foundation
import Testing
@testable import LibreKit

private let t0 = Date(timeIntervalSince1970: 1_791_800_000)

private func series(_ values: [Double], every minutes: Double = 5, from start: Date = t0) -> [GlucoseMeasurement] {
    values.enumerated().map { i, v in
        GlucoseMeasurement(date: start.addingTimeInterval(Double(i) * minutes * 60), mgdL: v, trend: nil)
    }
}

@Test func entriesRoundTripThroughDatabase() throws {
    let db = try HistoryDatabase(url: nil)
    var meal = LogEntry(date: t0, kind: .carbs, value: 45, note: "Pizza")
    let note = LogEntry(date: t0.addingTimeInterval(600), kind: .note, note: "Estrés")
    try db.save(meal, patientID: "a")
    try db.save(note, patientID: "a")
    try db.save(LogEntry(date: t0, kind: .rapidInsulin, value: 4), patientID: "b")

    let all = DateInterval(start: t0.addingTimeInterval(-3600), duration: 7200)
    #expect(try db.entries(patientID: "a", in: all) == [meal, note])

    meal.value = 60
    try db.save(meal, patientID: "a")
    try db.deleteEntry(id: note.id)
    #expect(try db.entries(patientID: "a", in: all) == [meal])
    #expect(try db.entries(patientID: "b", in: all).count == 1)
}

@Test func entryValidation() {
    #expect(LogEntry(date: t0, kind: .carbs, value: 45).isValid)
    #expect(!LogEntry(date: t0, kind: .carbs).isValid)
    #expect(!LogEntry(date: t0, kind: .fingerstick, value: 5.5).isValid)
    #expect(!LogEntry(date: t0, kind: .note, note: "  ").isValid)
    #expect(LogEntry(date: t0, kind: .note, note: "Hipo leve").isValid)
}

@Test func sensorValueInterpolates() {
    let readings = series([100, 110, 120])
    #expect(Logbook.sensorValue(at: t0.addingTimeInterval(150), readings: readings) == 105)
    #expect(Logbook.sensorValue(at: t0.addingTimeInterval(300), readings: readings) == 110)
    // Hasta 5 min fuera de las lecturas; más lejos, nada.
    #expect(Logbook.sensorValue(at: t0.addingTimeInterval(-240), readings: readings) == 100)
    #expect(Logbook.sensorValue(at: t0.addingTimeInterval(-900), readings: readings) == nil)
    // Un hueco de una hora no se interpola.
    let gap = series([100]) + series([200], from: t0.addingTimeInterval(3600))
    #expect(Logbook.sensorValue(at: t0.addingTimeInterval(1800), readings: gap) == nil)
}

@Test func mealResponseFindsPeakAndReturnToRange() throws {
    // Sube de 100 a 220 en 1 h, baja y vuelve a 180 a las 2 h; 4 h de lecturas.
    let values = (0...48).map { i -> Double in
        let minutes = Double(i * 5)
        return minutes <= 60 ? 100 + 2 * minutes : max(100, 220 - (minutes - 60))
    }
    let readings = series(values)
    let meal = LogEntry(date: t0, kind: .carbs, value: 60)
    let response = try #require(Logbook.mealResponses([meal], readings: readings, target: 70...180).first)
    #expect(response.start == 100)
    #expect(response.peak == 220)
    #expect(response.rise == 120)
    #expect(abs(response.timeToPeak - 3600) < 0.001)
    #expect(response.leftRange)
    #expect(abs((response.timeToBackInRange ?? 0) - 100 * 60) < 0.001)

    // Sin lecturas suficientes después de comer, no hay análisis.
    #expect(Logbook.mealResponses([meal], readings: Array(readings.prefix(12)), target: 70...180).isEmpty)
    // Sin salir del rango.
    let flat = try #require(Logbook.mealResponses([meal], readings: series(Array(repeating: 120, count: 40)), target: 70...180).first)
    #expect(!flat.leftRange && flat.backInRangeAt == nil && flat.rise == 0)
}

@Test func mealSummaryGroupsBySlot() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let day = calendar.startOfDay(for: t0)
    func response(hour: Double, rise: Double, back: TimeInterval?) -> MealResponse {
        let date = day.addingTimeInterval(hour * 3600)
        return MealResponse(entry: LogEntry(date: date, kind: .carbs, value: 50), start: 100, peak: 100 + rise,
                            peakAt: date.addingTimeInterval(3600), leftRange: back != nil,
                            backInRangeAt: back.map { date.addingTimeInterval($0) })
    }
    let summaries = MealSummary.compute([
        response(hour: 8, rise: 40, back: nil),
        response(hour: 9, rise: 80, back: 7200),
        response(hour: 21, rise: 100, back: 3600),
    ], calendar: calendar)
    #expect(summaries.map(\.slot) == [.breakfast, .dinner])
    #expect(summaries[0].count == 2 && summaries[0].averageRise == 60)
    #expect(summaries[0].averageTimeToBackInRange == 7200 && summaries[0].leftRange == 1)
    #expect(MealSlot(day.addingTimeInterval(2 * 3600), calendar: calendar) == .dinner)
}

@Test func fingerstickSummaryMeasuresSensorError() throws {
    let readings = series([110, 110, 110, 90, 90])
    let entries = [
        LogEntry(date: t0, kind: .fingerstick, value: 100),                       // +10 %
        LogEntry(date: t0.addingTimeInterval(1200), kind: .fingerstick, value: 70), // +20 mg/dL, fuera del 15/15
        LogEntry(date: t0, kind: .carbs, value: 30),
    ]
    let comparisons = Logbook.fingerstickComparisons(entries, readings: readings)
    #expect(comparisons.map(\.difference) == [10, 20])
    #expect(comparisons.map(\.withinFifteen) == [true, false])
    let summary = try #require(FingerstickSummary(comparisons))
    #expect(summary.averageDifference == 15)
    #expect(abs(summary.mard - (0.1 + 20.0 / 70) / 2) < 1e-9)
    #expect(summary.withinFifteen == 0.5)
    #expect(FingerstickSummary([]) == nil)
}

@Test func demoEntriesMatchTheCurve() {
    let now = t0
    let entries = DemoServer.logEntries(patientID: "demo-1", days: 3, now: now)
    #expect(entries.allSatisfy { $0.isValid && $0.date <= now })
    #expect(entries.filter { $0.kind == .carbs }.count >= 9)
    let readings = DemoServer.backfill(patientID: "demo-1", days: 3, now: now.addingTimeInterval(12 * 3600))
    let meals = Logbook.mealResponses(entries, readings: readings, target: 70...180)
    #expect(meals.count >= 6)
    #expect(meals.allSatisfy { $0.rise > 0 })
}
