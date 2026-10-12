import Foundation

/// Permiso de macOS para notificar.
public enum NotificationPermission: Sendable, Equatable {
    /// Sin bundle (`swift run`): macOS no deja notificar.
    case unavailable
    case notDetermined
    case denied
    case allowed
}

/// Lo que hace falta saber del sistema para decidir si una alarma llega (R15).
public struct AlarmDeliveryState: Sendable, Equatable {
    public var settings: AlarmSettings
    public var permission: NotificationPermission
    /// Estilo de aviso distinto de "Ninguno" en Ajustes del Sistema ▸ Notificaciones.
    public var bannersEnabled = true
    public var soundEnabled = true
    /// "Notificaciones urgentes": lo que deja pasar una alarma con Concentración activa.
    public var timeSensitiveEnabled = true
    /// Salida de audio en silencio o con volumen 0.
    public var outputMuted = false
    public var launchAtLogin = true
    /// Hay sesión y LibreLinkUp responde (si no, no hay lecturas que vigilar).
    public var hasData = true

    public init(settings: AlarmSettings, permission: NotificationPermission) {
        self.settings = settings
        self.permission = permission
    }
}

/// Por qué una alarma podría no llegar ("¿por qué no me llegan las alarmas?").
public enum AlarmDeliveryIssue: Hashable, Sendable {
    /// Ni notificaciones ni voz: nada avisa.
    case nothingEnabled
    case notBundled
    case permissionNotRequested
    case permissionDenied
    case bannersOff
    case soundOff
    case timeSensitiveOff
    case muted
    case launchAtLoginOff
    case noData
}

public enum AlarmDelivery {
    /// Problemas, del más grave al más leve.
    public static func issues(_ state: AlarmDeliveryState) -> [AlarmDeliveryIssue] {
        let settings = state.settings
        var result: [AlarmDeliveryIssue] = []
        if !state.hasData { result.append(.noData) }
        if !settings.notificationsEnabled, !settings.speakAlarms { result.append(.nothingEnabled) }
        if settings.notificationsEnabled {
            switch state.permission {
            case .unavailable: result.append(.notBundled)
            case .notDetermined: result.append(.permissionNotRequested)
            case .denied: result.append(.permissionDenied)
            case .allowed:
                if !state.bannersEnabled { result.append(.bannersOff) }
                if !state.soundEnabled, !settings.speakAlarms { result.append(.soundOff) }
                if !state.timeSensitiveEnabled { result.append(.timeSensitiveOff) }
            }
        }
        let wantsSound = settings.speakAlarms || (settings.notificationsEnabled && state.permission == .allowed && state.soundEnabled)
        if state.outputMuted, wantsSound { result.append(.muted) }
        if state.permission != .unavailable, !state.launchAtLogin, settings.notificationsEnabled || settings.speakAlarms {
            result.append(.launchAtLoginOff)
        }
        return result
    }

    /// Si al menos un camino (notificación visible o voz audible) puede avisar ahora.
    public static func canAlert(_ state: AlarmDeliveryState) -> Bool {
        guard state.hasData else { return false }
        let settings = state.settings
        let notification = settings.notificationsEnabled && state.permission == .allowed
            && (state.bannersEnabled || (state.soundEnabled && !state.outputMuted))
        let voice = settings.speakAlarms && !state.outputMuted
        return notification || voice
    }
}
