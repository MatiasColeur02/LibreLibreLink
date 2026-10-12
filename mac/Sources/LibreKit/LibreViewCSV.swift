import Foundation

public enum LibreViewCSVError: Error, LocalizedError, Equatable {
    /// No tiene la cabecera de "Datos de glucosa" de LibreView.
    case notLibreView
    /// Las fechas no tienen un formato conocido.
    case unreadableDates
    case noReadings

    public var errorDescription: String? {
        switch self {
        case .notLibreView: String(localized: "El archivo no es una exportación de glucosa de LibreView.")
        case .unreadableDates: String(localized: "No se entienden las fechas del archivo.")
        case .noReadings: String(localized: "El archivo no tiene lecturas de glucosa.")
        }
    }
}

/// Lector del CSV "Datos de glucosa" que exporta LibreView (libreview.com).
///
/// Formato: una línea de título ("Datos de glucosa,Generado el,…"), la cabecera y una fila por
/// registro. Las columnas van siempre en el mismo orden aunque los nombres cambien con el idioma:
/// 0 dispositivo, 1 número de serie, 2 fecha y hora del dispositivo (hora local), 3 tipo de
/// registro, 4 glucosa histórica, 5 glucosa escaneada. Tipo 0 = histórica (cada 15 min),
/// 1 = escaneo; el resto (notas, tiras, cetonas…) se ignora. La unidad sale de la cabecera.
public enum LibreViewCSV {
    public struct Result: Sendable, Equatable {
        /// Ordenadas por fecha, sin tendencia.
        public let readings: [GlucoseMeasurement]
        public var interval: DateInterval? {
            guard let first = readings.first, let last = readings.last else { return nil }
            return DateInterval(start: first.date, end: last.date)
        }
    }

    public static func parse(_ text: String, timeZone: TimeZone = .current) throws -> Result {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0].removeFirst() }

        // La cabecera es la primera fila cuya columna 4 menciona la unidad.
        let delimiter: Character = lines.prefix(3).joined().filter { $0 == ";" }.count
            > lines.prefix(3).joined().filter { $0 == "," }.count ? ";" : ","
        guard let headerIndex = lines.prefix(5).firstIndex(where: { line in
            let fields = split(line, delimiter: delimiter)
            return fields.count > 5 && unitFactor(fields[4]) != nil
        }) else { throw LibreViewCSVError.notLibreView }
        let factor = unitFactor(split(lines[headerIndex], delimiter: delimiter)[4])!

        var rows: [(time: String, value: Double)] = []
        for line in lines[(headerIndex + 1)...] {
            let fields = split(line, delimiter: delimiter)
            guard fields.count > 5 else { continue }
            let column: Int
            switch fields[3].trimmingCharacters(in: .whitespaces) {
            case "0": column = 4
            case "1": column = 5
            default: continue
            }
            let raw = fields[column].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw), value > 0 else { continue }
            rows.append((fields[2].trimmingCharacters(in: .whitespaces), value * factor))
        }
        guard !rows.isEmpty else { throw LibreViewCSVError.noReadings }

        // Elegir el formato de fecha que entiende más filas (desempata: día antes que mes).
        let times = rows.map { normalize($0.time) }
        let formatters = dateFormats.map { format -> DateFormatter in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter
        }
        var best: (formatter: DateFormatter, count: Int)?
        for formatter in formatters {
            let count = times.reduce(0) { $0 + (formatter.date(from: $1) == nil ? 0 : 1) }
            if count > (best?.count ?? 0) { best = (formatter, count) }
        }
        guard let formatter = best?.formatter else { throw LibreViewCSVError.unreadableDates }

        let readings = zip(times, rows).compactMap { time, row -> GlucoseMeasurement? in
            guard let date = formatter.date(from: time) else { return nil }
            return GlucoseMeasurement(date: date, mgdL: row.value, trend: nil, isHigh: row.value > 500, isLow: row.value < 40)
        }
        guard !readings.isEmpty else { throw LibreViewCSVError.noReadings }
        return Result(readings: readings.sorted { $0.date < $1.date })
    }

    /// mg/dL por unidad del archivo, o `nil` si el texto no es una columna de glucosa.
    private static func unitFactor(_ header: String) -> Double? {
        let lower = header.lowercased()
        if lower.contains("mg/dl") { return 1 }
        if lower.contains("mmol/l") { return 18.0182 }
        return nil
    }

    private static let dateFormats: [String] = {
        let dates = ["dd-MM-yyyy", "MM-dd-yyyy", "yyyy-MM-dd"]
        let times = ["HH:mm", "HH:mm:ss", "hh:mm a", "hh:mm:ss a"]
        return dates.flatMap { date in times.map { "\(date) \($0)" } } + ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
    }()

    /// Unifica separadores de fecha ("/", ".") y marcas "a. m."/"p.m." para probar menos formatos.
    private static func normalize(_ time: String) -> String {
        var text = time.uppercased()
        for (variant, mark) in [("A. M.", "AM"), ("P. M.", "PM"), ("A.M.", "AM"), ("P.M.", "PM")] {
            text = text.replacingOccurrences(of: variant, with: mark)
        }
        guard let space = text.firstIndex(of: " ") else { return text }
        let date = text[..<space].replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return date + text[space...]
    }

    /// Separa una fila respetando comillas (las notas pueden tener comas).
    private static func split(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if quoted, let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else {
                        quoted = false
                        if next == delimiter { fields.append(field); field = "" } else { field.append(next) }
                    }
                } else {
                    quoted.toggle()
                }
            } else if character == delimiter, !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
        }
        fields.append(field)
        return fields
    }
}
