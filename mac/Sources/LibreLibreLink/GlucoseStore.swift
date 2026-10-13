import Foundation
import LibreKit
import Observation
import WidgetKit

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
    /// Sección de la ventana grande (el panel la usa para abrir directo en Ajustes).
    var windowTab: MainWindow.Tab = .today
    /// Alarmas pospuestas desde la notificación. Solo en memoria: al reiniciar vuelven a sonar.
    private(set) var snoozes = AlarmSnoozes()
    /// Pide abrir la ventana grande (lo atiende `MenuBarLabel`, que tiene `openWindow`).
    private(set) var windowOpenRequest = 0
    /// La cámara o el micrófono están en uso (se revisa solo si el modo discreto automático está activo).
    private(set) var inCall = false

    /// Atajo de teclado, modo discreto y atajos en alarma.
    var preferences: MacPreferences {
        didSet {
            guard preferences != oldValue else { return }
            if let data = try? JSONEncoder().encode(preferences) {
                UserDefaults.standard.set(data, forKey: Keys.preferences)
            }
            if preferences.hotKey != oldValue.hotKey { GlobalHotKey.shared.register(preferences.hotKey) }
            if preferences.discreetInCalls != oldValue.discreetInCalls { startCallMonitor() }
            publishSnapshot()
        }
    }

    /// No mostrar el valor en la barra ni en los widgets.
    var isDiscreet: Bool { preferences.discreet || (preferences.discreetInCalls && inCall) }
    /// Estado del sistema que decide si las alarmas llegan (se revisa con el reloj).
    private(set) var outputMuted = false
    private(set) var launchAtLogin = LaunchAtLogin.isEnabled

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
            publishSnapshot()
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
    @ObservationIgnored private var shortcutTrigger = ShortcutTrigger()
    @ObservationIgnored private var callTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshot: GlucoseSnapshot?

    private enum Keys {
        static let patient = "selectedPatientID"
        static let region = "region"
        static let settings = "alarmSettings"
        static let display = "displaySettings"
        static let sensorNotices = "sensorNotices"
        static let preferences = "macPreferences"
    }

    init() {
        settings = UserDefaults.standard.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(AlarmSettings.self, from: $0) } ?? AlarmSettings()
        display = UserDefaults.standard.data(forKey: Keys.display)
            .flatMap { try? JSONDecoder().decode(DisplaySettings.self, from: $0) } ?? DisplaySettings()
        preferences = UserDefaults.standard.data(forKey: Keys.preferences)
            .flatMap { try? JSONDecoder().decode(MacPreferences.self, from: $0) } ?? MacPreferences()
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
        notifier.onResponse = { [weak self] kind, action in self?.handleAlarmResponse(kind, action) }
        startClock()
        startCallMonitor()
    }

    /// Atajo de teclado global; se llama cuando la app ya terminó de abrir.
    func startMacIntegration() {
        GlobalHotKey.shared.action = { StatusItem.togglePanel() }
        GlobalHotKey.shared.register(preferences.hotKey)
        publishSnapshot()
    }

    // MARK: Comandos (Atajos y widgets)

    func handle(_ command: AppCommand) {
        switch command {
        case .open(let section):
            if let section { windowTab = MainWindow.Tab(section) }
            windowOpenRequest += 1
        case .snooze(let minutes):
            // Igual que desde la notificación: la baja grave sigue avisando.
            for kind in AlarmKind.allCases where kind != .urgentLow {
                snoozes.snooze(kind, for: TimeInterval(minutes * 60), now: Date())
            }
            evaluateAlarms()
        case .resumeAlarms:
            cancelSnoozes()
        case .discreet(let change):
            switch change {
            case .on: preferences.discreet = true
            case .off: preferences.discreet = false
            case .toggle: preferences.discreet.toggle()
            }
        case .logChanged:
            historyRevision += 1
        }
    }

    // MARK: Modo discreto

    /// Mientras el modo discreto automático está activo, revisa cada 5 s si hay una llamada.
    private func startCallMonitor() {
        callTask?.cancel()
        guard preferences.discreetInCalls else {
            inCall = false
            return
        }
        callTask = Task { [weak self] in
            while !Task.isCancelled {
                let inCall = CallDetector.isInCall
                guard let self else { return }
                if self.inCall != inCall {
                    self.inCall = inCall
                    self.publishSnapshot()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Widgets y Atajos

    /// Escribe lo que muestran los widgets y leen las acciones de Atajos, y recarga los
    /// widgets si algo cambió.
    private func publishSnapshot() {
        let patient = patients.first { $0.id == selectedPatientID }
        var readings: [GlucoseMeasurement] = []
        var today: GlucoseSnapshot.Today?
        if phase != .needsLogin {
            readings = storedReadings(in: DateInterval(start: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(60)))
            if readings.isEmpty { readings = history + (current.map { [$0] } ?? []) }
            let day = DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
            if let stats = GlucoseStatistics.compute(readings.filter { day.contains($0.date) }, period: day, display: display) {
                today = .init(
                    inRange: stats.zoneFractions[.inTarget] ?? 0,
                    below: stats.zoneFractions[.below] ?? 0,
                    above: stats.zoneFractions[.above] ?? 0,
                    mean: stats.mean,
                    lowEvents: stats.lowEvents
                )
            }
        }
        let problem = conditions.first.map { condition in
            GlucoseSnapshot.Problem(title: condition.title, symbol: condition.symbolName, tint: condition.snapshotTint)
        }
        let snapshot = GlucoseSnapshot(
            updatedAt: now, signedIn: phase != .needsLogin, isDemo: isDemo, discreet: isDiscreet,
            patientID: selectedPatientID, patientName: patient?.displayName, display: display,
            current: phase == .needsLogin ? nil : current, readings: readings, problem: problem,
            today: today, sensorEnd: sensor?.expectedEnd
        )
        guard !snapshot.sameContent(as: lastSnapshot) else { return }
        lastSnapshot = snapshot
        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
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

    // MARK: Registro

    /// Anotaciones del paciente elegido.
    func logEntries(in interval: DateInterval) -> [LogEntry] {
        guard let database, let patient = selectedPatientID else { return [] }
        return (try? database.entries(patientID: patient, in: interval)) ?? []
    }

    func saveLogEntry(_ entry: LogEntry) throws {
        guard let database, let patient = selectedPatientID else { return }
        try database.save(entry, patientID: patient)
        historyRevision += 1
    }

    func deleteLogEntry(_ entry: LogEntry) {
        guard let database else { return }
        do {
            try database.deleteEntry(id: entry.id)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
        historyRevision += 1
    }

    /// El demo usa una base en memoria con 14 días inventados; nunca toca el archivo real.
    private func openHistory(demo: Bool) {
        do {
            let database = try HistoryDatabase(url: demo ? nil : HistoryDatabase.defaultURL)
            if demo {
                for patient in ["demo-1", "demo-2"] {
                    try database.insert(DemoServer.backfill(patientID: patient, days: 14), patientID: patient)
                    for entry in DemoServer.logEntries(patientID: patient, days: 14) {
                        try database.save(entry, patientID: patient)
                    }
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
            recent: history,
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
        snoozes = AlarmSnoozes()
        shortcutTrigger = ShortcutTrigger()
        phase = .needsLogin
        publishSnapshot()
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
                self.publishSnapshot()
                await self.refreshDeliveryChecks()
            }
        }
    }

    /// Hace una consulta y devuelve cuánto esperar hasta la próxima.
    private func refresh(using client: LibreLinkUpClient) async -> TimeInterval {
        defer {
            now = Date()
            evaluateAlarms()
            publishSnapshot()
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
        runShortcuts()
        guard settings.notificationsEnabled || settings.speakAlarms, phase != .needsLogin else {
            alarmEngine = AlarmEngine()
            return
        }
        let active = AlarmPolicy.alarms(conditions: conditions, readings: history + (current.map { [$0] } ?? []),
                                        settings: settings, snoozes: snoozes, now: now)
        let escalate = settings.escalationEnabled
        for kind in alarmEngine.update(active: active, now: now, escalate: escalate) {
            // Una baja sin atender también se lee en voz alta, aunque la voz esté apagada.
            let escalated = escalate && alarmEngine.isEscalated(kind, now: now)
            if settings.notificationsEnabled {
                notifier.post(kind, reading: freshReading, unit: display.unit, escalated: escalated)
            }
            if settings.speakAlarms || escalated { notifier.speak(kind, reading: freshReading, unit: display.unit) }
        }
    }

    /// Atajos del usuario al empezar una baja/alta/sin señal y al volver al rango. No dependen
    /// de que las notificaciones estén activadas, ni de las pospuestas.
    private func runShortcuts() {
        guard phase == .ready else { return }
        let alarms = AlarmPolicy.alarms(conditions: conditions, readings: history + (current.map { [$0] } ?? []),
                                        settings: settings, snoozes: AlarmSnoozes(), now: now)
        for event in shortcutTrigger.update(alarms: alarms, hasReading: freshReading != nil) {
            guard let name = preferences.shortcut(for: event) else { continue }
            UserShortcuts.run(name, input: shortcutInput(event))
        }
    }

    /// Texto que recibe el atajo, p. ej. "Glucosa baja · 64 mg/dL ↘".
    private func shortcutInput(_ event: ShortcutEvent) -> String {
        let reading = freshReading.map { "\(display.unit.withSymbol($0.mgdL)) \($0.trend?.arrow ?? "")" } ?? ""
        return [event.title, reading].filter { !$0.isEmpty }.joined(separator: " · ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lo que el usuario eligió en la notificación de una alarma.
    private func handleAlarmResponse(_ kind: AlarmKind, _ action: AlarmAction) {
        alarmEngine.acknowledge(kind)
        switch action {
        case .opened:
            break
        case .snooze(let duration):
            snoozes.snooze(kind, for: duration, now: Date())
        case .treated:
            snoozes.snooze(kind, for: AlarmAction.treatedDelay, now: Date())
            notifier.scheduleRecheck(after: AlarmAction.treatedDelay)
        }
        evaluateAlarms()
    }

    /// Vuelve a activar las alarmas pospuestas.
    func cancelSnoozes() {
        snoozes.cancelAll()
        evaluateAlarms()
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

    // MARK: Diagnóstico de alarmas (R15)

    var deliveryState: AlarmDeliveryState {
        var state = AlarmDeliveryState(settings: settings, permission: notifier.authorization)
        state.bannersEnabled = notifier.bannersEnabled
        state.soundEnabled = notifier.soundEnabled
        state.timeSensitiveEnabled = notifier.timeSensitiveEnabled
        state.outputMuted = outputMuted
        state.launchAtLogin = launchAtLogin
        state.hasData = phase == .ready && connectionError == nil && needsAttention == nil
        return state
    }

    /// Por qué una alarma podría no llegar, del más grave al más leve.
    var deliveryIssues: [AlarmDeliveryIssue] { AlarmDelivery.issues(deliveryState) }

    /// Se activó algún aviso (notificación o voz) pero ninguno puede llegar: se muestra en el panel.
    var alarmsBroken: Bool {
        let state = deliveryState
        return (settings.notificationsEnabled || settings.speakAlarms) && state.hasData && !AlarmDelivery.canAlert(state)
    }

    func refreshDeliveryChecks() async {
        await notifier.refreshAuthorization()
        outputMuted = SystemAudio.isOutputMuted
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { launchAtLogin = LaunchAtLogin.isEnabled }
        try LaunchAtLogin.set(enabled)
    }

    private func withoutRefresh(_ body: () -> Void) {
        suppressRefresh = true
        body()
        suppressRefresh = false
    }
}

extension ShortcutEvent {
    var title: String {
        switch self {
        case .low: String(localized: "Glucosa baja")
        case .high: String(localized: "Glucosa alta")
        case .signalLoss: String(localized: "Sin señal del sensor")
        case .backInRange: String(localized: "De vuelta en rango")
        }
    }
}

extension GlucoseCondition {
    var snapshotTint: GlucoseSnapshot.Tint {
        switch self {
        case .urgentLow, .low, .lowSoon, .fallingFast: .red
        case .high: .orange
        default: severity >= .warning ? .orange : .secondary
        }
    }
}

extension MainWindow.Tab {
    init(_ section: AppCommand.Section) {
        switch section {
        case .today: self = .today
        case .logbook: self = .logbook
        case .reports: self = .reports
        case .settings: self = .settings
        }
    }
}
