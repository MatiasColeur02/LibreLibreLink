import Foundation

/// Umbrales y alarmas elegidos por el usuario. Todo en mg/dL (R10).
public struct AlarmSettings: Codable, Sendable, Equatable {
    /// Notificaciones apagadas por defecto (R9). El estado en la barra se muestra siempre.
    public var notificationsEnabled = false
    public var lowEnabled = true
    public var lowThreshold = 70.0
    public var highEnabled = true
    public var highThreshold = 240.0
    public var signalLossEnabled = true
    /// Avisos del sensor: nuevo, listo, termina en 3 días / 1 día / 1 hora, terminado.
    public var sensorNoticesEnabled = true
    /// "Baja en camino": avisa si, al ritmo actual, cruzaría el umbral de baja en ≤ 15 min.
    public var lowSoonEnabled = true
    /// Leer las alarmas en voz alta (suena aunque Concentración silencie las notificaciones).
    public var speakAlarms = false
    /// "Bajando rápido": más de 2 mg/dL por minuto, aunque todavía esté en rango.
    public var fallingFastEnabled = false
    /// Avisar la alta solo si dura al menos esto (0 = enseguida). La barra la muestra igual.
    public var highDelay: TimeInterval = 0
    /// Si una baja no se atiende en 10 min: repetir cada 2 min y leerla en voz alta.
    public var escalationEnabled = true

    /// Horario de noche, con umbrales propios. Minutos desde la medianoche (hora local).
    public var nightEnabled = false
    public var nightStart = 23 * 60
    public var nightEnd = 7 * 60
    public var nightLowThreshold = 80.0
    public var nightHighThreshold = 270.0
    /// No avisar la alta de noche (la barra la sigue mostrando).
    public var nightSilencesHigh = false

    public static let lowRange = 60.0...100.0
    public static let highRange = 120.0...400.0
    /// Baja grave: fija, no configurable (R14).
    public static let urgentLowThreshold = 55.0
    public static let highDelayOptions: [TimeInterval] = [0, 30 * 60, 3600, 2 * 3600, 3 * 3600]

    public init() {}

    /// Si `date` cae en el horario de noche (puede cruzar la medianoche).
    public func isNight(at date: Date, calendar: Calendar = .current) -> Bool {
        guard nightEnabled, nightStart != nightEnd else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return nightStart < nightEnd
            ? (nightStart..<nightEnd).contains(minute)
            : minute >= nightStart || minute < nightEnd
    }

    /// Los ajustes que rigen a esa hora: de noche, los umbrales de noche.
    public func effective(at date: Date, calendar: Calendar = .current) -> AlarmSettings {
        guard isNight(at: date, calendar: calendar) else { return self }
        var night = self
        night.lowThreshold = nightLowThreshold
        night.highThreshold = nightHighThreshold
        return night
    }

    // Tolera claves faltantes para poder agregar ajustes sin perder los guardados.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlarmSettings()
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        lowEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowEnabled) ?? defaults.lowEnabled
        lowThreshold = try c.decodeIfPresent(Double.self, forKey: .lowThreshold) ?? defaults.lowThreshold
        highEnabled = try c.decodeIfPresent(Bool.self, forKey: .highEnabled) ?? defaults.highEnabled
        highThreshold = try c.decodeIfPresent(Double.self, forKey: .highThreshold) ?? defaults.highThreshold
        signalLossEnabled = try c.decodeIfPresent(Bool.self, forKey: .signalLossEnabled) ?? defaults.signalLossEnabled
        sensorNoticesEnabled = try c.decodeIfPresent(Bool.self, forKey: .sensorNoticesEnabled) ?? defaults.sensorNoticesEnabled
        lowSoonEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowSoonEnabled) ?? defaults.lowSoonEnabled
        speakAlarms = try c.decodeIfPresent(Bool.self, forKey: .speakAlarms) ?? defaults.speakAlarms
        fallingFastEnabled = try c.decodeIfPresent(Bool.self, forKey: .fallingFastEnabled) ?? defaults.fallingFastEnabled
        highDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .highDelay) ?? defaults.highDelay
        escalationEnabled = try c.decodeIfPresent(Bool.self, forKey: .escalationEnabled) ?? defaults.escalationEnabled
        nightEnabled = try c.decodeIfPresent(Bool.self, forKey: .nightEnabled) ?? defaults.nightEnabled
        nightStart = try c.decodeIfPresent(Int.self, forKey: .nightStart) ?? defaults.nightStart
        nightEnd = try c.decodeIfPresent(Int.self, forKey: .nightEnd) ?? defaults.nightEnd
        nightLowThreshold = try c.decodeIfPresent(Double.self, forKey: .nightLowThreshold) ?? defaults.nightLowThreshold
        nightHighThreshold = try c.decodeIfPresent(Double.self, forKey: .nightHighThreshold) ?? defaults.nightHighThreshold
        nightSilencesHigh = try c.decodeIfPresent(Bool.self, forKey: .nightSilencesHigh) ?? defaults.nightSilencesHigh
    }
}

