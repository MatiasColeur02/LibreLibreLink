import Foundation
import Testing
@testable import LibreKit

// Alarmas más inteligentes: bajando rápido, alta sostenida, noche, posponer y escalada.

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2027-01-15 14:00 UTC.
private let afternoon = Date(timeIntervalSince1970: 1_800_021_600)
private let night = afternoon.addingTimeInterval(10 * 3600) // 00:00 UTC

private func reading(_ mgdL: Double, minutesAgo: Double = 0, at now: Date = afternoon, trend: Trend? = .stable) -> GlucoseMeasurement {
    GlucoseMeasurement(date: now.addingTimeInterval(-minutesAgo * 60), mgdL: mgdL, trend: trend)
}

private func conditions(
    _ current: GlucoseMeasurement,
    recent: [GlucoseMeasurement] = [],
    settings: AlarmSettings = AlarmSettings(),
    now: Date = afternoon
) -> [GlucoseCondition] {
    GlucoseStatus.conditions(current: current, recent: recent, sensor: nil, settings: settings, fetched: true,
                             connectionError: nil, needsAttention: nil, now: now, calendar: utc)
}

private func alarms(
    _ conditions: [GlucoseCondition],
    readings: [GlucoseMeasurement] = [],
    settings: AlarmSettings = AlarmSettings(),
    snoozes: AlarmSnoozes = AlarmSnoozes(),
    now: Date = afternoon
) -> Set<AlarmKind> {
    AlarmPolicy.alarms(conditions: conditions, readings: readings, settings: settings, snoozes: snoozes, now: now, calendar: utc)
}

// MARK: - Bajando rápido

@Test func fallingFastOnlyWhenEnabledAndInRange() {
    var settings = AlarmSettings()
    let recent = stride(from: 15.0, to: 0, by: -5).map { reading(160 + 2.5 * $0, minutesAgo: $0, trend: nil) }
    let current = reading(160)
    #expect(conditions(current, recent: recent).isEmpty)
    settings.fallingFastEnabled = true
    #expect(conditions(current, recent: recent, settings: settings) == [.fallingFast])
    #expect(conditions(current, recent: recent, settings: settings).first?.alarm == .fallingFast)
    // La flecha ↓ de LibreLinkUp alcanza aunque no haya historial.
    #expect(conditions(reading(150, trend: .fallingQuickly), settings: settings) == [.fallingFast])
    // Bajando despacio: nada.
    #expect(conditions(reading(150, trend: .falling), settings: settings).isEmpty)
    // Ya baja o por cruzar el umbral: avisan esas, no "bajando rápido".
    #expect(conditions(reading(65, trend: .fallingQuickly), settings: settings) == [.low])
    let toLow = stride(from: 15.0, to: 0, by: -5).map { reading(85 + 2.5 * $0, minutesAgo: $0, trend: nil) }
    #expect(conditions(reading(85, trend: .fallingQuickly), recent: toLow, settings: settings).first.map {
        if case .lowSoon = $0 { true } else { false }
    } == true)
}

// MARK: - Alta sostenida

@Test func highSinceFollowsTheUnbrokenStreak() {
    let readings = [reading(200, minutesAgo: 40), reading(250, minutesAgo: 30), reading(260, minutesAgo: 15), reading(255)]
    #expect(GlucoseStatus.highSince(readings, threshold: 240) == afternoon.addingTimeInterval(-30 * 60))
    // Una laguna de más de 30 min corta la racha.
    #expect(GlucoseStatus.highSince([reading(250, minutesAgo: 60), reading(255)], threshold: 240) == afternoon)
    #expect(GlucoseStatus.highSince(readings + [reading(230, minutesAgo: -1)], threshold: 240) == nil)
    #expect(GlucoseStatus.highSince(readings, threshold: 300) == nil)
    // Sin una lectura no alta, la racha arranca en la más vieja.
    #expect(GlucoseStatus.highSince(Array(readings.dropFirst()), threshold: 240) == afternoon.addingTimeInterval(-30 * 60))
}

@Test func highDelayWaitsUntilTheHighLasts() {
    var settings = AlarmSettings()
    settings.highDelay = 2 * 3600
    let shortPeak = stride(from: 60.0, through: 0, by: -15).map { reading(280, minutesAgo: $0) } + [reading(150, minutesAgo: 75)]
    #expect(alarms([.high], readings: shortPeak, settings: settings).isEmpty)
    let longHigh = stride(from: 120.0, through: 0, by: -15).map { reading(280, minutesAgo: $0) }
    #expect(alarms([.high], readings: longHigh, settings: settings) == [.high])
    // Sin demora: enseguida.
    #expect(alarms([.high], readings: shortPeak) == [.high])
}

// MARK: - Noche

@Test func nightWindowCrossesMidnight() {
    var settings = AlarmSettings()
    #expect(!settings.isNight(at: night, calendar: utc))
    settings.nightEnabled = true
    #expect(settings.isNight(at: night, calendar: utc))                                  // 00:00
    #expect(settings.isNight(at: night.addingTimeInterval(-3600), calendar: utc))        // 23:00
    #expect(!settings.isNight(at: night.addingTimeInterval(7 * 3600), calendar: utc))    // 07:00
    #expect(!settings.isNight(at: afternoon, calendar: utc))
    settings.nightStart = 1 * 60
    settings.nightEnd = 5 * 60
    #expect(settings.isNight(at: night.addingTimeInterval(2 * 3600), calendar: utc))
    #expect(!settings.isNight(at: night, calendar: utc))
}

