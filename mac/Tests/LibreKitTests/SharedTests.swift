import Foundation
import Testing
@testable import LibreKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func appCommandsRoundTrip() {
    let commands: [AppCommand] = [
        .open(nil), .open(.settings), .snooze(minutes: 30), .resumeAlarms, .discreet(.toggle), .logChanged,
    ]
    for command in commands {
        #expect(AppCommand(url: command.url) == command)
    }
    #expect(AppCommand.snooze(minutes: 15).url.absoluteString == "librelibrelink://snooze?minutes=15")
    #expect(AppCommand(url: URL(string: "librelibrelink://snooze?minutes=0")!) == nil)
    #expect(AppCommand(url: URL(string: "librelibrelink://nope")!) == nil)
    #expect(AppCommand(url: URL(string: "https://open")!) == nil)
}

@Test func shortcutsRunOncePerEpisodeAndOnReturn() {
    var trigger = ShortcutTrigger()
    #expect(trigger.update(alarms: [], hasReading: true).isEmpty)
    #expect(trigger.update(alarms: [.low], hasReading: true) == [.low])
    #expect(trigger.update(alarms: [.low], hasReading: true).isEmpty)
    // Baja → baja grave: sigue siendo la misma baja.
    #expect(trigger.update(alarms: [.urgentLow, .low], hasReading: true).isEmpty)
    // Sin lectura no se sabe si volvió.
    #expect(trigger.update(alarms: [.signalLoss], hasReading: false) == [.signalLoss])
    #expect(trigger.update(alarms: [], hasReading: true) == [.backInRange])
    #expect(trigger.update(alarms: [], hasReading: true).isEmpty)
    #expect(trigger.update(alarms: [.high], hasReading: true) == [.high])
    #expect(trigger.update(alarms: [.lowSoon], hasReading: true) == [.backInRange])
}

@Test func macPreferencesDecodeMissingKeys() throws {
    let decoded = try JSONDecoder().decode(MacPreferences.self, from: Data(#"{"discreet":true}"#.utf8))
    #expect(decoded.discreet && decoded.hotKey == .optionCommandG && decoded.shortcuts.isEmpty)
    var prefs = MacPreferences()
    prefs.shortcuts = [ShortcutEvent.low.rawValue: "Pausar música", ShortcutEvent.high.rawValue: ""]
    #expect(prefs.shortcut(for: .low) == "Pausar música")
    #expect(prefs.shortcut(for: .high) == nil)
}

@Test func snapshotRoundTripAndFreshness() throws {
    let reading = GlucoseMeasurement(date: now, mgdL: 123, trend: .rising)
    let snapshot = GlucoseSnapshot(updatedAt: now, signedIn: true, patientID: "p", current: reading, readings: [reading],
                                   problem: .init(title: "Alta", symbol: "x", tint: .orange))
    let url = FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try snapshot.save(to: url)
    let loaded = try #require(GlucoseSnapshot.load(from: url))
    #expect(loaded == snapshot)
    #expect(loaded.freshReading(at: now.addingTimeInterval(19 * 60)) == reading)
    #expect(loaded.freshReading(at: now.addingTimeInterval(20 * 60)) == nil)
    var later = snapshot
    later.updatedAt = now.addingTimeInterval(60)
    #expect(later.sameContent(as: snapshot))
    later.discreet = true
    #expect(!later.sameContent(as: snapshot))
}
