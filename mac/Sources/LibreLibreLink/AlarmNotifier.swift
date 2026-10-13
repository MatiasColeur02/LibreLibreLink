import AppKit
import AVFoundation
import CoreAudio
import Foundation
import LibreKit
import ServiceManagement
import UserNotifications

/// Notificaciones de macOS para las alarmas. Requieren correr como `LibreLibreLink.app`
/// (con `swift run` no hay bundle y `UNUserNotificationCenter` no está disponible).
@MainActor
@Observable
final class AlarmNotifier {
    private(set) var authorization: NotificationPermission = .unavailable
    /// Lo que el usuario eligió en Ajustes del Sistema ▸ Notificaciones ▸ LibreLibreLink.
    private(set) var bannersEnabled = true
    private(set) var soundEnabled = true
    private(set) var timeSensitiveEnabled = true
    /// Marca las notificaciones para no confundirlas con datos reales.
    var isDemo = false

    nonisolated static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// El usuario tocó una alarma o eligió una de sus acciones.
    var onResponse: ((AlarmKind, AlarmAction) -> Void)?

    private let delegate = NotificationDelegate()
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        if Self.isBundled {
            let center = UNUserNotificationCenter.current()
            center.delegate = delegate
            center.setNotificationCategories(Set(AlarmCategory.allCases.map(\.category)))
        }
        delegate.handler = { [weak self] kind, action in self?.onResponse?(kind, action) }
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        guard Self.isBundled else { authorization = .unavailable; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
        bannersEnabled = settings.alertStyle != .none
        soundEnabled = settings.soundSetting != .disabled
        timeSensitiveEnabled = settings.timeSensitiveSetting != .disabled
    }

    /// Ajustes del Sistema ▸ Notificaciones, en la página de LibreLibreLink.
    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }

    static func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    func requestAuthorization() async {
        guard Self.isBundled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    /// - Parameter escalated: una baja sin atender (se marca en el título).
    func post(_ kind: AlarmKind, reading: GlucoseMeasurement?, unit: GlucoseUnit, escalated: Bool = false) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        let title = escalated ? String(localized: "Sin atender · \(kind.title)") : kind.title
        content.title = isDemo ? String(localized: "Demo · \(title)") : title
        if let reading {
            let value = unit.reading(reading.mgdL)
            content.body = "\(value) \(unit.symbol) \(reading.trend?.arrow ?? "") · \(kind.advice)"
        } else {
            content.body = kind.advice
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = AlarmCategory(kind).rawValue
        content.userInfo = ["kind": kind.rawValue]
        // Mismo identificador por tipo: la nueva reemplaza a la anterior.
        let request = UNNotificationRequest(identifier: "alarm.\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// "Ya comí": recordatorio para volver a medir (regla 15-15).
    func scheduleRecheck(after delay: TimeInterval) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        let title = String(localized: "Volvé a medir")
        content.title = isDemo ? String(localized: "Demo · \(title)") : title
        content.body = String(localized: "Pasaron \(Int(delay / 60)) min desde que trataste la baja. Medí con glucómetro; si sigue baja, repetí el tratamiento.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "recheck", content: content, trigger: trigger))
    }

    func post(_ notice: SensorNotice, sensor: SensorInfo) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = isDemo ? String(localized: "Demo · \(notice.title)") : notice.title
        content.body = notice.body(sensor)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sensor.\(notice.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Lee la alarma en voz alta, en el idioma de la app ("Glucosa baja, 64, bajando").
    /// No depende de los permisos de notificación ni de Concentración; sí del volumen.
    func speak(_ kind: AlarmKind, reading: GlucoseMeasurement?, unit: GlucoseUnit) {
        var parts = [kind.title]
        if let reading, kind != .signalLoss {
            parts.append(Self.spokenValue(reading.mgdL, unit: unit))
            if let trend = reading.trend, trend != .unknown { parts.append(trend.label.lowercased()) }
        }
        speak(parts.joined(separator: ", "))
    }

    func speakTest() {
        speak(String(localized: "Así suenan las alarmas."))
    }

    private func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        synthesizer.speak(utterance)
    }

    /// Voz del sistema para el idioma de la app (la de la región del usuario si coincide).
    /// Nunca una de las "novedosas" (Bubbles, Bad News…), que macOS lista primero.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = Bundle.main.preferredLocalizations.first ?? "es"
        let regional = Locale.current.identifier(.bcp47)
        let preferred = (regional.hasPrefix(language) ? [regional] : [])
            + (language == "es" ? ["es-MX", "es-ES", "es-US"] : ["en-US", "en-GB"])
        return preferred.lazy.compactMap { AVSpeechSynthesisVoice(language: $0) }.first
            ?? AVSpeechSynthesisVoice.speechVoices().first {
                $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice)
            }
    }()

    /// "LO"/"HI" no se entienden en voz: "menos de 40" / "más de 500".
    private static func spokenValue(_ mgdL: Double, unit: GlucoseUnit) -> String {
        if mgdL < 40 { return String(localized: "menos de \(unit.number(40))") }
        if mgdL > 500 { return String(localized: "más de \(unit.number(500))") }
        return unit.number(mgdL)
    }

    func postTest() {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "LibreLibreLink"
        content.body = String(localized: "Así se ven las alarmas.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil))
    }
}

/// Lo que el usuario hizo con una notificación de alarma.
enum AlarmAction: Equatable {
    /// Tocó la notificación: la vio.
    case opened
    case snooze(TimeInterval)
    /// "Ya comí": posponer las bajas 15 min y recordar volver a medir.
    case treated

    static let treatedDelay: TimeInterval = 15 * 60

    init?(identifier: String) {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: self = .opened
        case "treated": self = .treated
        default:
            guard identifier.hasPrefix("snooze."), let minutes = Double(identifier.dropFirst(7)) else { return nil }
            self = .snooze(minutes * 60)
        }
    }
}

