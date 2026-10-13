import Charts
import LibreKit
import SwiftUI
import WidgetKit

// Widgets de escritorio y del Centro de notificaciones. Leen el resumen que escribe la app
// (`GlucoseSnapshot`); la app los recarga con cada lectura nueva. macOS limita cuántas veces
// se redibujan, así que la antigüedad se muestra con un texto que avanza solo.

@main
struct GlucoseWidgets: WidgetBundle {
    var body: some Widget {
        CurrentGlucoseWidget()
        GlucoseChartWidget()
        DailySummaryWidget()
    }
}

struct CurrentGlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "current", provider: SnapshotProvider()) { entry in
            CurrentView(entry: entry).widgetContainer(entry)
        }
        .configurationDisplayName("Glucosa actual")
        .description("Valor, tendencia y hace cuánto llegó la lectura.")
        .supportedFamilies([.systemSmall])
    }
}

struct GlucoseChartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "chart", provider: SnapshotProvider()) { entry in
            ChartView(entry: entry).widgetContainer(entry)
        }
        .configurationDisplayName("Glucosa y gráfico")
        .description("Valor actual y las últimas 3 horas.")
        .supportedFamilies([.systemMedium])
    }
}

struct DailySummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "summary", provider: SnapshotProvider()) { entry in
            SummaryView(entry: entry).widgetContainer(entry)
        }
        .configurationDisplayName("Resumen del día")
        .description("Valor, gráfico de 12 horas, tiempo en rango y promedio de hoy, y el sensor.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Datos

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot?

    var reading: GlucoseMeasurement? { snapshot?.freshReading(at: date) }
    var unit: GlucoseUnit { snapshot?.display.unit ?? .mgdL }
    var hidden: Bool { snapshot?.discreet ?? false }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .preview : GlucoseSnapshot.load()))
    }

    /// Una entrada ahora y otras cuando la lectura pasa a vieja (10 min) y sin señal (20 min),
    /// por si la app no llega a recargar el widget.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = GlucoseSnapshot.load()
        var dates = [Date.now]
        if let current = snapshot?.current {
            dates += [GlucoseStatus.staleAfter, GlucoseStatus.signalLossAfter]
                .map { current.date.addingTimeInterval($0) }
                .filter { $0 > .now }
        }
        completion(Timeline(entries: dates.map { SnapshotEntry(date: $0, snapshot: snapshot) }, policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

extension GlucoseSnapshot {
    /// Datos de ejemplo para la galería de widgets.
    static var preview: GlucoseSnapshot {
        let now = Date.now
        let readings = stride(from: 12 * 60.0, through: 0, by: -5).map { minutes in
            GlucoseMeasurement(date: now.addingTimeInterval(-minutes * 60), mgdL: 130 + 40 * sin(minutes / 90), trend: nil)
        }
        let current = GlucoseMeasurement(date: now.addingTimeInterval(-120), mgdL: readings.last!.mgdL, trend: .rising)
        return GlucoseSnapshot(
            updatedAt: now, signedIn: true, current: current, readings: readings,
            today: .init(inRange: 0.78, below: 0.03, above: 0.19, mean: 142, lowEvents: 1),
            sensorEnd: now.addingTimeInterval(9 * 86_400)
        )
    }
}

// MARK: - Vistas

private extension View {
    /// Fondo del widget y, al tocarlo, abrir la ventana en "Hoy".
    func widgetContainer(_ entry: SnapshotEntry) -> some View {
        containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(AppCommand.open(.today).url)
    }
}

private extension GlucoseZone {
    var color: Color {
        switch self {
        case .below: .red
        case .inTarget: .green
        case .above: .orange
        }
    }
}

private extension GlucoseSnapshot.Tint {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .secondary: .secondary
        }
    }
}

/// Valor grande con flecha, o lo que impide mostrarlo.
private struct ValueView: View {
    let entry: SnapshotEntry
    var size: CGFloat = 44

