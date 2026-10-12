import Charts
import LibreKit
import SwiftUI

// Estilo compartido entre el panel de la barra de menú y la ventana:
// verde en rango, naranja por encima, rojo por debajo, gris si la lectura no sirve.

extension GlucoseZone {
    var color: Color {
        switch self {
        case .below: .red
        case .inTarget: .green
        case .above: .orange
        }
    }

    var label: String {
        switch self {
        case .below: "Por debajo"
        case .inTarget: "En rango"
        case .above: "Por encima"
        }
    }
}

extension DisplaySettings {
    func color(for mgdL: Double) -> Color { zone(mgdL).color }
}

/// Tarjeta de la ventana: fondo de control con borde sutil.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Gráfico de lecturas con el rango objetivo sombreado y los umbrales de alarma.
/// Se dibuja en mg/dL; los rótulos del eje van en la unidad elegida.
struct GlucoseChart: View {
    let points: [GlucoseMeasurement]
    let display: DisplaySettings
    let settings: AlarmSettings
    /// Intervalo del eje X; `nil` = el de los datos.
    var domain: ClosedRange<Date>?
    var hourStride = 3
    /// Con el puntero encima muestra el valor y la hora.
    var interactive = false

    @State private var hovered: Date?

    private var maxValue: Double { min(400, max(250, (points.map(\.mgdL).max() ?? 0) + 20)) }

    /// Tramos sin huecos > 15 min, para no unir con una línea las horas sin datos.
    private var segments: [(id: Int, point: GlucoseMeasurement)] {
        var segment = 0
        var previous: Date?
        return points.map { point in
            if let previous, point.date.timeIntervalSince(previous) > 15 * 60 { segment += 1 }
            previous = point.date
            return (segment, point)
        }
    }

    private var hoveredPoint: GlucoseMeasurement? {
        guard let hovered else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered)) }
    }

    var body: some View {
        let maxValue = maxValue
        let symbolSize: CGFloat = points.count > 400 ? 5 : 12
        Chart {
            RectangleMark(
                xStart: nil, xEnd: nil,
                yStart: .value("Bajo", display.targetLow),
                yEnd: .value("Alto", display.targetHigh)
            )
            .foregroundStyle(.green.opacity(0.12))

            if settings.lowEnabled {
                RuleMark(y: .value("Umbral bajo", settings.lowThreshold))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if settings.highEnabled, settings.highThreshold <= maxValue {
                RuleMark(y: .value("Umbral alto", settings.highThreshold))
                    .foregroundStyle(.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            ForEach(segments, id: \.point.date) { item in
                LineMark(
                    x: .value("Hora", item.point.date),
                    y: .value("Glucosa", min(item.point.mgdL, maxValue)),
                    series: .value("Tramo", item.id)
                )
                .foregroundStyle(.secondary)
                .interpolationMethod(.monotone)
                PointMark(x: .value("Hora", item.point.date), y: .value("Glucosa", min(item.point.mgdL, maxValue)))
                    .symbolSize(symbolSize)
                    .foregroundStyle(display.color(for: item.point.mgdL))
            }

            if interactive, let point = hoveredPoint {
                RuleMark(x: .value("Hora", point.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text("\(display.unit.reading(point.mgdL)) \(display.unit.symbol)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(display.color(for: point.mgdL))
                            Text(point.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                PointMark(x: .value("Hora", point.date), y: .value("Glucosa", min(point.mgdL, maxValue)))
                    .symbolSize(60)
                    .foregroundStyle(display.color(for: point.mgdL))
            }
        }
        .chartYScale(domain: 40...maxValue)
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks(maxValue)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let mgdL = value.as(Double.self) { Text(display.unit.number(mgdL)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hourStride)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .modifier(XDomain(domain: domain))
        .chartXSelection(value: interactive ? $hovered : .constant(nil))
    }

    private func yTicks(_ maxValue: Double) -> [Double] {
        Array(Set([display.targetLow, display.targetHigh, 250, 350].filter { $0 <= maxValue })).sorted()
    }
}

private struct XDomain: ViewModifier {
    let domain: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let domain { content.chartXScale(domain: domain) } else { content }
    }
}

/// Lista de problemas activos con su explicación.
struct ProblemsView: View {
    let conditions: [GlucoseCondition]

    var body: some View {
        if !conditions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(conditions, id: \.self) { condition in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: condition.symbolName)
                            .foregroundStyle(condition.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(condition.title).font(.callout.weight(.semibold))
                            Text(condition.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(conditions[0].tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension GlucoseCondition {
    var tint: Color {
        switch self {
        case .urgentLow, .low: .red
        case .high: .orange
        default: severity >= .warning ? .orange : .secondary
        }
    }
}