/// Problema visible en la barra de menú y en el panel.
public enum GlucoseCondition: Hashable, Sendable {
    case urgentLow
    case low
    /// Todavía no está baja, pero al ritmo actual cruza el umbral de baja a esa hora (estimado).
    case lowSoon(Date)
    /// Baja más de 2 mg/dL por minuto, todavía en rango.
    case fallingFast
    case high
    /// Sin lectura nueva desde hace ≥ 20 min, aunque LibreLinkUp responde.
    case signalLoss
    /// Lectura de 10 a 20 min de antigüedad.
    case stale
    /// Falla la red o la API (el texto es el error).
    case connectionError(String)
    /// Hace falta iniciar sesión o aceptar algo en LibreLinkUp.
    case needsAttention(String)
    /// Sensor nuevo en sus primeros 60 min: todavía no hay lecturas (listo a esa hora).
    case sensorWarmingUp(Date)
    case sensorExpiringSoon(Date)
    case sensorExpired

    public enum Severity: Int, Comparable, Sendable {
        case info = 0, warning, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var severity: Severity {
        switch self {
        case .urgentLow: .critical
        case .low, .lowSoon, .fallingFast, .high, .signalLoss, .connectionError, .needsAttention, .sensorExpired: .warning
        case .stale, .sensorWarmingUp, .sensorExpiringSoon: .info
        }
    }

    public var title: String {
        switch self {
        case .urgentLow: String(localized: "Glucosa muy baja")
        case .low: String(localized: "Glucosa baja")
        case .lowSoon: String(localized: "Baja en camino")
        case .fallingFast: String(localized: "Bajando rápido")
        case .high: String(localized: "Glucosa alta")
        case .signalLoss: String(localized: "Sin señal del sensor")
        case .stale: String(localized: "Lectura desactualizada")
        case .connectionError: String(localized: "Sin conexión con LibreLinkUp")
        case .needsAttention: String(localized: "Revisar la cuenta")
        case .sensorWarmingUp: String(localized: "Sensor calentando")
        case .sensorExpiringSoon: String(localized: "El sensor termina pronto")
        case .sensorExpired: String(localized: "Sensor terminado")
        }
    }