    var body: some View {
        if entry.snapshot?.signedIn != true {
            Label("Iniciá sesión en LibreLibreLink", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if entry.hidden {
            VStack(alignment: .leading, spacing: 2) {
                Text("•••").font(.system(size: size, weight: .semibold, design: .rounded))
                Label("Modo discreto", systemImage: "eye.slash").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let reading = entry.reading, let display = entry.snapshot?.display {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(entry.unit.reading(reading.mgdL))
                        .font(.system(size: size, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(display.zone(reading.mgdL).color)
                        .minimumScaleFactor(0.6)
                    Text(reading.trend?.arrow ?? "")
                        .font(.system(size: size * 0.6, weight: .semibold))
                }
                HStack(spacing: 4) {
                    Text(entry.unit.symbol)
                    Text("·")
                    Text(reading.date, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("––").font(.system(size: size, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Text("Sin lecturas recientes").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// El problema más grave, si hay (también en modo discreto, como en la barra).
private struct ProblemLine: View {
    let entry: SnapshotEntry

    var body: some View {
        if let problem = entry.snapshot?.problem, entry.snapshot?.signedIn == true {
            Label(problem.title, systemImage: problem.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(problem.tint.color)
                .lineLimit(1)
        }
    }
}

private struct Header: View {
    let entry: SnapshotEntry

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "drop.fill").foregroundStyle(Color(red: 0.54, green: 0.07, blue: 0.39))
            Text(entry.snapshot?.patientName ?? "LibreLibreLink").lineLimit(1)
            if entry.snapshot?.isDemo == true {
                Text("Demo").padding(.horizontal, 4).background(.purple.opacity(0.2), in: Capsule())
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct CurrentView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(entry: entry)
            Spacer(minLength: 0)
            ValueView(entry: entry)
            Spacer(minLength: 0)
            ProblemLine(entry: entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChartView: View {
    let entry: SnapshotEntry

    var body: some View {
        HStack(spacing: 12) {
            CurrentView(entry: entry).frame(width: 130)
            MiniChart(entry: entry, hours: 3)
        }
    }
}

private struct SummaryView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Header(entry: entry)
                    ValueView(entry: entry, size: 52)
                }
                Spacer()
                ProblemLine(entry: entry)
            }
            MiniChart(entry: entry, hours: 12)
            if let today = entry.snapshot?.today, !entry.hidden {
                HStack {
                    Stat(title: "En rango hoy", value: today.inRange.formatted(.percent.precision(.fractionLength(0))), color: .green)
                    Stat(title: "Promedio", value: entry.unit.number(today.mean), color: .primary)
                    Stat(title: "Bajas", value: "\(today.lowEvents)", color: today.lowEvents > 0 ? .red : .primary)
                }
            }
            if let end = entry.snapshot?.sensorEnd {
                Label {
                    if end > entry.date {
                        Text("Sensor: termina \(end, style: .relative)")
                    } else {
                        Text("Sensor terminado")
                    }
                } icon: {
                    Image(systemName: "sensor")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Stat: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gráfico de las últimas horas con el rango objetivo sombreado.
private struct MiniChart: View {
    let entry: SnapshotEntry
    let hours: Double

    var body: some View {
        let start = entry.date.addingTimeInterval(-hours * 3600)
        let points = (entry.snapshot?.readings ?? []).filter { $0.date >= start }
        if entry.hidden || points.isEmpty || entry.snapshot?.signedIn != true {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
        } else if let display = entry.snapshot?.display {
            let top = max(250, (points.map(\.mgdL).max() ?? 0) + 20)
            Chart {
                RectangleMark(xStart: nil, xEnd: nil, yStart: .value("Bajo", display.targetLow), yEnd: .value("Alto", display.targetHigh))
                    .foregroundStyle(.green.opacity(0.15))
                ForEach(points, id: \.date) { point in
                    LineMark(x: .value("Hora", point.date), y: .value("Glucosa", min(point.mgdL, top)))
                        .foregroundStyle(.secondary)
                        .interpolationMethod(.monotone)
                }
                if let last = points.last {
                    PointMark(x: .value("Hora", last.date), y: .value("Glucosa", min(last.mgdL, top)))
                        .foregroundStyle(display.zone(last.mgdL).color)
                }
            }
            .chartXScale(domain: start...entry.date)
            .chartYScale(domain: 40...top)
            .chartYAxis {
                AxisMarks(values: [display.targetLow, display.targetHigh]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(value.as(Double.self).map(entry.unit.number) ?? "") }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hours > 6 ? 3 : 1)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
        }
    }
}
