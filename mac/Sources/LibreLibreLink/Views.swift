import Charts
import LibreKit
import SwiftUI

struct ContentView: View {
    let store: GlucoseStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isDemo {
                DemoBanner(store: store)
            }
            switch store.phase {
            case .needsLogin:
                LoginView(store: store)
            case .loading:
                ProgressView("Conectando con LibreLinkUp…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .ready:
                if store.alarmsBroken {
                    HStack {
                        Label("Las alarmas no pueden avisarte", systemImage: "bell.slash.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ver") { openMainWindow(.settings) }.controlSize(.small)
                    }
                }
                ProblemsView(conditions: store.conditions)
                SnoozedView(store: store)
                ReadingView(store: store)
            }

            Divider()
            HStack {
                if store.phase == .ready {
                    Button("Actualizar") { store.refreshNow() }
                    Button("Abrir ventana") { openMainWindow() }
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

    /// Abre la ventana grande (en la sección indicada) y esconde el panel de la barra.
    private func openMainWindow(_ tab: MainWindow.Tab? = nil) {
        if let tab { store.windowTab = tab }
        // El panel es la ventana activa al tocar el botón.
        NSApp.keyWindow?.close()
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

/// Alarmas pospuestas desde la notificación, con la opción de reactivarlas.
struct SnoozedView: View {
    let store: GlucoseStore

    var body: some View {
        let snoozed = store.snoozes.active(now: store.now)
        if let last = snoozed.map(\.until).max() {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    "Pospuestas hasta las \(last.formatted(date: .omitted, time: .shortened)): \(snoozed.map(\.kind.title).formatted(.list(type: .and)))",
                    systemImage: "bell.badge.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Reactivar") { store.cancelSnoozes() }.controlSize(.mini)
            }
        }
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
        if sensor.isWarmingUp(at: store.now) {
            return String(localized: "Sensor: calentando, listo a las \(sensor.readyAt.formatted(date: .omitted, time: .shortened))")
        }
        let end = sensor.expectedEnd
        if end <= store.now { return String(localized: "Sensor terminado") }
        let remaining = end.timeIntervalSince(store.now)
        let days = Int(remaining / 86_400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3600)
        return String(localized: "Sensor: termina en \(days) d \(hours) h (\(end.formatted(date: .abbreviated, time: .shortened)))")
    }
}
