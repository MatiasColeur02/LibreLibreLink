import Charts
import LibreKit
import SwiftUI

struct ContentView: View {
    let store: GlucoseStore
    @State private var showingSettings = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isDemo {
                DemoBanner(store: store)
            }
            if showingSettings {
                SettingsView(store: store)
            } else {
                switch store.phase {
                case .needsLogin:
                    LoginView(store: store)
                case .loading:
                    ProgressView("Conectando con LibreLinkUp…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .ready:
                    ProblemsView(conditions: store.conditions)
                    ReadingView(store: store)
                }
            }

            Divider()
            HStack {
                Button(showingSettings ? "Listo" : "Ajustes") { showingSettings.toggle() }
                if store.phase == .ready, !showingSettings {
                    Button("Actualizar") { store.refreshNow() }
                    Button("Abrir ventana") {
                        // Esconder el panel de la barra (es la ventana activa al tocar el botón).
                        NSApp.keyWindow?.close()
                        openWindow(id: MainWindow.id)
                        NSApp.activate()
                    }
                }
                Spacer()
                Button("Salir") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)

            Text("No reemplaza las alarmas oficiales de LibreLink. Ante síntomas, medí con glucómetro.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 340)
    }
}

/// Avisa que los datos son inventados y deja elegir qué situación simular.
struct DemoBanner: View {
    @Bindable var store: GlucoseStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Modo demo · datos inventados", systemImage: "theatermasks.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Spacer()
                Button("Salir del demo") { store.stopDemo() }
                    .controlSize(.mini)
            }
            Picker("Escenario", selection: $store.demoScenario) {
                ForEach(DemoScenario.allCases) { scenario in
                    Text(scenario.label).tag(scenario)
                    if scenario == .tour { Divider() }
                }
            }
            .controlSize(.small)
            if store.demoScenario == .tour {
                Text("Cambia de situación cada \(Int(DemoScenario.tourStep)) s (alta, baja, sin señal, sin conexión…).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LoginView: View {
    let store: GlucoseStore
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cuenta de LibreLinkUp").font(.headline)
            Text("Usá la cuenta de seguidor invitada desde LibreLink (Menú ▸ Compartir ▸ Conectar a LibreLinkUp).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField("Contraseña", text: $password)
                .textContentType(.password)
                .onSubmit(submit)
            Button(action: submit) {
                if working { ProgressView().controlSize(.small) } else { Text("Iniciar sesión") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working || email.isEmpty || password.isEmpty)

            if let error = store.loginError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.isDemo {
                Divider()
                Button("Probar sin cuenta (datos de demostración)") { store.startDemo() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty, !working else { return }
        working = true
        Task {
            await store.signIn(email: email, password: password)
            working = false
        }
    }
}

struct ReadingView: View {
    let store: GlucoseStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.patients.count > 1 {
                Picker("Paciente", selection: Binding(
                    get: { store.selectedPatientID ?? "" },
                    set: { store.selectedPatientID = $0 }
                )) {
                    ForEach(store.patients) { Text($0.displayName).tag($0.id) }
                }
            }

            if let current = store.current {
                let fresh = store.freshReading != nil
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.display.unit.reading(current.mgdL))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(fresh ? store.display.color(for: current.mgdL) : .secondary)
                        .strikethrough(!fresh)
                    Text(store.display.unit.symbol).foregroundStyle(.secondary)
                    Text(current.trend?.arrow ?? "")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(fresh ? .primary : .secondary)
                    Spacer()
                }
                Text(subtitle(for: current))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sin lecturas todavía.").foregroundStyle(.secondary)
            }

            if let sensor = store.sensor {
                Label(sensorText(sensor), systemImage: "sensor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(for measurement: GlucoseMeasurement) -> String {
        let minutes = Int(store.now.timeIntervalSince(measurement.date) / 60)
        let age = minutes < 1 ? String(localized: "recién") : String(localized: "hace \(minutes) min")
        let trend = measurement.trend?.label ?? ""
        return [trend, age].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func sensorText(_ sensor: SensorInfo) -> String {
        let end = sensor.expectedEnd
        if end <= store.now { return String(localized: "Sensor terminado") }
        let remaining = end.timeIntervalSince(store.now)
        let days = Int(remaining / 86_400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3600)
        return String(localized: "Sensor: termina en \(days) d \(hours) h (\(end.formatted(date: .abbreviated, time: .shortened)))")
    }
}

struct SettingsView: View {
    @Bindable var store: GlucoseStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    private var unit: GlucoseUnit { store.display.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alarmas").font(.headline)

            Toggle("Notificaciones de alarma", isOn: $store.settings.notificationsEnabled)
                .onChange(of: store.settings.notificationsEnabled) { _, enabled in
                    if enabled { Task { await store.notifier.requestAuthorization() } }
                }
            notificationStatus

            Toggle(isOn: $store.settings.lowEnabled) {
                Stepper(value: $store.settings.lowThreshold, in: AlarmSettings.lowRange, step: 5) {
                    Text("Baja: < \(unit.withSymbol(store.settings.lowThreshold))")
                }
            }
            Toggle(isOn: $store.settings.highEnabled) {
                Stepper(value: $store.settings.highThreshold, in: AlarmSettings.highRange, step: 10) {
                    Text("Alta: > \(unit.withSymbol(store.settings.highThreshold))")
                }
            }
            Toggle("Sin señal (20 min sin lecturas)", isOn: $store.settings.signalLossEnabled)
            Text("La baja grave (< \(unit.withSymbol(AlarmSettings.urgentLowThreshold))) siempre se muestra y avisa. Las alarmas se repiten cada 5 min mientras dura el problema.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Visualización").font(.headline)
            Picker("Unidad", selection: $store.display.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Es muy importante elegir la misma unidad que usa tu medidor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $store.display.targetLow, in: DisplaySettings.targetLowRange, step: 5) {
                Text("Rango objetivo desde \(unit.withSymbol(store.display.targetLow))")
            }
            Stepper(value: $store.display.targetHigh, in: DisplaySettings.targetHighRange, step: 10) {
                Text("hasta \(unit.withSymbol(store.display.targetHigh))")
            }
            Text("El rango objetivo pinta los gráficos y el tiempo en rango; no cambia las alarmas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("General").font(.headline)
            Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                .disabled(!AlarmNotifier.isBundled)
                .onChange(of: launchAtLogin) { _, enabled in
                    do { try LaunchAtLogin.set(enabled); launchError = nil }
                    catch { launchError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.orange)
            }
            if store.phase != .needsLogin {
                Button("Cerrar sesión de LibreLinkUp") { store.signOut() }
                    .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .task { await store.notifier.refreshAuthorization() }
    }

    @ViewBuilder private var notificationStatus: some View {
        switch store.notifier.authorization {
        case .unavailable:
            hint("Las notificaciones y el inicio automático requieren abrir LibreLibreLink.app (scripts/make-app.sh), no `swift run`.")
        case .denied:
            hint("macOS tiene bloqueadas las notificaciones de LibreLibreLink: Ajustes del Sistema ▸ Notificaciones.")
        case .notDetermined:
            EmptyView()
        case .allowed:
            if store.settings.notificationsEnabled {
                Button("Probar notificación") { store.notifier.postTest() }.controlSize(.small)
            }
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
