import Foundation

/// Situación que simula el servidor de demostración.
public enum DemoScenario: String, CaseIterable, Sendable, Identifiable {
    /// Recorre los demás escenarios solo, cambiando cada `tourStep`.
    case tour
    case normal
    case high
    case low
    case urgentLow
    case belowRange
    case aboveRange
    case stale
    case signalLoss
    case connectionError
    case mustAcceptTerms
    case noPatients
    case sensorEnding

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tour: "Recorrido automático"
        case .normal: "Día normal"
        case .high: "Alta (≈ 265)"
        case .low: "Baja (≈ 64)"
        case .urgentLow: "Muy baja (≈ 48)"
        case .belowRange: "LO (< 40)"
        case .aboveRange: "HI (> 500)"
        case .stale: "Lectura vieja (13 min)"
        case .signalLoss: "Sin señal (28 min)"
        case .connectionError: "Sin conexión (HTTP 503)"
        case .mustAcceptTerms: "Hay que aceptar términos"
        case .noPatients: "Sin pacientes que seguir"
        case .sensorEnding: "Sensor por terminar"
        }
    }

    static let tourSteps: [DemoScenario] = [
        .normal, .high, .normal, .low, .urgentLow, .normal, .stale, .signalLoss, .connectionError, .sensorEnding,
    ]
    /// Duración de cada paso del recorrido.
    public static let tourStep: TimeInterval = 60

    /// Escenario que rige en `now` (resuelve el recorrido).
    public func resolved(at now: Date) -> DemoScenario {
        guard self == .tour else { return self }
        let index = Int(now.timeIntervalSince1970 / Self.tourStep) % Self.tourSteps.count
        return Self.tourSteps[index]
    }
}

/// Servidor de LibreLinkUp falso, para probar la app sin cuenta. Intercepta las
/// peticiones HTTP del cliente real (`URLProtocol`), así que el login con redirección,
/// los headers y la decodificación son los mismos que contra la API de verdad.
/// Los datos son inventados: una curva de un día típico que se acerca al valor del escenario.
public enum DemoServer {
    public static let email = "demo@librebar.local"
    public static let password = "demo"
    /// Región a la que redirige el primer login (como una cuenta argentina).
    static let homeRegion = "la"

    public static var scenario: DemoScenario {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    private static let state = Locked<DemoScenario>(.tour)

    /// Sesión cuyas peticiones contesta el servidor falso.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    public static func makeClient() -> LibreLinkUpClient {
        LibreLinkUpClient(email: email, password: password, region: .global, session: session)
    }

    // MARK: Respuestas

    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body: Any = [String: Any]()
    }

    static func respond(to request: URLRequest, now: Date = Date()) -> Response {
        let scenario = scenario.resolved(at: now)
        let host = request.url?.host() ?? ""
        let path = request.url?.path() ?? ""

        if path == "/llu/auth/login" {
            guard host == "api-\(homeRegion).libreview.io" else {
                return Response(body: ["status": 0, "data": ["redirect": true, "region": homeRegion]])
            }
            if scenario == .mustAcceptTerms {
                return Response(body: ["status": 4, "data": ["step": ["type": "tou", "componentName": "AcceptDocument"]]])
            }
            return Response(body: ["status": 0, "data": [
                "user": ["id": "demo-user", "firstName": "Demo"],
                "authTicket": ["token": "demo-token", "expires": now.timeIntervalSince1970 + 3600, "duration": 3_600_000],
            ]])
        }

        if scenario == .connectionError { return Response(status: 503) }
        if scenario == .mustAcceptTerms { return Response(status: 401) }

        if path == "/llu/connections" {
            let list: [[String: Any]] = scenario == .noPatients ? [] : patients.map {
                ["id": "c-\($0.id)", "patientId": $0.id, "firstName": $0.firstName, "lastName": $0.lastName]
            }
            return Response(body: ["status": 0, "data": list])
        }

        if path.hasPrefix("/llu/connections/"), path.hasSuffix("/graph") {
            let patientID = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            let patient = patients.first { $0.id == patientID } ?? patients[0]
            return Response(body: graph(for: patient, scenario: scenario, now: now))
        }

        return Response(status: 404)
    }

    // MARK: Datos inventados

    struct DemoPatient {
        let id: String
        let firstName: String
        let lastName: String
        /// Desfasa la curva para que cada paciente se vea distinto.
        let phaseHours: Double
        /// El segundo paciente siempre está en un día normal.
        let followsScenario: Bool
    }

    static let patients = [
        DemoPatient(id: "demo-1", firstName: "Paciente", lastName: "Demo", phaseHours: 0, followsScenario: true),
        DemoPatient(id: "demo-2", firstName: "Familiar", lastName: "Demo", phaseHours: 2.5, followsScenario: false),
    ]

    private static func graph(for patient: DemoPatient, scenario: DemoScenario, now: Date) -> [String: Any] {
        let scenario = patient.followsScenario ? scenario : .normal
        let curve = Curve(scenario: scenario, phaseHours: patient.phaseHours, now: now)

        // Historial cada 5 min (alineado al reloj) durante ~12 h hasta la última lectura.
        let step: TimeInterval = 5 * 60
        let last = curve.lastReading
        var history: [[String: Any]] = []
        var t = (last.timeIntervalSince1970 / step).rounded(.down) * step
        while t > last.timeIntervalSince1970 - 12 * 3600 {
            let date = Date(timeIntervalSince1970: t)
            history.append(measurement(curve.value(at: date), at: date, trend: nil))
            t -= step
        }

        let activationAgo: TimeInterval = scenario == .sensorEnding
            ? GlucoseStatus.sensorLifetime - 9 * 3600
            : 6 * 86_400 + 7 * 3600
        return ["status": 0, "data": [
            "connection": [
                "patientId": patient.id,
                "glucoseMeasurement": measurement(curve.value(at: last), at: last, trend: curve.trend),
                "sensor": ["sn": "3MH0DEMO\(patient.id.suffix(1))", "a": (now.timeIntervalSince1970 - activationAgo).rounded(), "pt": 4],
            ],
            "graphData": Array(history.reversed()),
        ]]
    }

    private static func measurement(_ mgdL: Double, at date: Date, trend: Trend?) -> [String: Any] {
        let value = mgdL.rounded()
        var result: [String: Any] = [
            "FactoryTimestamp": LibreTimestamp.formatUTC(date),
            "ValueInMgPerDl": value,
            "isHigh": value > 500,
            "isLow": value < 40,
        ]
        if let trend { result["TrendArrow"] = trend.rawValue }
        return result
    }
}

