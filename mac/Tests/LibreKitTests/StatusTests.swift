import Foundation
import Testing
@testable import LibreKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func reading(_ mgdL: Double, minutesAgo: Double = 1) -> GlucoseMeasurement {
    GlucoseMeasurement(date: now.addingTimeInterval(-minutesAgo * 60), mgdL: mgdL, trend: .stable)
}

private func conditions(
    _ current: GlucoseMeasurement?,
    settings: AlarmSettings = AlarmSettings(),
    sensor: SensorInfo? = nil,
    fetched: Bool = true,
    connectionError: String? = nil
) -> [GlucoseCondition] {
    GlucoseStatus.conditions(
        current: current, sensor: sensor, settings: settings, fetched: fetched,
        connectionError: connectionError, needsAttention: nil, now: now
    )
}

@Test func normalReadingHasNoProblems() {
    #expect(conditions(reading(120)).isEmpty)
}

@Test func glucoseZones() {
    #expect(conditions(reading(50)) == [.urgentLow])
    #expect(conditions(reading(65)) == [.low])
    #expect(conditions(reading(70)).isEmpty)
    #expect(conditions(reading(241)) == [.high])
    #expect(conditions(reading(240)).isEmpty)
}

@Test func disabledThresholdsAreIgnoredButUrgentLowIsNot() {
    var settings = AlarmSettings()
    settings.lowEnabled = false
    settings.highEnabled = false
    #expect(conditions(reading(65), settings: settings).isEmpty)
    #expect(conditions(reading(300), settings: settings).isEmpty)
    #expect(conditions(reading(50), settings: settings) == [.urgentLow])
}

@Test func staleAndSignalLoss() {
    #expect(conditions(reading(120, minutesAgo: 12)) == [.stale])
    #expect(conditions(reading(65, minutesAgo: 12)) == [.low, .stale])
    // Una lectura vieja no se juzga como baja: solo "sin señal".
    #expect(conditions(reading(65, minutesAgo: 25)) == [.signalLoss])
    #expect(conditions(nil) == [.signalLoss])
    #expect(conditions(nil, fetched: false).isEmpty)
}

@Test func connectionErrorIsReportedWithReading() {
    #expect(conditions(reading(120), connectionError: "offline") == [.connectionError("offline")])
}

@Test func sensorExpiry() {
    let day: TimeInterval = 24 * 3600
    let ending = SensorInfo(serial: "x", activation: now.addingTimeInterval(-14.5 * day))
    #expect(conditions(reading(120), sensor: ending) == [.sensorExpiringSoon(ending.expectedEnd)])
    let expired = SensorInfo(serial: "x", activation: now.addingTimeInterval(-16 * day))
    #expect(conditions(reading(120), sensor: expired) == [.sensorExpired])
    let fresh = SensorInfo(serial: "x", activation: now.addingTimeInterval(-3 * day))
    #expect(conditions(reading(120), sensor: fresh).isEmpty)
}

@Test func displayValue() {
    #expect(GlucoseStatus.displayValue(39) == "LO")
    #expect(GlucoseStatus.displayValue(40) == "40")
    #expect(GlucoseStatus.displayValue(500) == "500")
    #expect(GlucoseStatus.displayValue(501) == "HI")
}

@Test func alarmEpisodesNotifyOnceThenEveryFiveMinutes() {
    var engine = AlarmEngine()
    #expect(engine.update(active: [.low], now: now) == [.low])
    #expect(engine.update(active: [.low], now: now.addingTimeInterval(60)).isEmpty)
    #expect(engine.update(active: [.low], now: now.addingTimeInterval(299)).isEmpty)
    #expect(engine.update(active: [.low], now: now.addingTimeInterval(300)) == [.low])
    // Termina el episodio y vuelve a empezar: notifica de inmediato.
    #expect(engine.update(active: [], now: now.addingTimeInterval(360)).isEmpty)
    #expect(engine.update(active: [.low], now: now.addingTimeInterval(420)) == [.low])
}

@Test func urgentLowSuppressesLow() {
    var engine = AlarmEngine()
    #expect(engine.update(active: [.urgentLow, .low], now: now) == [.urgentLow])
}

@Test func graphDecodesSensorActivation() throws {
    let json = #"{"data":{"connection":{"sensor":{"sn":"MH0M1XXXXX","a":1800000000,"w":60,"pt":4}},"graphData":[]}}"#
    let graph = try LibreLinkUpClient.decodeGraph(Data(json.utf8))
    #expect(graph.sensor?.activation == now)
    #expect(graph.current == nil)
}
