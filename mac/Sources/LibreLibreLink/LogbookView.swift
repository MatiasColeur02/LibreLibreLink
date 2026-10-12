import LibreKit
import SwiftUI

// Registro (R22–R23): comidas, insulina, ejercicio, pinchazos y notas, con lo que hizo
// la glucosa después de comer y la diferencia entre el glucómetro y el sensor.

extension LogKind {
    var title: String {
        switch self {
        case .carbs: String(localized: "Comida")
        case .rapidInsulin: String(localized: "Insulina rápida")
        case .longInsulin: String(localized: "Insulina lenta")
        case .exercise: String(localized: "Ejercicio")
        case .fingerstick: String(localized: "Glucómetro")
        case .note: String(localized: "Nota")
        }
    }

    var symbol: String {
        switch self {
        case .carbs: "fork.knife"
        case .rapidInsulin: "syringe"
        case .longInsulin: "syringe.fill"
        case .exercise: "figure.walk"
        case .fingerstick: "drop.fill"
        case .note: "text.bubble"
        }
    }

    /// Colores fuera del verde/naranja/rojo de la glucosa.
    var color: Color {
        switch self {
        case .carbs: .brown
        case .rapidInsulin: .blue
        case .longInsulin: .indigo
        case .exercise: .teal
        case .fingerstick: .pink
        case .note: .gray
        }
    }

    /// Unidad del valor en el formulario.
    func unitLabel(_ unit: GlucoseUnit) -> String {
        switch self {
        case .carbs: String(localized: "g de carbohidratos")
        case .rapidInsulin, .longInsulin: String(localized: "U")
        case .exercise: String(localized: "min")
        case .fingerstick: unit.symbol
        case .note: ""
        }
    }
}

extension LogEntry {
    /// "45 g de carbohidratos", "4 U insulina rápida", "Glucómetro 112 mg/dL", o la nota.
    func summary(unit: GlucoseUnit) -> String {
        let number = value?.formatted(.number.precision(.fractionLength(0...1))) ?? ""
        let text = switch kind {
        case .carbs: String(localized: "\(number) g de carbohidratos")
        case .rapidInsulin: String(localized: "\(number) U de insulina rápida")
        case .longInsulin: String(localized: "\(number) U de insulina lenta")
        case .exercise: String(localized: "\(number) min de ejercicio")
        case .fingerstick: String(localized: "Glucómetro \(value.map(unit.withSymbol) ?? "")")
        case .note: note
        }
        return kind == .note || note.isEmpty ? text : "\(text) · \(note)"
    }
}

extension MealSlot {
    var title: String {
        switch self {
        case .breakfast: String(localized: "Desayuno")
        case .lunch: String(localized: "Almuerzo")
        case .snack: String(localized: "Merienda")
        case .dinner: String(localized: "Cena")
        }
    }
}

/// "55 min" o "2 h 10 min".
private func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return String(localized: "\(minutes) min") }
    return minutes % 60 == 0
        ? String(localized: "\(minutes / 60) h")
        : String(localized: "\(minutes / 60) h \(minutes % 60) min")
}

/// "+58" / "−12" en la unidad elegida.
private func signed(_ mgdL: Double, _ unit: GlucoseUnit) -> String {
    (mgdL >= 0 ? "+" : "−") + unit.number(abs(mgdL))
}

// MARK: - Pestaña

struct LogbookView: View {
    let store: GlucoseStore
    @State private var days = 14
    @State private var draft: Draft?

    /// Anotación abierta en el formulario (nueva o existente).
    struct Draft: Identifiable {
        var entry: LogEntry
        var isNew: Bool
        var id: UUID { entry.id }
    }

    var body: some View {
        let _ = store.historyRevision
        let period = DateInterval(start: store.now.addingTimeInterval(-Double(days) * 86_400), end: store.now)
        let entries = store.logEntries(in: period)
        // Lecturas un poco antes y hasta 5 h después, para la glucosa al comer y la vuelta al rango.
        let readings = store.storedReadings(in: DateInterval(
            start: period.start.addingTimeInterval(-Logbook.maxDistance),
            end: period.end.addingTimeInterval(Logbook.recoveryWindow)
        ))
        let meals = Logbook.mealResponses(entries, readings: readings, target: store.display.target)
        let fingersticks = Logbook.fingerstickComparisons(entries, readings: readings)

        HStack {
            Picker("Período", selection: $days) {
                ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) días").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button {
                draft = Draft(entry: LogEntry(date: store.now, kind: .carbs), isNew: true)
            } label: {
                Label("Anotar", systemImage: "plus")
            }
            .keyboardShortcut("n")
        }
        .sheet(item: $draft) { draft in
            EntrySheet(store: store, entry: draft.entry, isNew: draft.isNew)
        }

        if entries.isEmpty {
            Card {
                ContentUnavailableView(
                    "Sin anotaciones",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Anotá comidas, insulina, ejercicio, pinchazos o notas. Aparecen en el gráfico de Hoy.")
                )
            }
        } else {
            let summaries = MealSummary.compute(meals)
            let meter = FingerstickSummary(fingersticks)
            if !summaries.isEmpty || meter != nil {
                HStack(alignment: .top, spacing: 16) {
                    if !summaries.isEmpty { MealsCard(summaries: summaries, unit: store.display.unit) }
                    if let meter { FingerstickCard(summary: meter, unit: store.display.unit).frame(maxWidth: 320) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            EntriesCard(
                entries: entries,
                meals: Dictionary(meals.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a }),
                fingersticks: Dictionary(fingersticks.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a }),
                readings: readings,
                display: store.display,
                edit: { draft = Draft(entry: $0, isNew: false) },
                delete: store.deleteLogEntry
            )
        }
    }
}

// MARK: - Resúmenes

