import AppIntents
import AppKit
import Foundation
import LibreKit

// Acciones de Atajos / Siri / Spotlight. Corren en una extensión (con firma local, macOS no
// logra hablar con acciones dentro de la app). Leen el resumen que escribe la app, anotan
// directo en el historial y, para lo demás, le mandan a la app una URL `librelibrelink://`.

@main
struct LibreLibreLinkIntents: AppIntentsExtension {}

struct LibreLibreLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetGlucoseIntent(),
            phrases: [
                "Cuál es mi glucosa en \(.applicationName)",
                "Glucosa en \(.applicationName)",
                "What's my glucose in \(.applicationName)",
            ],
            shortTitle: "Glucosa actual",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: TodaySummaryIntent(),
            phrases: ["Resumen de hoy en \(.applicationName)", "Today's summary in \(.applicationName)"],
            shortTitle: "Resumen de hoy",
            systemImageName: "chart.pie"
        )
        AppShortcut(
            intent: LogEntryIntent(),
            phrases: ["Anotar en \(.applicationName)", "Log in \(.applicationName)"],
            shortTitle: "Anotar",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SnoozeAlarmsIntent(),
            phrases: ["Posponer alarmas de \(.applicationName)", "Snooze \(.applicationName) alarms"],
            shortTitle: "Posponer alarmas",
            systemImageName: "bell.slash"
        )
        AppShortcut(
            intent: DiscreetModeIntent(),
            phrases: ["Modo discreto en \(.applicationName)", "Discreet mode in \(.applicationName)"],
            shortTitle: "Modo discreto",
            systemImageName: "eye.slash"
        )
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case noRecentReading
    case invalidEntry
    case history(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: "LibreLibreLink no tiene sesión de LibreLinkUp. Abrí la app e iniciá sesión."
        case .noRecentReading: "No hay lecturas de los últimos 20 minutos."
        case .invalidEntry: "Falta el valor, está fuera de rango o la nota está vacía."
        case .history(let message): "No se pudo anotar: \(message)"
        }
    }
}

/// Lo que escribió la app, o error si no hay sesión.
private func snapshot() throws -> GlucoseSnapshot {
    guard let snapshot = GlucoseSnapshot.load(), snapshot.signedIn else { throw IntentError.notSignedIn }
    return snapshot
}

/// Le pide algo a la app (la abre si estaba cerrada, sin traerla al frente salvo que se pida).
private func send(_ command: AppCommand, activate: Bool = false) async {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activate
    _ = try? await NSWorkspace.shared.open(command.url, configuration: configuration)
}

// MARK: - Glucosa

struct GetGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener glucosa"
    static let description = IntentDescription(
        "Devuelve la última lectura en la unidad elegida en LibreLibreLink, para usarla en otros atajos (por ejemplo: si es menor que 70, pausar la música)."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let snapshot = try snapshot()
        guard let reading = snapshot.freshReading(at: .now) else { throw IntentError.noRecentReading }
        let unit = snapshot.display.unit
        let minutes = Int(Date.now.timeIntervalSince(reading.date) / 60)
        let age = minutes < 1 ? String(localized: "recién") : String(localized: "hace \(minutes) min")
        var parts = ["\(unit.withSymbol(reading.mgdL))"]
        if let trend = reading.trend, trend != .unknown { parts.append(trend.label.lowercased()) }
        parts.append(age)
        if let problem = snapshot.problem { parts.append(problem.title) }
        let text = parts.joined(separator: ", ")
        return .result(value: unit.convert(reading.mgdL), dialog: "\(text)")
    }
}

struct TodaySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Resumen de hoy"
    static let description = IntentDescription("Tiempo en rango, promedio y bajas desde la medianoche.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = try snapshot()
        guard let today = snapshot.today else { throw IntentError.noRecentReading }
        let percent = today.inRange.formatted(.percent.precision(.fractionLength(0)))
        let mean = snapshot.display.unit.withSymbol(today.mean)
        let text = String(localized: "Hoy: \(percent) en rango, promedio \(mean), \(today.lowEvents) bajas.")
        return .result(value: text, dialog: "\(text)")
    }
}

// MARK: - Registro

