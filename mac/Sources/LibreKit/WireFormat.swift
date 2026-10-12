import Foundation

// Formato JSON de la API de LibreLinkUp. Referencia: pylibrelinkup 0.11.1
// (`models/login.py`, `models/connection.py`, `models/data.py`).

struct LoginEnvelope: Decodable {
    let status: Int?
    let data: LoginData?
    let error: APIMessage?
}

struct LoginData: Decodable {
    let redirect: Bool?
    let region: String?
    let step: Step?
    let user: User?
    let authTicket: AuthTicket?

    struct Step: Decodable { let type: String? }
    struct User: Decodable { let id: String }
}

struct AuthTicket: Decodable {
    let token: String
    /// Segundos Unix.
    let expires: TimeInterval?
}

struct APIMessage: Decodable {
    let message: String?
}

struct ConnectionsEnvelope: Decodable {
    let data: [WireConnection]
}

struct WireConnection: Decodable {
    let patientId: String
    let firstName: String?
    let lastName: String?
}

struct GraphEnvelope: Decodable {
    let data: GraphData

    struct GraphData: Decodable {
        let connection: Connection?
        let graphData: [WireMeasurement]?
    }

    struct Connection: Decodable {
        let glucoseMeasurement: WireMeasurement?
        let sensor: WireSensor?
    }

    /// `a` = activación en segundos Unix.
    struct WireSensor: Decodable {
        let sn: String?
        let a: TimeInterval?

        func info() -> SensorInfo? {
            guard let a, a > 0 else { return nil }
            return SensorInfo(serial: sn ?? "", activation: Date(timeIntervalSince1970: a))
        }
    }
}

/// Las mediciones vienen en PascalCase, salvo `isHigh`/`isLow`.
struct WireMeasurement: Decodable {
    let FactoryTimestamp: String
    let ValueInMgPerDl: Double
    let TrendArrow: Int?
    let isHigh: Bool?
    let isLow: Bool?

    func measurement() -> GlucoseMeasurement? {
        guard let date = LibreTimestamp.parseUTC(FactoryTimestamp) else { return nil }
        return GlucoseMeasurement(
            date: date,
            mgdL: ValueInMgPerDl,
            trend: TrendArrow.flatMap(Trend.init(rawValue:)),
            isHigh: isHigh ?? false,
            isLow: isLow ?? false
        )
    }
}

enum LibreTimestamp {
    /// Formato "M/d/yyyy h:mm:ss a", p. ej. "10/12/2026 3:04:05 PM".
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f
    }()

    static func parseUTC(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    static func formatUTC(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
