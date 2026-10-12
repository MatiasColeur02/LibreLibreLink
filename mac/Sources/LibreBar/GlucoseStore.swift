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
    @ObservationIgnored private var suppressRefresh = false

    private enum Keys {
        static let patient = "selectedPatientID"
        static let region = "region"
        static let settings = "alarmSettings"
    }

    init() {
        settings = UserDefaults.standard.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(AlarmSettings.self, from: $0) } ?? AlarmSettings()
        selectedPatientID = UserDefaults.standard.string(forKey: Keys.patient)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") || ProcessInfo.processInfo.environment["LIBREBAR_DEMO"] != nil {
            startDemo()
        } else if let credentials = Keychain.load() {
            start(with: makeClient(credentials))
        }
        startClock()
    }

    private var pollInterval: TimeInterval { isDemo ? Self.demoPollInterval : Self.pollInterval }

    // MARK: Estado

    /// Problemas activos, del más grave al más leve.
    var conditions: [GlucoseCondition] {
        if phase == .needsLogin {
            return [.needsAttention(needsAttention ?? "Iniciá sesión con tu cuenta de LibreLinkUp.")]
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
        withoutRefresh { selectedPatientID = nil }
        start(with: DemoServer.makeClient())
    }

    func stopDemo() {
        resetSession()
        isDemo = false
        notifier.isDemo = false
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
                needsAttention = "La cuenta LibreLinkUp no sigue a nadie. Aceptá la invitación enviada desde LibreLink."
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
        guard settings.notificationsEnabled, phase != .needsLogin else {
            alarmEngine = AlarmEngine()
            return
        }
        let active = Set(conditions.compactMap(\.alarm)).filter { kind in
            kind != .signalLoss || settings.signalLossEnabled
        }
        for kind in alarmEngine.update(active: active, now: now) {
            notifier.post(kind, reading: freshReading)
        }
    }

    private func withoutRefresh(_ body: () -> Void) {
        suppressRefresh = true
        body()
        suppressRefresh = false
    }
}