/// Curva de glucosa de un día típico (comidas a las 8, 13:30 y 21 h) que, en los
/// últimos ~100 min, converge al valor y la pendiente del escenario.
struct Curve {
    let scenario: DemoScenario
    let phaseHours: Double
    let now: Date

    /// Momento de la última lectura que "subió" el teléfono.
    var lastReading: Date {
        let minute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        let delay: TimeInterval = switch scenario {
        case .stale: 13 * 60
        case .signalLoss: 28 * 60
        default: 0
        }
        return Date(timeIntervalSince1970: minute - delay)
    }

    /// Valor final y pendiente (mg/dL por minuto) del escenario; `nil` = curva natural.
    private var target: (value: Double, slope: Double)? {
        switch scenario {
        case .high: (265, 1.2)
        case .low: (64, -1.1)
        case .urgentLow: (48, -2.2)
        case .belowRange: (36, -0.4)
        case .aboveRange: (520, 1.0)
        default: nil
        }
    }

    var trend: Trend {
        let slope = target?.slope ?? (value(at: lastReading) - value(at: lastReading.addingTimeInterval(-15 * 60))) / 15
        switch slope {
        case ..<(-2): return .fallingQuickly
        case ..<(-1): return .falling
        case ...1: return .stable
        case ...2: return .rising
        default: return .risingQuickly
        }
    }

    func value(at date: Date) -> Double {
        let natural = Self.typicalDay(date, phaseHours: phaseHours)
        guard let target else { return natural }
        let window: TimeInterval = 100 * 60
        let end = lastReading
        let x = 1 - end.timeIntervalSince(date) / window
        guard x > 0 else { return natural }
        let w = x * x * (3 - 2 * x)
        let line = target.value + target.slope * date.timeIntervalSince(end) / 60
        return natural * (1 - w) + line * w
    }

    /// Hora local con picos posprandiales y un poco de ruido determinista.
    static func typicalDay(_ date: Date, phaseHours: Double) -> Double {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let hour = date.timeIntervalSince(start) / 3600 + phaseHours
        func meal(at mealHour: Double, rise: Double) -> Double {
            // Pico ~55 min después de comer; cuenta también la comida del día anterior.
            [mealHour, mealHour - 24, mealHour + 24].reduce(0) { sum, h in
                let x = (hour - h) / 0.9
                return x > 0 ? sum + rise * x * exp(1 - x) : sum
            }
        }
        let t = date.timeIntervalSince1970 / 60
        let noise = 4 * sin(t / 7.3) + 3 * sin(t / 2.9 + 1.7) + 2 * sin(t / 17.1 + 0.4)
        let night = -12 * exp(-pow((hour.truncatingRemainder(dividingBy: 24) - 3.5) / 1.5, 2))
        return 102 + meal(at: 8, rise: 62) + meal(at: 13.5, rise: 78) + meal(at: 21, rise: 70) + night + noise
    }
}

/// Contesta las peticiones de `DemoServer.session`.
final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = DemoServer.respond(to: request)
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let body = JSONSerialization.isValidJSONObject(reply.body)
            ? (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data("{}".utf8)
            : Data("{}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Valor protegido por un lock (macOS 14 no tiene `Mutex`).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
