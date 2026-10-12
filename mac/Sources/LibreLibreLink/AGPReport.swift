import AppKit
import Charts
import LibreKit
import SwiftUI

/// Informe AGP (perfil ambulatorio de glucosa) de una página A4, para llevar al médico:
/// estadísticas, tiempo en los 5 rangos del consenso, patrón diario (percentiles 5–95) y
/// los perfiles de los últimos 14 días.
struct AGPReport {
    let patient: String?
    let period: DateInterval
    let readings: [GlucoseMeasurement]
    let stats: GlucoseStatistics
    let display: DisplaySettings

    static let pageSize = CGSize(width: 595, height: 842)

    /// El PDF, con el texto como texto (no imagen).
    @MainActor func pdf() -> Data {
        let renderer = ImageRenderer(content: AGPPage(report: self))
        renderer.proposedSize = ProposedViewSize(Self.pageSize)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// "Informe glucosa 2026-09-28 a 2026-10-12.pdf"
    var fileName: String {
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        return String(localized: "Informe glucosa \(period.start.formatted(day)) a \(period.end.formatted(day)).pdf")
    }

    /// Últimos días (hasta 14) para los perfiles diarios, del más viejo al más nuevo.
    var profileDays: [Date] {
        let calendar = Calendar.current
        let last = calendar.startOfDay(for: period.end)
        let count = min(14, Int((period.duration / 86_400).rounded()))
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }
    }
}

extension GlucoseBand {
    var color: Color {
        switch self {
        case .veryLow: .red.mix(with: .black, by: 0.35)
        case .low: .red
        case .target: .green
        case .high: .orange
        case .veryHigh: .orange.mix(with: .black, by: 0.3)
        }
    }

    var label: String {
        switch self {
        case .veryLow: String(localized: "Muy bajo")
        case .low: String(localized: "Bajo")
        case .target: String(localized: "En rango")
        case .high: String(localized: "Alto")
        case .veryHigh: String(localized: "Muy alto")
        }
    }

    func range(_ unit: GlucoseUnit) -> String {
        switch self {
        case .veryLow: "< \(unit.withSymbol(54))"
        case .low: "\(unit.number(54))–\(unit.withSymbol(69))"
        case .target: "\(unit.number(70))–\(unit.withSymbol(180))"
        // 181 mg/dL redondea a 10,0 mmol/L; el consenso usa 10,1.
        case .high: "\(unit.number(unit == .mgdL ? 181 : 182))–\(unit.withSymbol(250))"
        case .veryHigh: "> \(unit.withSymbol(250))"
        }
    }

    /// Meta del consenso como texto ("< 4 %" para bajo cuenta también el muy bajo).
    var goalText: String {
        let goal = self.goal.formatted(.percent.precision(.fractionLength(0)))
        switch self {
        case .target: return String(localized: "Meta: > \(goal)")
        case .low: return String(localized: "Meta: < \(goal) (con muy bajo)")
        case .high: return String(localized: "Meta: < \(goal) (con muy alto)")
        case .veryLow, .veryHigh: return String(localized: "Meta: < \(goal)")
        }
    }
}

