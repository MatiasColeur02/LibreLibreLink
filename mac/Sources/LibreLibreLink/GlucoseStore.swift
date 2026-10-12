import Foundation
import LibreKit
import Observation

/// Estado de la app: credenciales, paciente elegido, última lectura, problemas
/// activos y alarmas. Consulta LibreLinkUp cada `pollInterval` mientras hay sesión.
@MainActor
@Observable
final class GlucoseStore {
    enum Phase: Equatable {
        case needsLogin
        case loading
        case ready
    }

    static let pollInterval: TimeInterval = 60
    /// En demo se consulta más seguido para que el recorrido automático se vea rápido.
    static let demoPollInterval: TimeInterval = 15
    /// Cada cuánto se reevalúan la antigüedad de la lectura y las alarmas.
    static let clockInterval: TimeInterval = 30

    private(set) var phase: Phase = .needsLogin
    private(set) var patients: [Patient] = []
    private(set) var current: GlucoseMeasurement?
    private(set) var history: [GlucoseMeasurement] = []
    private(set) var sensor: SensorInfo?
    private(set) var lastRefresh: Date?
    /// Error del último intento de inicio de sesión (se muestra en el formulario).
    private(set) var loginError: String?
    /// La red o la API fallaron en la última consulta.
    private(set) var connectionError: String?
    /// Algo que el usuario tiene que resolver en LibreLinkUp.
    private(set) var needsAttention: String?
    /// Reloj observable para que la antigüedad de la lectura se recalcule sola.
    private(set) var now = Date()
    /// Datos inventados por `DemoServer` en lugar de la cuenta real.
    private(set) var isDemo = false

    let notifier = AlarmNotifier()

