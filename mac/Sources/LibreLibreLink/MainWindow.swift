import AppKit
import Charts
import LibreKit
import SwiftUI

/// Ventana grande: "Hoy" (lectura + gráfico diario), "Registro" (anotaciones), "Informes"
/// (estadísticas del período) y "Ajustes" (alarmas, visualización y cuenta).
/// Mientras está abierta la app aparece en el Dock.
struct MainWindow: View {
    static let id = "main"

    @Bindable var store: GlucoseStore

    enum Tab: String, CaseIterable, Identifiable {
        case today, logbook, reports, settings
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .today: "Hoy"
            case .logbook: "Registro"
            case .reports: "Informes"
            case .settings: "Ajustes"
            }
        }
    }

    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(minWidth: 720, minHeight: 560)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Sección", selection: $store.windowTab) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if store.patients.count > 1 {
                    ToolbarItem {
                        Picker("Paciente", selection: Binding(
                            get: { store.selectedPatientID ?? "" },
                            set: { store.selectedPatientID = $0 }
                        )) {
                            ForEach(store.patients) { Text($0.displayName).tag($0.id) }
                        }
                    }
                }
                ToolbarItem {
                    Button { store.refreshNow() } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                }
            }
            .navigationTitle("LibreLibreLink")
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    /// Ajustes se ve aunque no haya sesión (y trae su propio scroll, como todo `Form`).
    @ViewBuilder private var content: some View {
        if store.windowTab == .settings {
            SettingsView(store: store)
        } else {
            readings
        }
    }

    private var readings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.isDemo {
                    Label("Modo demo · datos inventados", systemImage: "theatermasks.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.purple.opacity(0.10), in: Capsule())
                }
                if let error = store.historyError {
                    Label(error, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                switch store.phase {
                case .needsLogin:
                    ContentUnavailableView(
                        "Sin sesión",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Iniciá sesión de LibreLinkUp desde el ícono de la barra de menú.")
                    )
                    .frame(minHeight: 300)
                case .loading:
                    ProgressView("Conectando con LibreLinkUp…").frame(maxWidth: .infinity, minHeight: 300)
                case .ready:
                    switch store.windowTab {
                    case .today: TodayView(store: store)
                    case .logbook: LogbookView(store: store)
                    case .reports, .settings: ReportsView(store: store)
                    }
                }
                Text("No reemplaza las alarmas oficiales de LibreLink. Ante síntomas, medí con glucómetro. No usar para decidir dosis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Hoy

private struct TodayView: View {
    let store: GlucoseStore

    var body: some View {
        let today = DateInterval(start: Calendar.current.startOfDay(for: store.now), end: store.now)
        let _ = store.historyRevision
        let stats = GlucoseStatistics.compute(store.storedReadings(in: today), period: today, display: store.display)

        HStack(alignment: .top, spacing: 16) {
            CurrentReadingCard(store: store)
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    StatTile(
                        title: "En rango hoy",
                        value: stats.map { percent($0.zoneFractions[.inTarget] ?? 0) } ?? "–",
                        detail: rangeLabel(store.display),
                        tint: .green
                    )
                    StatTile(
                        title: "Promedio de hoy",
                        value: stats.map { store.display.unit.number($0.mean) } ?? "–",
                        detail: store.display.unit.symbol,
                        tint: stats.map { store.display.color(for: $0.mean) } ?? .secondary
                    )
                }
                SensorTile(sensor: store.sensor, now: store.now)
            }
            .frame(maxWidth: 360)
        }
        .fixedSize(horizontal: false, vertical: true)

        ProblemsView(conditions: store.conditions)

        DailyGraphCard(store: store)
    }
}

private struct CurrentReadingCard: View {
    let store: GlucoseStore

    var body: some View {
        Card {
            if let current = store.current {
                let fresh = store.freshReading != nil
                let unit = store.display.unit
                Text("Glucosa actual").font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(unit.reading(current.mgdL))
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(fresh ? store.display.color(for: current.mgdL) : .secondary)
                        .strikethrough(!fresh)
                    Text(unit.symbol).font(.title3).foregroundStyle(.secondary)
                    Text(current.trend?.arrow ?? "")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(fresh ? .primary : .secondary)
                }
                Text(subtitle(current))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text("Sin lecturas todavía.").foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func subtitle(_ reading: GlucoseMeasurement) -> String {
        let minutes = Int(store.now.timeIntervalSince(reading.date) / 60)
        let age = minutes < 1 ? String(localized: "recién") : String(localized: "hace \(minutes) min")
        let time = reading.date.formatted(date: .omitted, time: .shortened)
        return [reading.trend?.label, "\(age) (\(time))"].compactMap { $0 }.joined(separator: " · ")
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    var tint: Color = .primary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SensorTile: View {
    let sensor: SensorInfo?
    let now: Date

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Sensor", systemImage: "sensor").font(.caption).foregroundStyle(.secondary)
                if let sensor, sensor.isWarmingUp(at: now) {
                    Text("Calentando").font(.title3.weight(.semibold))
                    ProgressView(value: now.timeIntervalSince(sensor.activation), total: GlucoseStatus.sensorWarmup)
                    Text("Listo a las \(sensor.readyAt.formatted(date: .omitted, time: .shortened)) · \(sensor.serial)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let sensor {
                    let total = GlucoseStatus.sensorLifetime
                    let remaining = max(0, sensor.expectedEnd.timeIntervalSince(now))
                    Text(remaining > 0 ? String(localized: "Termina en \(Self.duration(remaining))") : String(localized: "Sensor terminado"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(remaining < 86_400 ? .orange : .primary)
                    ProgressView(value: total - remaining, total: total)
                        .tint(remaining < 86_400 ? .orange : .accentColor)
                    Text(verbatim: "\(sensor.expectedEnd.formatted(date: .abbreviated, time: .shortened)) · \(sensor.serial)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sin datos del sensor").foregroundStyle(.secondary)
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
        return days > 0 ? String(localized: "\(days) d \(hours) h") : String(localized: "\(hours) h")
    }
}

private struct DailyGraphCard: View {
    let store: GlucoseStore
    @State private var span: Span = .twelveHours
    /// Día elegido en el modo "Día" (medianoche local).
    @State private var day = Calendar.current.startOfDay(for: Date())

    enum Span: String, CaseIterable, Identifiable {
        case sixHours, twelveHours, day, calendarDay
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .sixHours: "6 h"
            case .twelveHours: "12 h"
            case .day: "24 h"
            case .calendarDay: "Por día"
            }
        }
    }

    var body: some View {
        let interval = interval
        let _ = store.historyRevision
        let points = store.storedReadings(in: interval)
        let entries = store.logEntries(in: interval)
        let calendar = Calendar.current

        Card {
            HStack {
                Text("Gráfico diario").font(.headline)
                Spacer()
                if span == .calendarDay {
                    Button { day = calendar.date(byAdding: .day, value: -1, to: day)! } label: { Image(systemName: "chevron.left") }
                        .disabled(store.historyStart.map { day <= $0 } ?? true)
                    Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.callout)
                        .frame(minWidth: 150)
                    Button { day = calendar.date(byAdding: .day, value: 1, to: day)! } label: { Image(systemName: "chevron.right") }
                        .disabled(calendar.isDateInToday(day))
                }
                Picker("Período", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if points.isEmpty {
                ContentUnavailableView("Sin lecturas en este período", systemImage: "chart.xyaxis.line")
                    .frame(height: 300)
            } else {
                GlucoseChart(
                    points: points,
                    display: store.display,
                    settings: store.settings,
                    domain: interval.start...interval.end,
                    hourStride: span == .sixHours ? 1 : span == .twelveHours ? 2 : 3,
                    interactive: true,
                    entries: entries
                )
                .frame(height: 300)
            }
            Legend(display: store.display, settings: store.settings)
        }
    }

    private var interval: DateInterval {
        let now = store.now
        switch span {
        case .sixHours: return DateInterval(start: now.addingTimeInterval(-6 * 3600), end: now)
        case .twelveHours: return DateInterval(start: now.addingTimeInterval(-12 * 3600), end: now)
        case .day: return DateInterval(start: now.addingTimeInterval(-24 * 3600), end: now)
        case .calendarDay:
            let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            return DateInterval(start: day, end: end)
        }
    }
}

private struct Legend: View {
    let display: DisplaySettings
    let settings: AlarmSettings

    var body: some View {
        HStack(spacing: 16) {
            item(Rectangle().fill(.green.opacity(0.25)).frame(width: 14, height: 10),
                 "Rango objetivo \(rangeLabel(display))")
            if settings.lowEnabled { item(dash(.red), "Alarma de baja") }
            if settings.highEnabled { item(dash(.orange), "Alarma de alta") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func dash(_ color: Color) -> some View {
        Rectangle().fill(color.opacity(0.6)).frame(width: 14, height: 1.5)
    }

    private func item(_ swatch: some View, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) { swatch; Text(text) }
    }
}

// MARK: - Informes

private struct ReportsView: View {
    let store: GlucoseStore
    @State private var days = 14
    @State private var report: Report?
    @State private var showingImport = false
    @State private var exportError: String?

    struct Report {
        let period: DateInterval
        let readings: [GlucoseMeasurement]
        let stats: GlucoseStatistics?
        let pattern: [DailyPatternPoint]
    }

    /// Lo que obliga a recalcular el informe.
    private struct Key: Equatable {
        let days: Int
        let patient: String?
        let revision: Int
        let display: DisplaySettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .task(id: key) { report = load() }
    }

    @ViewBuilder private var content: some View {
        let unit = store.display.unit
        HStack {
            Picker("Período", selection: $days) {
                ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) días").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let stats = report?.stats {
                Text("Datos disponibles para \(stats.daysWithData) de \(days) días")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button { showingImport = true } label: { Label("Importar", systemImage: "square.and.arrow.down") }
            Button { exportPDF() } label: { Label("Exportar PDF", systemImage: "doc.richtext") }
                .disabled(report?.stats == nil)
        }
        .sheet(isPresented: $showingImport) { ImportSheet(store: store) }
        .alert("No se pudo exportar el PDF", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
        } message: {
            Text(verbatim: exportError ?? "")
        }

        if let report {
            if let stats = report.stats {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    StatTile(title: "Glucosa promedio", value: unit.number(stats.mean), detail: unit.symbol,
                             tint: store.display.color(for: stats.mean))
                    StatTile(title: "A1c estimada (GMI)", value: stats.gmi.formatted(.number.precision(.fractionLength(1))) + " %",
                             detail: String(localized: "Aproximación; no reemplaza el análisis"))
                    StatTile(title: "Variabilidad (CV)", value: percent(stats.coefficientOfVariation / 100),
                             detail: stats.coefficientOfVariation <= 36 ? String(localized: "Estable (≤ 36 %)") : String(localized: "Alta (> 36 %)"),
                             tint: stats.coefficientOfVariation <= 36 ? .primary : .orange)
                    StatTile(title: "Uso del sensor", value: percent(stats.coverage),
                             detail: String(localized: "del tiempo con lecturas"))
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 16) {
                    TimeInRangeCard(stats: stats, display: store.display)
                        .frame(maxWidth: 320)
                    DailyPatternCard(pattern: report.pattern, enoughDays: stats.daysWithData >= DailyPattern.minimumDays,
                                     display: store.display)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Card {
                    ContentUnavailableView(
                        "Todavía no hay historial",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("LibreLibreLink guarda las lecturas mientras está abierta. Los informes se llenan con los días.")
                    )
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    /// Guarda el informe AGP del período elegido y lo abre.
    private func exportPDF() {
        guard let report, let stats = report.stats else { return }
        let agp = AGPReport(
            patient: store.patients.first { $0.id == store.selectedPatientID }?.displayName,
            period: report.period,
            readings: report.readings,
            stats: stats,
            display: store.display
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = agp.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try agp.pdf().write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var key: Key {
        Key(days: days, patient: store.selectedPatientID, revision: store.historyRevision, display: store.display)
    }

    private func load() -> Report {
        let end = store.now
        let period = DateInterval(start: end.addingTimeInterval(-Double(days) * 86_400), end: end)
        let readings = store.storedReadings(in: period)
        return Report(
            period: period,
            readings: readings,
            stats: GlucoseStatistics.compute(readings, period: period, display: store.display),
            pattern: DailyPattern.compute(readings)
        )
    }
}

/// Explica qué hace la importación y deja elegir el CSV de LibreView.
private struct ImportSheet: View {
    let store: GlucoseStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var outcome: Result<String, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar historial de LibreView").font(.headline)
            switch outcome {
            case nil:
                Text("Agrega a los informes las lecturas de un archivo CSV de LibreView (en libreview.com: Descargar datos de glucosa). Las lecturas que ya están no se modifican.")
                if store.patients.count > 1, let patient = store.patients.first(where: { $0.id == store.selectedPatientID }) {
                    Text("Se importan para \(patient.displayName).").foregroundStyle(.secondary)
                }
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if case .success = outcome {
                    Button("Listo") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Elegir archivo…") { choosingFile = true }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            outcome = result.flatMap { url in Result { try summary(store.importLibreView(from: url)) } }
        }
    }

    private func summary(_ imported: (added: Int, interval: DateInterval?)) -> String {
        guard let interval = imported.interval else { return String(localized: "No había lecturas nuevas.") }
        let range = "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(interval.end.formatted(date: .abbreviated, time: .omitted))"
        return imported.added == 0
            ? String(localized: "No había lecturas nuevas (\(range)).")
            : String(localized: "Se agregaron \(imported.added) lecturas (\(range)).")
    }
}

private struct TimeInRangeCard: View {
    let stats: GlucoseStatistics
    let display: DisplaySettings

    var body: some View {
        Card(title: "Tiempo en rango") {
            let zones = GlucoseZone.allCases.reversed()
            HStack(alignment: .top, spacing: 16) {
                // Barra apilada vertical: arriba lo alto, abajo lo bajo.
                VStack(spacing: 2) {
                    ForEach(Array(zones), id: \.self) { zone in
                        let fraction = stats.zoneFractions[zone] ?? 0
                        if fraction > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(zone.color)
                                .frame(height: max(4, 200 * fraction))
                        }
                    }
                }
                .frame(width: 36, height: 200, alignment: .bottom)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(zones), id: \.self) { zone in
                        let fraction = stats.zoneFractions[zone] ?? 0
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(percent(fraction))
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(zone.color)
                                Text(zone.label).font(.callout)
                            }
                            Text(verbatim: "\(rangeText(zone)) · \(perDay(fraction))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Label("Episodios de baja: \(stats.lowEvents)", systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(stats.lowEvents > 0 ? .red : .secondary)
                    Text("< \(display.unit.withSymbol(GlucoseStatistics.lowEventThreshold)) durante 15 min o más")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rangeText(_ zone: GlucoseZone) -> String {
        let unit = display.unit
        switch zone {
        case .above: return "> \(unit.withSymbol(display.targetHigh))"
        case .inTarget: return rangeLabel(display)
        case .below: return "< \(unit.withSymbol(display.targetLow))"
        }
    }

    private func perDay(_ fraction: Double) -> String {
        let minutes = Int((fraction * 24 * 60).rounded())
        return minutes >= 60
            ? String(localized: "\(minutes / 60) h \(minutes % 60) min/día")
            : String(localized: "\(minutes) min/día")
    }
}

private struct DailyPatternCard: View {
    let pattern: [DailyPatternPoint]
    let enoughDays: Bool
    let display: DisplaySettings

    var body: some View {
        Card(title: "Patrones diarios") {
            if !enoughDays || pattern.isEmpty {
                ContentUnavailableView(
                    "Faltan datos",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Hacen falta al menos \(DailyPattern.minimumDays) días con lecturas.")
                )
                .frame(height: 220)
            } else {
                let maxValue = min(400, max(250, (pattern.map(\.p90).max() ?? 0) + 20))
                Chart {
                    RectangleMark(xStart: nil, xEnd: nil,
                                  yStart: .value("Bajo", display.targetLow), yEnd: .value("Alto", display.targetHigh))
                        .foregroundStyle(.green.opacity(0.12))
                    ForEach(pattern, id: \.minute) { point in
                        AreaMark(x: .value("Hora", point.minute), yStart: .value("P10", point.p10), yEnd: .value("P90", point.p90),
                                 series: .value("Banda", "10–90"))
                            .foregroundStyle(.blue.opacity(0.12))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(pattern, id: \.minute) { point in
                        AreaMark(x: .value("Hora", point.minute), yStart: .value("P25", point.p25), yEnd: .value("P75", point.p75),
                                 series: .value("Banda", "25–75"))
                            .foregroundStyle(.blue.opacity(0.25))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(pattern, id: \.minute) { point in
                        LineMark(x: .value("Hora", point.minute), y: .value("Mediana", point.p50))
                            .foregroundStyle(.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXScale(domain: 0...(24 * 60))
                .chartYScale(domain: 40...maxValue)
                .chartXAxis {
                    AxisMarks(values: Array(stride(from: 0, through: 24 * 60, by: 180))) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let minute = value.as(Int.self) { Text(verbatim: "\(minute / 60) h") }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [display.targetLow, display.targetHigh, 250, 350].filter { $0 <= maxValue }) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let mgdL = value.as(Double.self) { Text(display.unit.number(mgdL)) }
                        }
                    }
                }
                .frame(height: 220)

                HStack(spacing: 16) {
                    swatch(Rectangle().fill(.primary).frame(width: 14, height: 2.5), "Mediana")
                    swatch(Rectangle().fill(.blue.opacity(0.25)).frame(width: 14, height: 10), "Percentil 25–75")
                    swatch(Rectangle().fill(.blue.opacity(0.12)).frame(width: 14, height: 10), "Percentil 10–90")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func swatch(_ shape: some View, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) { shape; Text(text) }
    }
}

/// "70–180 mg/dL" en la unidad elegida.
func rangeLabel(_ display: DisplaySettings) -> String {
    "\(display.unit.number(display.targetLow))–\(display.unit.withSymbol(display.targetHigh))"
}

func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}