private struct MealsCard: View {
    let summaries: [MealSummary]
    let unit: GlucoseUnit

    var body: some View {
        Card(title: "Después de comer") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: "")
                    Text("Comidas")
                    Text("Subida")
                    Text("Pico a los")
                    Text("Vuelve al rango")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(summaries, id: \.slot) { summary in
                    GridRow {
                        Text(summary.slot.title).font(.callout.weight(.semibold))
                        Text(verbatim: "\(summary.count)").monospacedDigit()
                        Text(verbatim: "\(signed(summary.averageRise, unit)) \(unit.symbol)").monospacedDigit()
                        Text(duration(summary.averageTimeToPeak)).monospacedDigit()
                        Text(summary.averageTimeToBackInRange.map(duration)
                             ?? (summary.leftRange == 0 ? String(localized: "no salió") : "–"))
                            .monospacedDigit()
                    }
                }
            }
            Text("Promedios desde la glucosa al comer, en las 3 h siguientes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FingerstickCard: View {
    let summary: FingerstickSummary
    let unit: GlucoseUnit

    var body: some View {
        Card(title: "Glucómetro vs sensor") {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(signed(summary.averageDifference, unit)) \(unit.symbol)")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(summary.averageDifference >= 0 ? "El sensor marca más, en promedio" : "El sensor marca menos, en promedio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Diferencia media \(percent(summary.mard)) · \(percent(summary.withinFifteen)) dentro de ±\(percent(0.15))")
                .font(.callout)
            Text("\(summary.count) pinchazos. Ante síntomas o diferencias grandes, guiate por el glucómetro.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Lista

private struct EntriesCard: View {
    let entries: [LogEntry]
    let meals: [UUID: MealResponse]
    let fingersticks: [UUID: FingerstickComparison]
    let readings: [GlucoseMeasurement]
    let display: DisplaySettings
    let edit: (LogEntry) -> Void
    let delete: (LogEntry) -> Void

    var body: some View {
        let calendar = Calendar.current
        let days = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        Card(title: "Anotaciones") {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.callout.weight(.semibold))
                        .padding(.top, 8)
                    ForEach(days[day]!.sorted { $0.date > $1.date }) { entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        Button { edit(entry) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 72, alignment: .trailing)
                Image(systemName: entry.kind.symbol)
                    .foregroundStyle(entry.kind.color)
                    .frame(width: 18)
                Text(entry.summary(unit: display.unit))
                    .lineLimit(2)
                Spacer(minLength: 12)
                detail(entry)
                    .font(.caption)
                    .monospacedDigit()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Editar…") { edit(entry) }
            Button("Eliminar", role: .destructive) { delete(entry) }
        }
    }

    /// Lo que hizo el sensor alrededor de la anotación.
    @ViewBuilder private func detail(_ entry: LogEntry) -> some View {
        let unit = display.unit
        if let meal = meals[entry.id] {
            let back = meal.leftRange
                ? meal.timeToBackInRange.map { String(localized: "vuelve al rango en \(duration($0))") }
                    ?? String(localized: "no volvió al rango en 5 h")
                : String(localized: "sin salir del rango")
            Text("\(signed(meal.rise, unit)) \(unit.symbol) a los \(duration(meal.timeToPeak)) · \(back)")
                .foregroundStyle(.secondary)
        } else if let comparison = fingersticks[entry.id] {
            HStack(spacing: 4) {
                Text("Sensor")
                Text(verbatim: unit.number(comparison.sensor))
                    .foregroundStyle(display.color(for: comparison.sensor))
                Text(verbatim: "(\(comparison.relativeDifference >= 0 ? "+" : "−")\(percent(abs(comparison.relativeDifference))))")
            }
            .foregroundStyle(.secondary)
        } else if let value = Logbook.sensorValue(at: entry.date, readings: readings) {
            HStack(spacing: 4) {
                Text("Sensor")
                Text(verbatim: unit.number(value)).foregroundStyle(display.color(for: value))
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formulario

private struct EntrySheet: View {
    let store: GlucoseStore
    let isNew: Bool
    @State private var entry: LogEntry
    @State private var valueText: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: GlucoseStore, entry: LogEntry, isNew: Bool) {
        self.store = store
        self.isNew = isNew
        _entry = State(initialValue: entry)
        let shown = entry.kind == .fingerstick ? entry.value.map(store.display.unit.convert) : entry.value
        _valueText = State(initialValue: shown?.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) ?? "")
    }

    /// El valor en la unidad que se guarda (mg/dL para el glucómetro).
    private var value: Double? {
        let text = valueText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(text) else { return nil }
        return entry.kind == .fingerstick && store.display.unit == .mmolL ? number * GlucoseUnit.mmolFactor : number
    }

    private var result: LogEntry {
        var result = entry
        result.value = entry.kind.valueRange == nil ? nil : value
        result.note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Nueva anotación" : "Editar anotación").font(.headline)
            Picker("Tipo", selection: $entry.kind) {
                ForEach(LogKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                DatePicker("Fecha y hora", selection: $entry.date, in: ...store.now.addingTimeInterval(3600))
                if entry.kind.valueRange != nil {
                    HStack {
                        TextField("Cantidad", text: $valueText)
                            .frame(width: 80)
                        Text(entry.kind.unitLabel(store.display.unit)).foregroundStyle(.secondary)
                    }
                }
                TextField(entry.kind == .note ? "Nota" : "Nota (opcional)", text: $entry.note, axis: .vertical)
                    .lineLimit(1...4)
            }
            .textFieldStyle(.roundedBorder)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }

            HStack {
                if !isNew {
                    Button("Eliminar", role: .destructive) {
                        store.deleteLogEntry(entry)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!result.isValid)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        do {
            try store.saveLogEntry(result)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
