import Foundation

// Lo que comparten la app, los widgets y las acciones de Atajos. Los widgets y las acciones
// corren en extensiones con sandbox: leen (y las acciones escriben) en la carpeta de la app
// gracias a una excepción de sandbox para esa ruta, y le piden cosas a la app con URLs
// `librelibrelink://`.

/// Archivos en ~/Library/Application Support/LibreLibreLink (la carpeta real del usuario,
/// también desde una extensión con sandbox, donde `applicationSupportDirectory` apunta al contenedor).
public enum SharedFiles {
    public static var directory: URL {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appending(path: "Library/Application Support/LibreLibreLink", directoryHint: .isDirectory)
    }

    public static var history: URL { directory.appending(path: "history.sqlite") }
    public static var snapshot: URL { directory.appending(path: "snapshot.json") }
}

// MARK: - Estado para widgets y Atajos

/// Lo último que vio la app, para los widgets y las acciones de Atajos.
public struct GlucoseSnapshot: Codable, Sendable, Equatable {
    public enum Tint: String, Codable, Sendable {
        case red, orange, secondary
    }

    /// El problema más grave activo.
    public struct Problem: Codable, Sendable, Equatable {
        public var title: String
        public var symbol: String
        public var tint: Tint

        public init(title: String, symbol: String, tint: Tint) {
            self.title = title
            self.symbol = symbol
            self.tint = tint
        }
    }

    /// Resumen de hoy (desde la medianoche).
    public struct Today: Codable, Sendable, Equatable {
        public var inRange: Double
        public var below: Double
        public var above: Double
        public var mean: Double
        public var lowEvents: Int

        public init(inRange: Double, below: Double, above: Double, mean: Double, lowEvents: Int) {
            self.inRange = inRange
            self.below = below
            self.above = above
            self.mean = mean
            self.lowEvents = lowEvents
        }
    }

    public var updatedAt: Date
    public var signedIn: Bool
    public var isDemo: Bool
    /// Modo discreto: los widgets no muestran el valor.
    public var discreet: Bool
    public var patientID: String?
    public var patientName: String?
    public var display: DisplaySettings
    public var current: GlucoseMeasurement?
    /// Últimas 12 h, de la más vieja a la más nueva.
    public var readings: [GlucoseMeasurement]
    public var problem: Problem?
    public var today: Today?
    public var sensorEnd: Date?

    public init(
        updatedAt: Date, signedIn: Bool, isDemo: Bool = false, discreet: Bool = false,
        patientID: String? = nil, patientName: String? = nil, display: DisplaySettings = DisplaySettings(),
        current: GlucoseMeasurement? = nil, readings: [GlucoseMeasurement] = [], problem: Problem? = nil,
        today: Today? = nil, sensorEnd: Date? = nil
    ) {
        self.updatedAt = updatedAt
        self.signedIn = signedIn
        self.isDemo = isDemo
        self.discreet = discreet
        self.patientID = patientID
        self.patientName = patientName
        self.display = display
        self.current = current
        self.readings = readings
        self.problem = problem
        self.today = today
        self.sensorEnd = sensorEnd
    }

    /// La lectura actual si todavía sirve (menos de 20 min).
    public func freshReading(at now: Date) -> GlucoseMeasurement? {
        guard let current, now.timeIntervalSince(current.date) < GlucoseStatus.signalLossAfter else { return nil }
        return current
    }

    /// Mismo contenido, sin mirar cuándo se escribió.
    public func sameContent(as other: GlucoseSnapshot?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return other == self
    }