enum LogKindOption: String, AppEnum {
    case carbs, rapidInsulin, longInsulin, exercise, fingerstick, note

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tipo de anotación"
    static let caseDisplayRepresentations: [LogKindOption: DisplayRepresentation] = [
        .carbs: "Carbohidratos (g)",
        .rapidInsulin: "Insulina rápida (U)",
        .longInsulin: "Insulina lenta (U)",
        .exercise: "Ejercicio (min)",
        .fingerstick: "Glucómetro",
        .note: "Nota",
    ]

    var kind: LogKind { LogKind(rawValue: rawValue)! }
}

struct LogEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Anotar en el registro"
    static let description = IntentDescription(
        "Anota carbohidratos, insulina, ejercicio, un pinchazo con glucómetro (en la unidad elegida) o una nota, con la hora actual."
    )

    @Parameter(title: "Tipo")
    var kind: LogKindOption

    @Parameter(title: "Cantidad")
    var value: Double?

    @Parameter(title: "Nota")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Anotar \(\.$kind) \(\.$value)") {
            \.$note
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = try snapshot()
        guard let patient = snapshot.patientID else { throw IntentError.notSignedIn }
        var amount = value
        // El glucómetro se guarda en mg/dL.
        if kind == .fingerstick, snapshot.display.unit == .mmolL { amount = amount.map { $0 * GlucoseUnit.mmolFactor } }
        let entry = LogEntry(date: .now, kind: kind.kind, value: kind == .note ? nil : amount, note: note ?? "")
        guard entry.isValid else { throw IntentError.invalidEntry }
        do {
            try HistoryDatabase(url: SharedFiles.history).save(entry, patientID: patient)
        } catch {
            throw IntentError.history(error.localizedDescription)
        }
        await send(.logChanged)
        return .result(dialog: "Anotado.")
    }
}

// MARK: - Control

struct SnoozeAlarmsIntent: AppIntent {
    static let title: LocalizedStringResource = "Posponer alarmas"
    static let description = IntentDescription("Pospone las alarmas de LibreLibreLink. La baja grave sigue avisando.")

    @Parameter(title: "Minutos", default: 30, inclusiveRange: (5, 240))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Posponer alarmas \(\.$minutes) min")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await send(.snooze(minutes: minutes))
        return .result(dialog: "Alarmas pospuestas \(minutes) min. La baja grave sigue avisando.")
    }
}

struct ResumeAlarmsIntent: AppIntent {
    static let title: LocalizedStringResource = "Reactivar alarmas"
    static let description = IntentDescription("Vuelve a activar las alarmas pospuestas.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await send(.resumeAlarms)
        return .result(dialog: "Alarmas reactivadas.")
    }
}

enum DiscreetOption: String, AppEnum {
    case toggle, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Modo discreto"
    static let caseDisplayRepresentations: [DiscreetOption: DisplayRepresentation] = [
        .toggle: "Alternar",
        .on: "Activar",
        .off: "Desactivar",
    ]
}

struct DiscreetModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Modo discreto"
    static let description = IntentDescription("Oculta o vuelve a mostrar el valor en la barra de menú y en los widgets.")

    @Parameter(title: "Acción", default: .toggle)
    var mode: DiscreetOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode) el modo discreto")
    }

    func perform() async throws -> some IntentResult {
        await send(.discreet(AppCommand.Discreet(rawValue: mode.rawValue)!))
        return .result()
    }
}

enum SectionOption: String, AppEnum {
    case today, logbook, reports, settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sección"
    static let caseDisplayRepresentations: [SectionOption: DisplayRepresentation] = [
        .today: "Hoy",
        .logbook: "Registro",
        .reports: "Informes",
        .settings: "Ajustes",
    ]
}

struct OpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir LibreLibreLink"
    static let description = IntentDescription("Abre la ventana de LibreLibreLink en una sección.")

    @Parameter(title: "Sección", default: .today)
    var section: SectionOption

    static var parameterSummary: some ParameterSummary {
        Summary("Abrir LibreLibreLink en \(\.$section)")
    }

    func perform() async throws -> some IntentResult {
        await send(.open(AppCommand.Section(rawValue: section.rawValue)), activate: true)
        return .result()
    }
}
