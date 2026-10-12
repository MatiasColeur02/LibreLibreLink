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

// MARK: - Sensor

@Test func warmingUpReplacesSignalLoss() {
    let sensor = SensorInfo(serial: "NEW", activation: now.addingTimeInterval(-20 * 60))
    // Última lectura del sensor anterior, de antes de activar el nuevo.
    #expect(conditions(reading(120, minutesAgo: 25), sensor: sensor) == [.sensorWarmingUp(sensor.readyAt)])
    #expect(conditions(nil, sensor: sensor) == [.sensorWarmingUp(sensor.readyAt)])
    // Si ya llegan lecturas del sensor nuevo, se juzgan normalmente.
    #expect(conditions(reading(50, minutesAgo: 1), sensor: sensor) == [.urgentLow])
    let ready = SensorInfo(serial: "NEW", activation: now.addingTimeInterval(-61 * 60))
    #expect(conditions(reading(120, minutesAgo: 26), sensor: ready) == [.signalLoss])
}

@Test func sensorNoticesOncePerSensor() {
    let day: TimeInterval = 86_400
    let sensor = SensorInfo(serial: "A", activation: now.addingTimeInterval(-10 * day))
    var engine = SensorNoticeEngine()
    // El primer sensor se adopta en silencio, sin repetir lo que ya pasó.
    #expect(engine.update(sensor: sensor, now: now) == nil)
    #expect(engine.update(sensor: sensor, now: now.addingTimeInterval(2.5 * day)) == .endsIn3Days)
    #expect(engine.update(sensor: sensor, now: now.addingTimeInterval(2.6 * day)) == nil)
    // Si la app estuvo cerrada y pasaron dos avisos, solo el más reciente.
    #expect(engine.update(sensor: sensor, now: now.addingTimeInterval(5 * day - 1800)) == .endsIn1Hour)
    #expect(engine.update(sensor: sensor, now: now.addingTimeInterval(5 * day)) == .ended)

    let next = SensorInfo(serial: "B", activation: now.addingTimeInterval(5 * day + 600))
    #expect(engine.update(sensor: next, now: next.activation.addingTimeInterval(60)) == .newSensor)
    #expect(engine.update(sensor: next, now: next.readyAt.addingTimeInterval(60)) == .ready)
}

@Test func lateReadyNoticeIsSkipped() {
    let sensor = SensorInfo(serial: "B", activation: now)
    var engine = SensorNoticeEngine()
    _ = engine.update(sensor: SensorInfo(serial: "A", activation: now.addingTimeInterval(-15 * 86_400)), now: now)
    #expect(engine.update(sensor: sensor, now: now.addingTimeInterval(60)) == .newSensor)
    #expect(engine.update(sensor: sensor, now: now.addingTimeInterval(5 * 3600)) == nil)
}

@Test func alarmSettingsDecodeMissingKeys() throws {
    let decoded = try JSONDecoder().decode(AlarmSettings.self, from: Data(#"{"notificationsEnabled":true,"lowThreshold":80}"#.utf8))
    #expect(decoded.notificationsEnabled && decoded.lowThreshold == 80 && decoded.sensorNoticesEnabled)
}

// MARK: - Baja en camino

/// Lecturas cada 5 min de los últimos 15 min que terminan en `last` con la pendiente dada.
private func falling(to last: Double, slope: Double) -> (recent: [GlucoseMeasurement], current: GlucoseMeasurement) {
    let recent = stride(from: 15.0, to: 0, by: -5).map { reading(last - slope * $0, minutesAgo: $0) }
    return (recent, reading(last, minutesAgo: 0))
}

@Test func lowSoonWhenFallingTowardThreshold() throws {
    let (recent, current) = falling(to: 88, slope: -1.6)
    let result = GlucoseStatus.conditions(current: current, recent: recent, sensor: nil, settings: AlarmSettings(),
                                          fetched: true, connectionError: nil, needsAttention: nil, now: now)
    // (88 − 70) / 1,6 ≈ 11 min.
    guard case .lowSoon(let crossing) = try #require(result.first) else { Issue.record("\(result)"); return }
    #expect(abs(crossing.timeIntervalSince(now) / 60 - 11.25) < 0.1)
    #expect(result.first?.alarm == .lowSoon)
}

@Test func lowSoonNeedsAClearFallWithinFifteenMinutes() {
    func check(_ last: Double, _ slope: Double, settings: AlarmSettings = AlarmSettings()) -> [GlucoseCondition] {
        let (recent, current) = falling(to: last, slope: slope)
        return GlucoseStatus.conditions(current: current, recent: recent, sensor: nil, settings: settings,
                                        fetched: true, connectionError: nil, needsAttention: nil, now: now)
    }
    #expect(check(74, -0.5).isEmpty)      // cerca pero bajando lento
    #expect(check(120, -1.5).isEmpty)     // bajando, pero tardaría ~33 min
    #expect(check(100, 1.5).isEmpty)      // subiendo
    #expect(check(65, -1.5) == [.low])    // ya está baja: la alarma de baja, no la anticipada
    var off = AlarmSettings()
    off.lowSoonEnabled = false
    #expect(check(88, -1.6, settings: off).isEmpty)
}

@Test func forecastNeedsEnoughReadings() {
    let latest = reading(90, minutesAgo: 0)
    #expect(GlucoseForecast.slope([reading(95, minutesAgo: 5)], latest: latest) == nil)
    #expect(GlucoseForecast.slope([reading(92, minutesAgo: 2), reading(91, minutesAgo: 1)], latest: latest) == nil)
}