    public var detail: String {
        switch self {
        case .urgentLow: String(localized: "Por debajo de \(Int(AlarmSettings.urgentLowThreshold)) mg/dL. Comprobá con glucómetro y tratá ya.")
        case .low: String(localized: "Por debajo del umbral de baja. Comprobá con glucómetro.")
        case .lowSoon(let crossing):
            String(localized: "Bajando: a este ritmo cruza el umbral de baja cerca de las \(crossing.formatted(date: .omitted, time: .shortened)). Es una estimación; comprobá con glucómetro.")
        case .fallingFast: String(localized: "Baja más de 2 mg/dL por minuto, aunque todavía está en rango. Comprobá con glucómetro.")
        case .high: String(localized: "Por encima del umbral de alta. Comprobá con glucómetro.")
        case .signalLoss: String(localized: "No llegan lecturas nuevas hace más de 20 min. ¿El iPhone está cerca del sensor, con LibreLink abierta e internet?")
        case .stale: String(localized: "La última lectura tiene más de 10 min.")
        case .connectionError(let message): message
        case .needsAttention(let message): message
        case .sensorWarmingUp(let ready):
            String(localized: "Las lecturas empiezan a las \(ready.formatted(date: .omitted, time: .shortened)).")
        case .sensorExpiringSoon(let end):
            String(localized: "Termina \(end.formatted(.relative(presentation: .named))). Tené uno de repuesto.")
        case .sensorExpired: String(localized: "Ya pasaron los 15 días. Reemplazalo y activalo con LibreLink.")
        }
    }

    /// Nombre de SF Symbol.
    public var symbolName: String {
        switch self {
        case .urgentLow: "exclamationmark.octagon.fill"
        case .low: "arrow.down.circle.fill"
        case .lowSoon: "arrow.down.right.circle.fill"
        case .fallingFast: "arrow.down.to.line.circle.fill"
        case .high: "arrow.up.circle.fill"
        case .signalLoss: "antenna.radiowaves.left.and.right.slash"
        case .stale: "clock"
        case .connectionError: "wifi.slash"
        case .needsAttention: "person.crop.circle.badge.exclamationmark"
        case .sensorWarmingUp: "timer"
        case .sensorExpiringSoon: "hourglass"
        case .sensorExpired: "sensor.fill"
        }
    }

    /// Tipo de alarma que dispara notificaciones, si corresponde.
    public var alarm: AlarmKind? {
        switch self {
        case .urgentLow: .urgentLow
        case .low: .low
        case .lowSoon: .lowSoon
        case .fallingFast: .fallingFast
        case .high: .high
        case .signalLoss: .signalLoss
        default: nil
        }
    }
}

public enum GlucoseStatus {
    public static let staleAfter: TimeInterval = 10 * 60
    public static let signalLossAfter: TimeInterval = 20 * 60
    /// Libre 2 Plus: 15 días (I: no se lee de la API).
    public static let sensorLifetime: TimeInterval = 15 * 24 * 3600
    /// Calentamiento tras activar el sensor (guía p. 28).
    public static let sensorWarmup: TimeInterval = 60 * 60

    /// Problemas activos, del más grave al más leve.
    /// - Parameters:
    ///   - recent: lecturas de los últimos minutos, para estimar la tendencia ("baja en camino").
    ///   - fetched: si ya hubo al menos una consulta exitosa (para no marcar
    ///     "sin señal" antes de la primera respuesta).
    public static func conditions(
        current: GlucoseMeasurement?,
        recent: [GlucoseMeasurement] = [],
        sensor: SensorInfo?,
        settings: AlarmSettings,
        fetched: Bool,
        connectionError: String?,
        needsAttention: String?,
        now: Date,
        calendar: Calendar = .current
    ) -> [GlucoseCondition] {
        // De noche rigen los umbrales de noche.
        let settings = settings.effective(at: now, calendar: calendar)
        var result: [GlucoseCondition] = []
        if let needsAttention { result.append(.needsAttention(needsAttention)) }
        if let connectionError { result.append(.connectionError(connectionError)) }

        // Durante el calentamiento no hay lecturas del sensor nuevo: no es "sin señal".
        if let sensor, sensor.isWarmingUp(at: now), current.map({ $0.date < sensor.activation }) ?? true {
            result.append(.sensorWarmingUp(sensor.readyAt))
        } else if let current {
            let age = now.timeIntervalSince(current.date)
            if age >= signalLossAfter {
                result.append(.signalLoss)
            } else {
                // Solo se juzga la glucosa si la lectura es reciente.
                if age >= staleAfter { result.append(.stale) }
                if current.mgdL < AlarmSettings.urgentLowThreshold {
                    result.append(.urgentLow)
                } else if settings.lowEnabled, current.mgdL < settings.lowThreshold {
                    result.append(.low)
                } else if settings.highEnabled, current.mgdL > settings.highThreshold {
                    result.append(.high)
                } else if age < staleAfter {
                    if settings.lowEnabled, settings.lowSoonEnabled,
                       let crossing = GlucoseForecast.lowCrossing(
                           below: settings.lowThreshold, readings: recent, latest: current, now: now) {
                        result.append(.lowSoon(crossing))
                    } else if settings.fallingFastEnabled, GlucoseForecast.isFallingFast(recent, latest: current) {
                        result.append(.fallingFast)
                    }
                }
            }
        } else if fetched {
            result.append(.signalLoss)
        }

        if let end = sensor?.expectedEnd {
            if end <= now {
                result.append(.sensorExpired)
            } else if end.timeIntervalSince(now) < 24 * 3600 {
                result.append(.sensorExpiringSoon(end))
            }
        }

        return result.enumerated()
            .sorted { ($0.element.severity, -$0.offset) > ($1.element.severity, -$1.offset) }
            .map(\.element)
    }

