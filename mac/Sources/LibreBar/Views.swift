import Charts
import LibreKit
import SwiftUI

/// Rango objetivo que se pinta en el gráfico (por defecto de LibreLink).
private let targetRange = 70.0...180.0

struct ContentView: View {
    let store: GlucoseStore
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

/// Lista de problemas activos con su explicación.
struct ProblemsView: View {
    let conditions: [GlucoseCondition]

    var body: some View {
        if !conditions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(conditions, id: \.self) { condition in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: condition.symbolName)
                            .foregroundStyle(tint(condition))
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
            .background(tint(conditions[0]).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tint(_ condition: GlucoseCondition) -> Color {
        switch condition {
        case .urgentLow, .low: .red
        case .high: .orange
        default: condition.severity >= .warning ? .orange : .secondary
        }
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
                    Text(GlucoseStatus.displayValue(current.mgdL))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(fresh ? color(for: current.mgdL) : .secondary)
                        .strikethrough(!fresh)
                    Text("mg/dL").foregroundStyle(.secondary)
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

            if !store.history.isEmpty {
                GlucoseChart(history: store.history, current: store.current, settings: store.settings)
                    .frame(height: 150)
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
        let age = minutes < 1 ? "recién" : "hace \(minutes) min"
        let trend = measurement.trend?.label ?? ""
        return [trend, age].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func sensorText(_ sensor: SensorInfo) -> String {
        let end = sensor.expectedEnd
        if end <= store.now { return "Sensor terminado" }
        let remaining = end.timeIntervalSince(store.now)
        let days = Int(remaining / 86_400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3600)
        return "Sensor: termina en \(days) d \(hours) h (\(end.formatted(date: .abbreviated, time: .shortened)))"
    }
}

struct GlucoseChart: View {
    let history: [GlucoseMeasurement]
    let current: GlucoseMeasurement?
    let settings: AlarmSettings

    private var points: [GlucoseMeasurement] {
        guard let current, current.date > (history.last?.date ?? .distantPast) else { return history }
        return history + [current]
    }

    var body: some View {
        let maxValue = min(350, max(250, (points.map(\.mgdL).max() ?? 0) + 20))
        Chart {
            RectangleMark(
                xStart: nil, xEnd: nil,
                yStart: .value("Bajo", targetRange.lowerBound),
                yEnd: .value("Alto", targetRange.upperBound)
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

            ForEach(points, id: \.date) { point in
                LineMark(x: .value("Hora", point.date), y: .value("mg/dL", min(point.mgdL, maxValue)))
                    .foregroundStyle(.secondary)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Hora", point.date), y: .value("mg/dL", min(point.mgdL, maxValue)))
                    .symbolSize(12)
                    .foregroundStyle(color(for: point.mgdL))
            }
        }
        .chartYScale(domain: 40...maxValue)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var store: GlucoseStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

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
                    Text("Baja: < \(Int(store.settings.lowThreshold)) mg/dL")
                }
            }
            Toggle(isOn: $store.settings.highEnabled) {
                Stepper(value: $store.settings.highThreshold, in: AlarmSettings.highRange, step: 10) {
                    Text("Alta: > \(Int(store.settings.highThreshold)) mg/dL")
                }
            }
            Toggle("Sin señal (20 min sin lecturas)", isOn: $store.settings.signalLossEnabled)
            Text("La baja grave (< \(Int(AlarmSettings.urgentLowThreshold)) mg/dL) siempre se muestra y avisa. Las alarmas se repiten cada 5 min mientras dura el problema.")
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
            hint("Las notificaciones y el inicio automático requieren abrir LibreBar.app (scripts/make-app.sh), no `swift run`.")
        case .denied:
            hint("macOS tiene bloqueadas las notificaciones de LibreBar: Ajustes del Sistema ▸ Notificaciones.")
        case .notDetermined:
            EmptyView()
        case .allowed:
            if store.settings.notificationsEnabled {
                Button("Probar notificación") { store.notifier.postTest() }.controlSize(.small)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func color(for mgdL: Double) -> Color {
    if mgdL < targetRange.lowerBound { return .red }
    if mgdL > targetRange.upperBound { return .orange }
    return .green
}
