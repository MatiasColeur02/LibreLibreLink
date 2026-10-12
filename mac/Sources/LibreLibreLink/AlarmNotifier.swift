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
        content.title = isDemo ? "Demo · \(kind.title)" : kind.title
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

    func postTest() {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "LibreLibreLink"
        content.body = "Así se ven las alarmas."
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
        case .urgentLow: "Glucosa muy baja"
        case .low: "Glucosa baja"
        case .high: "Glucosa alta"
        case .signalLoss: "Sin señal del sensor"
        }
    }

    var advice: String {
        switch self {
        case .urgentLow, .low, .high: "Comprobá con glucómetro."
        case .signalLoss: "No llegan lecturas hace más de 20 min."
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