    /// Desde cuándo está por encima de `threshold` sin interrupción (una laguna de más de
    /// 30 min corta la racha), o `nil` si la última lectura no está alta.
    public static func highSince(_ readings: [GlucoseMeasurement], threshold: Double) -> Date? {
        var since: Date?
        for reading in readings.sorted(by: { $0.date > $1.date }) {
            guard reading.mgdL > threshold else { break }
            if let since, since.timeIntervalSince(reading.date) > 30 * 60 { break }
            since = reading.date
        }
        return since
    }

    /// Texto del valor: "LO" < 40 y "HI" > 500 (R2).
    public static func displayValue(_ mgdL: Double) -> String {
        GlucoseUnit.mgdL.reading(mgdL)
    }
}

// MARK: - Episodios de alarma

public enum AlarmKind: String, Codable, Sendable, CaseIterable {
    case urgentLow, low, lowSoon, fallingFast, high, signalLoss

    /// Lo que queda pospuesto al posponer esta alarma: posponer una baja también calla
    /// los avisos de baja más leves (no al revés: una baja grave sigue sonando).
    public var snoozeCovers: [AlarmKind] {
        switch self {
        case .urgentLow: [.urgentLow, .low, .lowSoon, .fallingFast]
        case .low: [.low, .lowSoon, .fallingFast]
        case .lowSoon, .fallingFast: [.lowSoon, .fallingFast]
        case .high, .signalLoss: [self]
        }
    }

    /// Alarmas de baja: tienen la acción "Ya comí" (regla 15-15).
    public var isLow: Bool { snoozeCovers.contains(.lowSoon) }
}

/// Decide cuándo notificar (R12): una vez al empezar el episodio y otra cada
/// `repeatInterval` mientras siga; el episodio termina cuando la condición desaparece.
/// Escalada: una baja que nadie atiende en `escalateAfter` pasa a repetirse cada
/// `escalatedRepeatInterval`.
public struct AlarmEngine: Codable, Sendable, Equatable {
    public static let repeatInterval: TimeInterval = 5 * 60
    public static let escalateAfter: TimeInterval = 10 * 60
    public static let escalatedRepeatInterval: TimeInterval = 2 * 60
    public static let escalating: Set<AlarmKind> = [.urgentLow, .low]

    /// Última notificación por episodio activo.
    public private(set) var lastNotified: [AlarmKind: Date] = [:]
    /// Comienzo de cada episodio activo.
    public private(set) var started: [AlarmKind: Date] = [:]
    /// Episodios que el usuario atendió (tocó la notificación o eligió una acción).
    public private(set) var acknowledged: Set<AlarmKind> = []

    public init() {}