private struct AGPPage: View {
    let report: AGPReport
    private var unit: GlucoseUnit { report.display.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 20) {
                statistics.frame(width: 220, alignment: .leading)
                timeInRanges
            }
            section("Perfil ambulatorio de glucosa (AGP)") {
                AGPChart(pattern: DailyPattern.compute(report.readings), unit: unit)
                    .frame(height: 210)
                legend
            }
            section("Perfiles diarios") { dailyProfiles }
            Spacer(minLength: 0)
            Text("Generado el \(Date().formatted(date: .abbreviated, time: .shortened)) con LibreLibreLink (datos de LibreLinkUp). No es un dispositivo médico; confirmá con el médico antes de cambiar el tratamiento. Rangos y metas: consenso internacional de tiempo en rango (2019).")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: AGPReport.pageSize.width, height: AGPReport.pageSize.height, alignment: .topLeading)
        .background(.white)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Informe de glucosa").font(.system(size: 18, weight: .bold))
                if let patient = report.patient { Text(verbatim: patient).font(.system(size: 11)) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(report.period.start.formatted(date: .abbreviated, time: .omitted)) – \(report.period.end.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(Int((report.period.duration / 86_400).rounded())) días")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(.black).frame(height: 1) }
    }

    private var statistics: some View {
        let stats = report.stats
        return section("Estadísticas") {
            row("Glucosa promedio", unit.withSymbol(stats.mean))
            row("Indicador de manejo de glucosa (GMI)", (stats.gmi / 100).formatted(.percent.precision(.fractionLength(1))))
            row("Variabilidad (CV)", percent(stats.coefficientOfVariation / 100), detail: String(localized: "Meta: ≤ 36 %"))
            row("Tiempo con sensor activo", percent(stats.coverage))
            row("Episodios de baja", "\(stats.lowEvents)", detail: String(localized: "< \(unit.withSymbol(70)) durante 15 min o más"))
        }
    }

    private var timeInRanges: some View {
        section("Tiempo en rangos") {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 1) {
                    ForEach(GlucoseBand.allCases.reversed(), id: \.self) { band in
                        let fraction = report.stats.bandFractions[band] ?? 0
                        if fraction > 0 {
                            Rectangle().fill(band.color).frame(height: max(2, 150 * fraction))
                        }
                    }
                }
                .frame(width: 28, height: 150, alignment: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(GlucoseBand.allCases.reversed(), id: \.self) { band in
                        let fraction = report.stats.bandFractions[band] ?? 0
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: "\(band.label)  \(band.range(unit))").font(.system(size: 9, weight: .medium))
                                Text(verbatim: band.goalText).font(.system(size: 7)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(percent(fraction))
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(band.color)
                            Text(perDay(fraction))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: 66, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Rectangle().fill(.black).frame(width: 12, height: 2), "Mediana")
            swatch(Rectangle().fill(.blue.opacity(0.35)).frame(width: 12, height: 8), "Percentil 25–75")
            swatch(Rectangle().fill(.blue.opacity(0.12)).frame(width: 12, height: 8), "Percentil 5–95")
            swatch(Rectangle().fill(.green.opacity(0.15)).frame(width: 12, height: 8),
                   "Rango \(unit.number(70))–\(unit.withSymbol(180))")
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
    }

    private var dailyProfiles: some View {
        let calendar = Calendar.current
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
            ForEach(report.profileDays, id: \.self) { day in
                let end = calendar.date(byAdding: .day, value: 1, to: day)!
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                    DayProfile(points: report.readings.filter { $0.date >= day && $0.date < end }, day: day...end)
                        .frame(height: 58)
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold)).textCase(.uppercase)
            content()
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 9))
                Spacer()
                Text(verbatim: value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            if let detail { Text(verbatim: detail).font(.system(size: 7)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }

    private func swatch(_ shape: some View, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { shape; Text(text) }
    }

    /// Sin decimales; lo que no llega al 1 % se muestra "< 1 %" para no confundirlo con nada.
    private func percent(_ fraction: Double) -> String {
        fraction > 0 && fraction < 0.005
            ? "< " + 0.01.formatted(.percent.precision(.fractionLength(0)))
            : fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func perDay(_ fraction: Double) -> String {
        let minutes = Int((fraction * 24 * 60).rounded())
        return minutes >= 60
            ? String(localized: "\(minutes / 60) h \(minutes % 60) min/día")
            : String(localized: "\(minutes) min/día")
    }
}

/// Patrón diario con escala fija 0–350 mg/dL, como el AGP estándar.
private struct AGPChart: View {
    let pattern: [DailyPatternPoint]
    let unit: GlucoseUnit

    var body: some View {
        Chart {
            RectangleMark(xStart: nil, xEnd: nil, yStart: .value("Bajo", 70), yEnd: .value("Alto", 180))
                .foregroundStyle(.green.opacity(0.15))
            ForEach(pattern, id: \.minute) { point in
                AreaMark(x: .value("Hora", point.minute), yStart: .value("P5", min(point.p5, 350)),
                         yEnd: .value("P95", min(point.p95, 350)), series: .value("Banda", "5–95"))
                    .foregroundStyle(.blue.opacity(0.12))
                    .interpolationMethod(.monotone)
            }
            ForEach(pattern, id: \.minute) { point in
                AreaMark(x: .value("Hora", point.minute), yStart: .value("P25", min(point.p25, 350)),
                         yEnd: .value("P75", min(point.p75, 350)), series: .value("Banda", "25–75"))
                    .foregroundStyle(.blue.opacity(0.35))
                    .interpolationMethod(.monotone)
            }
            ForEach(pattern, id: \.minute) { point in
                LineMark(x: .value("Hora", point.minute), y: .value("Mediana", min(point.p50, 350)))
                    .foregroundStyle(.black)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...(24 * 60))
        .chartYScale(domain: 0...350)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 24 * 60, by: 180))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minute = value.as(Int.self) { Text(verbatim: "\(minute / 60) h").font(.system(size: 8)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [54, 70, 180, 250, 350]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let mgdL = value.as(Double.self) { Text(unit.number(mgdL)).font(.system(size: 8)) }
                }
            }
        }
        .overlay {
            if pattern.isEmpty {
                Text("Faltan datos").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Curva de un día, sin ejes, con el rango 70–180 sombreado.
private struct DayProfile: View {
    let points: [GlucoseMeasurement]
    let day: ClosedRange<Date>

    var body: some View {
        Chart {
            RectangleMark(xStart: nil, xEnd: nil, yStart: .value("Bajo", 70), yEnd: .value("Alto", 180))
                .foregroundStyle(.green.opacity(0.15))
            ForEach(segments, id: \.point.date) { item in
                LineMark(x: .value("Hora", item.point.date), y: .value("Glucosa", min(item.point.mgdL, 350)),
                         series: .value("Tramo", item.id))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
            }
        }
        .chartXScale(domain: day)
        .chartYScale(domain: 0...350)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .border(.separator, width: 0.5)
    }

    /// Tramos sin huecos > 15 min, para no unir horas sin datos.
    private var segments: [(id: Int, point: GlucoseMeasurement)] {
        var segment = 0
        var previous: Date?
        return points.map { point in
            if let previous, point.date.timeIntervalSince(previous) > 15 * 60 { segment += 1 }
            previous = point.date
            return (segment, point)
        }
    }
}