    var settings: AlarmSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Keys.settings)
            }
            evaluateAlarms()
        }
    }

    /// Unidad y rango objetivo (solo visualización; no cambia las alarmas).
    var display: DisplaySettings {
        didSet {
            guard display != oldValue else { return }
            if let data = try? JSONEncoder().encode(display) {
                UserDefaults.standard.set(data, forKey: Keys.display)
            }
        }
    }

    /// Cambia cada vez que se agregan lecturas al historial (para recalcular informes).
    private(set) var historyRevision = 0
    /// Error al abrir o escribir el historial persistente.
    private(set) var historyError: String?

    var selectedPatientID: String? {
        didSet {
            if !isDemo { UserDefaults.standard.set(selectedPatientID, forKey: Keys.patient) }
            if oldValue != selectedPatientID, !suppressRefresh {
                current = nil
                history = []
                sensor = nil
                refreshNow()
            }
        }
    }

    @ObservationIgnored private var client: LibreLinkUpClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var alarmEngine = AlarmEngine()
    /// Avisos del sensor ya mostrados, por paciente. Se guardan (salvo en demo) para no repetirlos al reiniciar.
    @ObservationIgnored private var sensorNotices: [String: SensorNoticeEngine] = [:]
    @ObservationIgnored private var suppressRefresh = false
    @ObservationIgnored private var database: HistoryDatabase?

    private enum Keys {
        static let patient = "selectedPatientID"
        static let region = "region"
        static let settings = "alarmSettings"
        static let display = "displaySettings"
        static let sensorNotices = "sensorNotices"
    }

    init() {
        settings = UserDefaults.standard.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(AlarmSettings.self, from: $0) } ?? AlarmSettings()
        display = UserDefaults.standard.data(forKey: Keys.display)
            .flatMap { try? JSONDecoder().decode(DisplaySettings.self, from: $0) } ?? DisplaySettings()
        selectedPatientID = UserDefaults.standard.string(forKey: Keys.patient)
        sensorNotices = Self.savedSensorNotices()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") || ProcessInfo.processInfo.environment["LIBREBAR_DEMO"] != nil {
            startDemo()
        } else {
            openHistory(demo: false)
            if let credentials = Keychain.load() {
                start(with: makeClient(credentials))
            }
        }
        startClock()
    }

    // MARK: Historial

    /// Lecturas guardadas del paciente elegido.
    func storedReadings(in interval: DateInterval) -> [GlucoseMeasurement] {
        guard let database, let patient = selectedPatientID else { return [] }
        return (try? database.readings(patientID: patient, in: interval)) ?? []
    }

    /// Desde cuándo hay historial del paciente elegido.
    var historyStart: Date? {
        _ = historyRevision
        guard let database, let patient = selectedPatientID else { return nil }
        return try? database.earliest(patientID: patient)
    }

    /// Agrega al paciente elegido las lecturas de un CSV de LibreView, sin tocar las que ya hay.
    /// - Returns: lecturas nuevas y el período que cubre el archivo.
    func importLibreView(from url: URL) throws -> (added: Int, interval: DateInterval?) {
        guard let database, let patient = selectedPatientID else { throw LibreViewCSVError.noReadings }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
        let result = try LibreViewCSV.parse(text)
        let added = try database.insert(result.readings, patientID: patient, replacingExisting: false)
        historyRevision += 1
        return (added, result.interval)
    }

    /// El demo usa una base en memoria con 14 días inventados; nunca toca el archivo real.
    private func openHistory(demo: Bool) {
        do {
            let database = try HistoryDatabase(url: demo ? nil : HistoryDatabase.defaultURL)
            if demo {
                for patient in ["demo-1", "demo-2"] {
                    try database.insert(DemoServer.backfill(patientID: patient, days: 14), patientID: patient)
                }
            }
            self.database = database
            historyError = nil
        } catch {
            database = nil
            historyError = error.localizedDescription
        }
        historyRevision += 1
    }

    private func record(_ graph: GraphResult, patientID: String) {
        guard let database else { return }
        do {
            try database.insert(graph.history + (graph.current.map { [$0] } ?? []), patientID: patientID)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
        historyRevision += 1
    }

    private var pollInterval: TimeInterval { isDemo ? Self.demoPollInterval : Self.pollInterval }

    // MARK: Estado

    /// Problemas activos, del más grave al más leve.
    var conditions: [GlucoseCondition] {
        if phase == .needsLogin {
            return [.needsAttention(needsAttention ?? String(localized: "Iniciá sesión con tu cuenta de LibreLinkUp."))]
        }
        return GlucoseStatus.conditions(
            current: current,
            sensor: sensor,
            settings: settings,
            fetched: lastRefresh != nil,
            connectionError: connectionError,
            needsAttention: needsAttention,
            now: now
        )
    }

    /// Lectura actual si todavía sirve (no hay pérdida de señal).
    var freshReading: GlucoseMeasurement? {
        guard let current, now.timeIntervalSince(current.date) < GlucoseStatus.signalLossAfter else { return nil }
        return current
    }

    // MARK: Sesión

    /// Valida las credenciales contra LibreLinkUp; si andan, las guarda y empieza a consultar.
    func signIn(email: String, password: String) async {
        if isDemo {
            resetSession()
            isDemo = false
            notifier.isDemo = false
            openHistory(demo: false)
        }
        loginError = nil
        phase = .loading
        let credentials = Credentials(email: email.trimmingCharacters(in: .whitespaces), password: password)
        let client = makeClient(credentials)
        do {
            try await client.login()
            Keychain.save(credentials)
            needsAttention = nil
            start(with: client)
        } catch {
            phase = .needsLogin
            loginError = error.localizedDescription
        }
    }

    func signOut() {
        if isDemo { stopDemo(); return }
        resetSession()
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: Keys.region)
    }

    // MARK: Demo

    /// Escenario del servidor falso; cambiarlo vuelve a consultar enseguida.
    var demoScenario: DemoScenario {
        get { demoScenarioValue }
        set {
            demoScenarioValue = newValue
            DemoServer.scenario = newValue
            if isDemo {
                needsAttention = nil
                loginError = nil
                start(with: client ?? DemoServer.makeClient())
            }
        }
    }

    private var demoScenarioValue = DemoServer.scenario

    /// Prueba la app sin cuenta. No toca el llavero ni las preferencias de la cuenta real.
    func startDemo() {
        resetSession()
        isDemo = true
        notifier.isDemo = true
        sensorNotices = [:]
        openHistory(demo: true)
        withoutRefresh { selectedPatientID = nil }
        start(with: DemoServer.makeClient())
    }

    func stopDemo() {
        resetSession()
        isDemo = false
        notifier.isDemo = false
        sensorNotices = Self.savedSensorNotices()
        openHistory(demo: false)
        withoutRefresh { selectedPatientID = UserDefaults.standard.string(forKey: Keys.patient) }
        if let credentials = Keychain.load() {
            start(with: makeClient(credentials))
        }
    }

    private func resetSession() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        patients = []
        current = nil
        history = []
        sensor = nil
        lastRefresh = nil
        loginError = nil
        connectionError = nil
        needsAttention = nil
        alarmEngine = AlarmEngine()
        phase = .needsLogin
    }

    func refreshNow() {
        guard let client else { return }
        start(with: client)
    }

    // MARK: Consulta

    private func makeClient(_ credentials: Credentials) -> LibreLinkUpClient {
        let region = UserDefaults.standard.string(forKey: Keys.region).flatMap(Region.init(code:)) ?? .global
        return LibreLinkUpClient(email: credentials.email, password: credentials.password, region: region)
    }

    private func start(with client: LibreLinkUpClient) {
        self.client = client
        if current == nil { phase = .loading }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = await self?.refresh(using: client) ?? Self.pollInterval
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.clockInterval))
                guard let self else { return }
                self.now = Date()
                self.evaluateAlarms()
            }
        }
    }

    /// Hace una consulta y devuelve cuánto esperar hasta la próxima.
    private func refresh(using client: LibreLinkUpClient) async -> TimeInterval {
        defer {
            now = Date()
            evaluateAlarms()
        }
        do {
            let patients = try await client.patients()
            if !isDemo { UserDefaults.standard.set(await client.region.code, forKey: Keys.region) }
            guard !Task.isCancelled else { return pollInterval }
            self.patients = patients
            guard let patient = patients.first(where: { $0.id == selectedPatientID }) ?? patients.first else {
                needsAttention = String(localized: "La cuenta LibreLinkUp no sigue a nadie. Aceptá la invitación enviada desde LibreLink.")
                connectionError = nil
                phase = .ready
                return pollInterval
            }
            if selectedPatientID != patient.id {
                withoutRefresh { selectedPatientID = patient.id }
            }
            let graph = try await client.graph(patientID: patient.id)
            guard !Task.isCancelled else { return pollInterval }
            current = graph.current ?? graph.history.last
            history = graph.history
            record(graph, patientID: patient.id)
            sensor = graph.sensor
            lastRefresh = Date()
            connectionError = nil
            needsAttention = nil
            phase = .ready
            return pollInterval
        } catch let error as LibreLinkUpError {
            switch error {
            case .invalidCredentials, .mustAcceptTerms, .mustAcceptPrivacyPolicy, .mustVerifyEmail, .unsupportedLoginStep:
                // Hace falta intervención del usuario: dejar de consultar.
                pollTask?.cancel()
                self.client = nil
                needsAttention = error.localizedDescription
                loginError = error.localizedDescription
                phase = .needsLogin
                return pollInterval
            case .rateLimited(let retryAfter):
                connectionError = error.localizedDescription
                if phase == .loading { phase = .ready }
                return max(retryAfter ?? 300, pollInterval)
            default:
                connectionError = error.localizedDescription
                if phase == .loading { phase = .ready }
                return pollInterval
            }
        } catch {
            if Task.isCancelled { return pollInterval }
            connectionError = error.localizedDescription
            if phase == .loading { phase = .ready }
            return pollInterval
        }
    }

    // MARK: Alarmas

    private func evaluateAlarms() {
        evaluateSensorNotices()
        guard settings.notificationsEnabled, phase != .needsLogin else {
            alarmEngine = AlarmEngine()
            return
        }
        let active = Set(conditions.compactMap(\.alarm)).filter { kind in
            kind != .signalLoss || settings.signalLossEnabled
        }
        for kind in alarmEngine.update(active: active, now: now) {
            notifier.post(kind, reading: freshReading, unit: display.unit)
        }
    }

    /// Corre siempre (para seguir el sensor), pero solo notifica si los avisos están activados.
    private func evaluateSensorNotices() {
        guard let patient = selectedPatientID, let sensor else { return }
        var engine = sensorNotices[patient] ?? SensorNoticeEngine()
        let notice = engine.update(sensor: sensor, now: now)
        guard engine != sensorNotices[patient] else { return }
        sensorNotices[patient] = engine
        if !isDemo, let data = try? JSONEncoder().encode(sensorNotices) {
            UserDefaults.standard.set(data, forKey: Keys.sensorNotices)
        }
        if let notice, settings.notificationsEnabled, settings.sensorNoticesEnabled {
            notifier.post(notice, sensor: sensor)
        }
    }

    private static func savedSensorNotices() -> [String: SensorNoticeEngine] {
        UserDefaults.standard.data(forKey: Keys.sensorNotices)
            .flatMap { try? JSONDecoder().decode([String: SensorNoticeEngine].self, from: $0) } ?? [:]
    }

    private func withoutRefresh(_ body: () -> Void) {
        suppressRefresh = true
        body()
        suppressRefresh = false
    }
}