    public static func load(from url: URL = SharedFiles.snapshot) -> GlucoseSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(GlucoseSnapshot.self, from: data)
    }

    public func save(to url: URL = SharedFiles.snapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Comandos para la app

/// Lo que una acción de Atajos le pide a la app (que corre fuera del sandbox).
public enum AppCommand: Equatable, Sendable {
    public enum Section: String, Sendable, CaseIterable {
        case today, logbook, reports, settings
    }

    public enum Discreet: String, Sendable {
        case on, off, toggle
    }

    /// Abre la ventana, en una sección o en la última que se vio.
    case open(Section?)
    case snooze(minutes: Int)
    case resumeAlarms
    case discreet(Discreet)
    /// Se anotó algo en el registro desde afuera: releer.
    case logChanged

    public static let scheme = "librelibrelink"

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .open(let section):
            parts.host = "open"
            if let section { parts.queryItems = [URLQueryItem(name: "section", value: section.rawValue)] }
        case .snooze(let minutes):
            parts.host = "snooze"
            parts.queryItems = [URLQueryItem(name: "minutes", value: "\(minutes)")]
        case .resumeAlarms:
            parts.host = "resume"
        case .discreet(let change):
            parts.host = "discreet"
            parts.queryItems = [URLQueryItem(name: "mode", value: change.rawValue)]
        case .logChanged:
            parts.host = "log-changed"
        }
        return parts.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        switch parts.host {
        case "open":
            self = .open(query("section").flatMap(Section.init(rawValue:)))
        case "snooze":
            guard let minutes = query("minutes").flatMap(Int.init), (1...24 * 60).contains(minutes) else { return nil }
            self = .snooze(minutes: minutes)
        case "resume":
            self = .resumeAlarms
        case "discreet":
            guard let mode = query("mode").flatMap(Discreet.init(rawValue:)) else { return nil }
            self = .discreet(mode)
        case "log-changed":
            self = .logChanged
        default:
            return nil
        }
    }
}

// MARK: - Preferencias propias de la Mac

/// Combinación de teclas global que abre el panel de la barra.
public enum HotKeyChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case optionCommandG
    case controlOptionG
    case controlOptionCommandG
    case optionCommandL

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: String(localized: "Ninguno")
        case .optionCommandG: "⌥⌘G"
        case .controlOptionG: "⌃⌥G"
        case .controlOptionCommandG: "⌃⌥⌘G"
        case .optionCommandL: "⌥⌘L"
        }
    }
}

/// Cuándo correr un atajo propio del usuario.
public enum ShortcutEvent: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Empieza una baja o una baja grave.
    case low
    case high
    case signalLoss
    /// Terminó una baja o una alta.
    case backInRange

    public var id: String { rawValue }
}

public struct MacPreferences: Codable, Sendable, Equatable {
    public var hotKey: HotKeyChoice = .optionCommandG
    /// Modo discreto a mano: la barra y los widgets no muestran el valor.
    public var discreet = false
    /// Modo discreto automático mientras la cámara o el micrófono están en uso (llamadas).
    public var discreetInCalls = false
    /// Atajo (por nombre) a correr en cada evento.
    public var shortcuts: [String: String] = [:]

    public init() {}

    public func shortcut(for event: ShortcutEvent) -> String? {
        shortcuts[event.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    // Tolera claves faltantes para poder agregar preferencias sin perder las guardadas.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MacPreferences()
        hotKey = try c.decodeIfPresent(HotKeyChoice.self, forKey: .hotKey) ?? defaults.hotKey
        discreet = try c.decodeIfPresent(Bool.self, forKey: .discreet) ?? defaults.discreet
        discreetInCalls = try c.decodeIfPresent(Bool.self, forKey: .discreetInCalls) ?? defaults.discreetInCalls
        shortcuts = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? defaults.shortcuts
    }
}

/// Decide cuándo correr los atajos del usuario: una vez al empezar cada episodio, y
/// "volvió al rango" cuando termina una baja o una alta. Usa las alarmas sin pospuestas,
/// para que posponer una baja no cuente como volver al rango.
public struct ShortcutTrigger: Sendable, Equatable {
    public private(set) var active: Set<ShortcutEvent> = []

    public init() {}

    /// - Parameter hasReading: hay una lectura reciente (sin ella no se sabe si volvió al rango).
    public mutating func update(alarms: Set<AlarmKind>, hasReading: Bool) -> [ShortcutEvent] {
        var now: Set<ShortcutEvent> = []
        if alarms.contains(.urgentLow) || alarms.contains(.low) { now.insert(.low) }
        if alarms.contains(.high) { now.insert(.high) }
        if alarms.contains(.signalLoss) { now.insert(.signalLoss) }

        var due = ShortcutEvent.allCases.filter { now.contains($0) && !active.contains($0) }
        let wasOut = active.contains(.low) || active.contains(.high)
        if wasOut, !now.contains(.low), !now.contains(.high), hasReading {
            due.append(.backInRange)
        }
        // Sin lectura no se puede decir que volvió: se recuerda la baja/alta hasta saberlo.
        active = hasReading ? now : now.union(active.intersection([.low, .high]))
        return due
    }
}
