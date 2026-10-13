import Foundation
import Testing
@testable import LibreKit

private let t0 = Date(timeIntervalSince1970: 1_791_800_000)

private func series(_ values: [Double], every minutes: Double = 5, from start: Date = t0) -> [GlucoseMeasurement] {
    values.enumerated().map { i, v in
        GlucoseMeasurement(date: start.addingTimeInterval(Double(i) * minutes * 60), mgdL: v, trend: nil)
    }
}

@Test func unitsFormatAndConvert() {
    #expect(GlucoseUnit.mgdL.reading(123.4) == "123")
    #expect(GlucoseUnit.mmolL.reading(35) == "LO")
    #expect(GlucoseUnit.mmolL.reading(520) == "HI")
    #expect(abs(GlucoseUnit.mmolL.convert(180) - 9.99) < 0.01)
    #expect(GlucoseUnit.mgdL.withSymbol(70) == "70 mg/dL")
}

@Test func displaySettingsDecodeMissingKeys() throws {
    let decoded = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"unit":"mmolL"}"#.utf8))
    #expect(decoded.unit == .mmolL)
    #expect(decoded.target == 70...180)
    #expect(decoded.zone(65) == .below)
    #expect(decoded.zone(180) == .inTarget)
    #expect(decoded.zone(181) == .above)
}

@Test func statisticsAreTimeWeighted() throws {
    // 1 h a 100 cada 5 min, y después 1 h a 200 cada 1 min: la mitad del tiempo en cada valor.
    let first = series(Array(repeating: 100, count: 12))
    let second = series(Array(repeating: 200, count: 60), every: 1, from: t0.addingTimeInterval(3600))
    let period = DateInterval(start: t0, duration: 2 * 3600)
    let stats = try #require(GlucoseStatistics.compute(first + second, period: period, display: DisplaySettings()))
    #expect(abs(stats.mean - 150) < 1)
    #expect(abs((stats.zoneFractions[.inTarget] ?? 0) - 0.5) < 0.01)
    #expect(abs((stats.zoneFractions[.above] ?? 0) - 0.5) < 0.01)
    #expect(stats.coverage > 0.99)
    #expect(abs(stats.gmi - (3.31 + 0.02392 * stats.mean)) < 1e-9)
}

@Test func lowEventsNeedFifteenMinutes() throws {
    // Baja de 10 min (no cuenta), luego baja de 20 min (cuenta).
    let values: [Double] = [100, 65, 62, 100, 100, 60, 58, 57, 61, 100]
    let period = DateInterval(start: t0, duration: 3600)
    let stats = try #require(GlucoseStatistics.compute(series(values), period: period, display: DisplaySettings()))
    #expect(stats.lowEvents == 1)
}

@Test func gapsAreNotFilled() throws {
    // Dos lecturas separadas por 3 h: cada una cuenta como mucho 15 min.
    let readings = [GlucoseMeasurement(date: t0, mgdL: 100, trend: nil),
                    GlucoseMeasurement(date: t0.addingTimeInterval(3 * 3600), mgdL: 100, trend: nil)]
    let stats = try #require(GlucoseStatistics.compute(readings, period: DateInterval(start: t0, duration: 4 * 3600),
                                                       display: DisplaySettings()))
    #expect(stats.coverage < 0.15)
}

@Test func percentilesInterpolate() {
    #expect(DailyPattern.percentile([1, 2, 3, 4, 5], 0.5) == 3)
    #expect(DailyPattern.percentile([0, 10], 0.25) == 2.5)
}

@Test func dailyPatternFromDemoBackfill() {
    let readings = DemoServer.backfill(patientID: "demo-1", days: 7, now: t0)
    let pattern = DailyPattern.compute(readings)
    #expect(pattern.count == 49)
    #expect(pattern.allSatisfy { $0.p5 <= $0.p10 && $0.p10 <= $0.p25 && $0.p25 <= $0.p50 && $0.p50 <= $0.p75 && $0.p75 <= $0.p90 && $0.p90 <= $0.p95 })
    let stats = GlucoseStatistics.compute(readings, period: DateInterval(start: t0.addingTimeInterval(-8 * 86_400), end: t0),
                                          display: DisplaySettings())
    #expect((stats?.daysWithData ?? 0) >= 7)
}

@Test func historyDatabaseUpsertsByMinute() throws {
    let db = try HistoryDatabase(url: nil)
    let withTrend = GlucoseMeasurement(date: t0.addingTimeInterval(5), mgdL: 120, trend: .rising)
    let sameMinute = GlucoseMeasurement(date: t0.addingTimeInterval(30), mgdL: 121, trend: nil)
    try db.insert([withTrend], patientID: "p")
    try db.insert([sameMinute] + series([90, 95], from: t0.addingTimeInterval(300)), patientID: "p")
    try db.insert(series([300]), patientID: "otro")

    let all = try db.readings(patientID: "p", in: DateInterval(start: t0.addingTimeInterval(-60), duration: 3600))
    #expect(all.map(\.mgdL) == [121, 90, 95])
    #expect(all.first?.trend == .rising)
    #expect(try db.earliest(patientID: "p") == Date(timeIntervalSince1970: (t0.timeIntervalSince1970 / 60).rounded(.down) * 60))
    #expect(try db.earliest(patientID: "nadie") == nil)
}

@Test func historyDatabaseCountsOnlyNewOrChangedReadings() throws {
    let db = try HistoryDatabase(url: nil)
    let readings = series([100, 110])
    #expect(try db.insert(readings, patientID: "p") == 2)
    #expect(try db.insert(readings, patientID: "p") == 0)
    let corrected = GlucoseMeasurement(date: readings[1].date, mgdL: 112, trend: nil)
    #expect(try db.insert([corrected], patientID: "p") == 1)
    let withTrend = GlucoseMeasurement(date: readings[1].date, mgdL: 112, trend: .stable)
    #expect(try db.insert([withTrend], patientID: "p") == 1)
    #expect(try db.insert([corrected], patientID: "p") == 0)
}

@Test func historyDatabasePersistsToFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "librebar-\(UUID().uuidString)/h.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try HistoryDatabase(url: url).insert(series([100, 110]), patientID: "p")
    let reopened = try HistoryDatabase(url: url)
    #expect(try reopened.readings(patientID: "p", in: DateInterval(start: t0, duration: 3600)).count == 2)
}

@Test func consensusBandsUseFixedLimits() throws {
    // Una hora en cada valor; los límites del consenso no dependen del rango objetivo.
    var display = DisplaySettings()
    display.targetLow = 90
    let values: [Double] = [50, 60, 180, 181, 300]
    let readings = values.enumerated().flatMap { i, v in series(Array(repeating: v, count: 12), from: t0.addingTimeInterval(Double(i) * 3600)) }
    let stats = try #require(GlucoseStatistics.compute(readings, period: DateInterval(start: t0, duration: 5 * 3600), display: display))
    for band in GlucoseBand.allCases {
        #expect(abs((stats.bandFractions[band] ?? 0) - 0.2) < 0.01)
    }
    #expect(GlucoseBand(53.9) == .veryLow && GlucoseBand(54) == .low && GlucoseBand(70) == .target && GlucoseBand(250) == .high)
}