@Test func nightThresholdsApplyAtNight() {
    var settings = AlarmSettings()
    settings.nightEnabled = true
    settings.nightLowThreshold = 80
    settings.nightHighThreshold = 270
    #expect(conditions(reading(75), settings: settings).isEmpty)
    #expect(conditions(reading(75, at: night), settings: settings, now: night) == [.low])
    #expect(conditions(reading(250), settings: settings) == [.high])
    #expect(conditions(reading(250, at: night), settings: settings, now: night).isEmpty)
    // La baja grave no cambia de noche.
    #expect(conditions(reading(50, at: night), settings: settings, now: night) == [.urgentLow])
}

@Test func nightCanSilenceOnlyTheHigh() {
    var settings = AlarmSettings()
    settings.nightEnabled = true
    settings.nightSilencesHigh = true
    #expect(alarms([.high, .signalLoss], settings: settings, now: night) == [.signalLoss])
    #expect(alarms([.low], settings: settings, now: night) == [.low])
    #expect(alarms([.high], settings: settings) == [.high])
}

// MARK: - Posponer

@Test func snoozeCoversMilderLowsButNotUrgentLow() {
    var snoozes = AlarmSnoozes()
    snoozes.snooze(.low, for: 30 * 60, now: afternoon)
    #expect(alarms([.low, .lowSoon(afternoon), .high], snoozes: snoozes) == [.high])
    #expect(alarms([.urgentLow, .low], snoozes: snoozes) == [.urgentLow])
    #expect(alarms([.low], snoozes: snoozes, now: afternoon.addingTimeInterval(30 * 60)) == [.low])
    #expect(snoozes.active(now: afternoon).map(\.kind) == [.low, .lowSoon, .fallingFast])
}

@Test func urgentLowSnoozeIsCapped() {
    var snoozes = AlarmSnoozes()
    snoozes.snooze(.urgentLow, for: 3600, now: afternoon)
    #expect(snoozes.isSnoozed(.urgentLow, now: afternoon.addingTimeInterval(14 * 60)))
    #expect(!snoozes.isSnoozed(.urgentLow, now: afternoon.addingTimeInterval(15 * 60)))
    // Una pospuesta más corta no acorta una más larga.
    snoozes.snooze(.high, for: 3600, now: afternoon)
    snoozes.snooze(.high, for: 15 * 60, now: afternoon)
    #expect(snoozes.isSnoozed(.high, now: afternoon.addingTimeInterval(30 * 60)))
}

@Test func signalLossSettingStillApplies() {
    var settings = AlarmSettings()
    settings.signalLossEnabled = false
    #expect(alarms([.signalLoss], settings: settings).isEmpty)
}

// MARK: - Escalada

@Test func unattendedLowEscalates() {
    var engine = AlarmEngine()
    let t = afternoon
    #expect(engine.update(active: [.urgentLow], now: t, escalate: true) == [.urgentLow])
    #expect(engine.update(active: [.urgentLow], now: t.addingTimeInterval(5 * 60), escalate: true) == [.urgentLow])
    #expect(!engine.isEscalated(.urgentLow, now: t.addingTimeInterval(9 * 60)))
    #expect(engine.update(active: [.urgentLow], now: t.addingTimeInterval(10 * 60), escalate: true) == [.urgentLow])
    #expect(engine.isEscalated(.urgentLow, now: t.addingTimeInterval(10 * 60)))
    // Escalada: cada 2 min en vez de 5.
    #expect(engine.update(active: [.urgentLow], now: t.addingTimeInterval(11 * 60), escalate: true).isEmpty)
    #expect(engine.update(active: [.urgentLow], now: t.addingTimeInterval(12 * 60), escalate: true) == [.urgentLow])
    // Atendida: vuelve a cada 5 min.
    engine.acknowledge(.urgentLow)
    #expect(!engine.isEscalated(.urgentLow, now: t.addingTimeInterval(13 * 60)))
    #expect(engine.update(active: [.urgentLow], now: t.addingTimeInterval(14 * 60), escalate: true).isEmpty)
    // Termina el episodio: la próxima vuelve a empezar sin atender.
    _ = engine.update(active: [], now: t.addingTimeInterval(20 * 60))
    _ = engine.update(active: [.urgentLow], now: t.addingTimeInterval(21 * 60), escalate: true)
    #expect(engine.isEscalated(.urgentLow, now: t.addingTimeInterval(31 * 60)))
}

@Test func onlyLowsEscalateAndOnlyWhenEnabled() {
    var engine = AlarmEngine()
    _ = engine.update(active: [.high], now: afternoon, escalate: true)
    #expect(!engine.isEscalated(.high, now: afternoon.addingTimeInterval(3600)))
    var off = AlarmEngine()
    _ = off.update(active: [.low], now: afternoon)
    _ = off.update(active: [.low], now: afternoon.addingTimeInterval(10 * 60))
    #expect(off.update(active: [.low], now: afternoon.addingTimeInterval(12 * 60)).isEmpty)
}

@Test func newAlarmSettingsDecodeFromOldData() throws {
    let decoded = try JSONDecoder().decode(AlarmSettings.self, from: Data(#"{"lowThreshold":80}"#.utf8))
    #expect(decoded.lowThreshold == 80 && decoded.escalationEnabled && !decoded.nightEnabled && decoded.highDelay == 0)
}
