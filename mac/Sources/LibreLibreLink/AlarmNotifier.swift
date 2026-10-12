import AVFoundation
import Foundation
import LibreKit
import ServiceManagement
import UserNotifications

/// Notificaciones de macOS para las alarmas. Requieren correr como `LibreLibreLink.app`
/// (con `swift run` no hay bundle y `UNUserNotificationCenter` no está disponible).
@MainActor
@Observable
final class AlarmNotifier {
    enum Authorization: Equatable {
        case unavailable, notDetermined, denied, allowed
    }

    private(set) var authorization: Authorization = .unavailable
    /// Marca las notificaciones para no confundirlas con datos reales.
    var isDemo = false

    nonisolated static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    private let delegate = ForegroundPresenter()
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        if Self.isBundled { UNUserNotificationCenter.current().delegate = delegate }
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
    }

    func requestAuthorization() async {
        guard Self.isBundled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func post(_ kind: AlarmKind, reading: GlucoseMeasurement?, unit: GlucoseUnit) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = isDemo ? String(localized: "Demo · \(kind.title)") : kind.title
        if let reading {
            let value = unit.reading(reading.mgdL)
            content.body = "\(value) \(unit.symbol) \(reading.trend?.arrow ?? "") · \(kind.advice)"
        } else {
            content.body = kind.advice
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // Mismo identificador por tipo: la nueva reemplaza a la anterior.
        let request = UNNotificationRequest(identifier: "alarm.\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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

/// Muestra el banner aunque el panel de LibreLibreLink esté abierto (app activa).
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

private extension AlarmKind {
    var title: String {
        switch self {
        case .urgentLow: String(localized: "Glucosa muy baja")
        case .low: String(localized: "Glucosa baja")
        case .lowSoon: String(localized: "Baja en camino")
        case .high: String(localized: "Glucosa alta")
        case .signalLoss: String(localized: "Sin señal del sensor")
        }
    }

    var advice: String {
        switch self {
        case .urgentLow, .low, .high: String(localized: "Comprobá con glucómetro.")
        case .lowSoon: String(localized: "A este ritmo cruza el umbral de baja en menos de 15 min (estimado). Comprobá con glucómetro.")
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

/// Abrir al iniciar sesión (R16). Solo funciona como `LibreLibreLink.app`.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        AlarmNotifier.isBundled && SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