    /// - Parameter escalate: si está activada la escalada.
    /// - Returns: alarmas a notificar ahora, de la más grave a la más leve.
    public mutating func update(active: Set<AlarmKind>, now: Date, escalate: Bool = false) -> [AlarmKind] {
        for kind in Set(started.keys).union(lastNotified.keys) where !active.contains(kind) {
            lastNotified[kind] = nil
            started[kind] = nil
            acknowledged.remove(kind)
        }
        var due: [AlarmKind] = []
        for kind in AlarmKind.allCases where active.contains(kind) {
            if started[kind] == nil { started[kind] = now }
            let interval = escalate && isEscalated(kind, now: now) ? Self.escalatedRepeatInterval : Self.repeatInterval
            if let last = lastNotified[kind], now.timeIntervalSince(last) < interval { continue }
            // La baja grave ya cubre la baja: no notificar las dos.
            if kind == .low, active.contains(.urgentLow) { continue }
            lastNotified[kind] = now
            due.append(kind)
        }
        return due
    }

    /// El usuario atendió la alarma: deja de escalar hasta que termine el episodio.
    public mutating func acknowledge(_ kind: AlarmKind) {
        for covered in kind.snoozeCovers where started[covered] != nil {
            acknowledged.insert(covered)
        }
    }

    /// Una baja activa hace `escalateAfter` o más que nadie atendió.
    public func isEscalated(_ kind: AlarmKind, now: Date) -> Bool {
        guard Self.escalating.contains(kind), !acknowledged.contains(kind), let start = started[kind] else { return false }
        return now.timeIntervalSince(start) >= Self.escalateAfter
    }
}

/// Alarmas pospuestas desde la notificación ("Posponer 30 min", "Ya comí").
public struct AlarmSnoozes: Codable, Sendable, Equatable {
    /// La baja grave se puede posponer como mucho esto.
    public static let urgentLowLimit: TimeInterval = 15 * 60

    public private(set) var until: [AlarmKind: Date] = [:]

    public init() {}

    public mutating func snooze(_ kind: AlarmKind, for duration: TimeInterval, now: Date) {
        let end = now.addingTimeInterval(kind == .urgentLow ? min(duration, Self.urgentLowLimit) : duration)
        for covered in kind.snoozeCovers {
            until[covered] = max(until[covered] ?? .distantPast, end)
        }
    }

    public func isSnoozed(_ kind: AlarmKind, now: Date) -> Bool {
        (until[kind] ?? .distantPast) > now
    }

    /// Las pospuestas que siguen vigentes, de la más grave a la más leve.
    public func active(now: Date) -> [(kind: AlarmKind, until: Date)] {
        AlarmKind.allCases.compactMap { kind in
            until[kind].flatMap { $0 > now ? (kind, $0) : nil }
        }
    }

    public mutating func cancelAll() { until = [:] }
}

/// Qué alarmas deben avisar a partir de los problemas activos: aplica los ajustes que
/// no cambian lo que muestra la barra (sin señal, alta sostenida, silencio de noche,
/// pospuestas).
public enum AlarmPolicy {
    public static func alarms(
        conditions: [GlucoseCondition],
        readings: [GlucoseMeasurement],
        settings: AlarmSettings,
        snoozes: AlarmSnoozes,
        now: Date,
        calendar: Calendar = .current
    ) -> Set<AlarmKind> {
        let effective = settings.effective(at: now, calendar: calendar)
        let night = settings.isNight(at: now, calendar: calendar)
        return Set(conditions.compactMap(\.alarm)).filter { kind in
            if snoozes.isSnoozed(kind, now: now) { return false }
            switch kind {
            case .signalLoss:
                return settings.signalLossEnabled
            case .high:
                if night, settings.nightSilencesHigh { return false }
                guard settings.highDelay > 0 else { return true }
                guard let since = GlucoseStatus.highSince(readings, threshold: effective.highThreshold) else { return false }
                return now.timeIntervalSince(since) >= settings.highDelay
            default:
                return true
            }
        }
    }
}