/// Botones de cada alarma. La baja grave solo se puede posponer tratándola.
private enum AlarmCategory: String, CaseIterable {
    case urgentLow = "alarm.urgentLow"
    case low = "alarm.low"
    case other = "alarm.other"

    init(_ kind: AlarmKind) {
        self = kind == .urgentLow ? .urgentLow : kind.isLow ? .low : .other
    }

    var category: UNNotificationCategory {
        let treated = UNNotificationAction(identifier: "treated", title: String(localized: "Ya comí · recordame en 15 min"))
        let snooze = { (minutes: Int) in
            UNNotificationAction(identifier: "snooze.\(minutes)", title: String(localized: "Posponer \(minutes) min"))
        }
        let actions = switch self {
        case .urgentLow: [treated]
        case .low: [treated, snooze(15), snooze(30)]
        case .other: [snooze(15), snooze(30), snooze(60)]
        }
        return UNNotificationCategory(identifier: rawValue, actions: actions, intentIdentifiers: [])
    }
}

/// Muestra el banner aunque el panel de LibreLibreLink esté abierto (app activa) y
/// pasa a la app lo que el usuario eligió en una alarma.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var handler: (@MainActor (AlarmKind, AlarmAction) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["kind"] as? String,
              let kind = AlarmKind(rawValue: raw),
              let action = AlarmAction(identifier: response.actionIdentifier) else { return }
        await handler?(kind, action)
    }
}

extension AlarmKind {
    var title: String {
        switch self {
        case .urgentLow: String(localized: "Glucosa muy baja")
        case .low: String(localized: "Glucosa baja")
        case .lowSoon: String(localized: "Baja en camino")
        case .fallingFast: String(localized: "Bajando rápido")
        case .high: String(localized: "Glucosa alta")
        case .signalLoss: String(localized: "Sin señal del sensor")
        }
    }

    var advice: String {
        switch self {
        case .urgentLow, .low, .high: String(localized: "Comprobá con glucómetro.")
        case .lowSoon: String(localized: "A este ritmo cruza el umbral de baja en menos de 15 min (estimado). Comprobá con glucómetro.")
        case .fallingFast: String(localized: "Baja más de 2 mg/dL por minuto. Comprobá con glucómetro.")
        case .signalLoss: String(localized: "No llegan lecturas hace más de 20 min.")
        }
    }
}

private extension SensorNotice {
    var title: String {
        switch self {
        case .newSensor: String(localized: "Sensor nuevo")
        case .ready: String(localized: "Sensor listo")
        case .endsIn3Days: String(localized: "El sensor termina en 3 días")
        case .endsIn1Day: String(localized: "El sensor termina en 1 día")
        case .endsIn1Hour: String(localized: "El sensor termina en 1 hora")
        case .ended: String(localized: "Sensor terminado")
        }
    }

    func body(_ sensor: SensorInfo) -> String {
        let end = sensor.expectedEnd.formatted(date: .abbreviated, time: .shortened)
        switch self {
        case .newSensor:
            let ready = sensor.readyAt.formatted(date: .omitted, time: .shortened)
            return sensor.readyAt > Date()
                ? String(localized: "Calentando: las lecturas empiezan a las \(ready). Termina el \(end).")
                : String(localized: "Termina el \(end).")
        case .ready: return String(localized: "Terminó el calentamiento; ya deberían llegar lecturas.")
        case .endsIn3Days, .endsIn1Day: return String(localized: "Termina el \(end). Tené uno de repuesto.")
        case .endsIn1Hour: return String(localized: "Termina a las \(sensor.expectedEnd.formatted(date: .omitted, time: .shortened)).")
        case .ended: return String(localized: "Ya pasaron los 15 días. Reemplazalo y activalo con LibreLink.")
        }
    }
}

/// Salida de audio actual en silencio o con volumen 0 (la voz y el sonido no se oirían).
enum SystemAudio {
    static var isOutputMuted: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }

        address.mScope = kAudioDevicePropertyScopeOutput
        address.mSelector = kAudioDevicePropertyMute
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr, mute != 0 { return true }

        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr { return volume < 0.01 }
        return false
    }
}

/// Abrir al iniciar sesión (R16). Solo funciona como `LibreLibreLink.app`.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        AlarmNotifier.isBundled && SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
