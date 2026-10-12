import Testing
@testable import LibreKit

private func state(notifications: Bool = true, voice: Bool = false, permission: NotificationPermission = .allowed,
                   configure: (inout AlarmDeliveryState) -> Void = { _ in }) -> AlarmDeliveryState {
    var settings = AlarmSettings()
    settings.notificationsEnabled = notifications
    settings.speakAlarms = voice
    var result = AlarmDeliveryState(settings: settings, permission: permission)
    configure(&result)
    return result
}

@Test func everythingFineHasNoIssues() {
    #expect(AlarmDelivery.issues(state()).isEmpty)
    #expect(AlarmDelivery.canAlert(state()))
}

@Test func defaultsWarnThatNothingIsOn() {
    let off = state(notifications: false, permission: .notDetermined)
    #expect(AlarmDelivery.issues(off) == [.nothingEnabled])
    #expect(!AlarmDelivery.canAlert(off))
}

@Test func permissionProblems() {
    #expect(AlarmDelivery.issues(state(permission: .denied)) == [.permissionDenied])
    #expect(AlarmDelivery.issues(state(permission: .notDetermined)) == [.permissionNotRequested])
    #expect(AlarmDelivery.issues(state(permission: .unavailable)) == [.notBundled])
    #expect(!AlarmDelivery.canAlert(state(permission: .denied)))
    // La voz sigue avisando aunque macOS bloquee las notificaciones.
    #expect(AlarmDelivery.canAlert(state(voice: true, permission: .denied)))
}

@Test func notificationStyleAndSound() {
    let silentBanner = state { $0.soundEnabled = false }
    #expect(AlarmDelivery.issues(silentBanner) == [.soundOff])
    #expect(AlarmDelivery.canAlert(silentBanner))
    // Con voz, que la notificación no suene no es un problema.
    #expect(AlarmDelivery.issues(state(voice: true) { $0.soundEnabled = false }).isEmpty)

    let noBanner = state { $0.bannersEnabled = false }
    #expect(AlarmDelivery.issues(noBanner) == [.bannersOff])
    #expect(AlarmDelivery.canAlert(noBanner))  // todavía suena
    #expect(!AlarmDelivery.canAlert(state { $0.bannersEnabled = false; $0.outputMuted = true }))
    #expect(AlarmDelivery.issues(state { $0.timeSensitiveEnabled = false }) == [.timeSensitiveOff])
}

@Test func mutedOnlyMattersWhenSomethingShouldSound() {
    #expect(AlarmDelivery.issues(state { $0.outputMuted = true }) == [.muted])
    #expect(AlarmDelivery.issues(state { $0.outputMuted = true; $0.soundEnabled = false }) == [.soundOff])
    let voiceOnlyMuted = state(notifications: false, voice: true) { $0.outputMuted = true }
    #expect(AlarmDelivery.issues(voiceOnlyMuted) == [.muted])
    #expect(!AlarmDelivery.canAlert(voiceOnlyMuted))
}

@Test func launchAtLoginAndData() {
    #expect(AlarmDelivery.issues(state { $0.launchAtLogin = false }) == [.launchAtLoginOff])
    #expect(AlarmDelivery.issues(state(notifications: false, permission: .allowed) { $0.launchAtLogin = false }) == [.nothingEnabled])
    let noData = state { $0.hasData = false }
    #expect(AlarmDelivery.issues(noData) == [.noData])
    #expect(!AlarmDelivery.canAlert(noData))
}
