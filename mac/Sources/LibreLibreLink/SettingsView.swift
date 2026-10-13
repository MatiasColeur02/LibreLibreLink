import AppKit
import LibreKit
import SwiftUI

/// Sección "Ajustes" de la ventana: alarmas, horario de noche, atajos, visualización y cuenta.
struct SettingsView: View {
    @Bindable var store: GlucoseStore
    @State private var launchError: String?
    /// Atajos del usuario (app Atajos); `nil` mientras se cargan.
    @State private var userShortcuts: [String]?

    private var unit: GlucoseUnit { store.display.unit }

    var body: some View {
        Form {
            delivery
            low
            high
            night
            if !store.snoozes.active(now: store.now).isEmpty {
                Section("Pospuestas") {
                    SnoozedView(store: store)
                }
            }
            other
            shortcuts
            mac
            display
            general
        }
        .formStyle(.grouped)
        .task { await store.refreshDeliveryChecks() }
        // Al volver de Ajustes del Sistema, revisar de nuevo.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshDeliveryChecks() }
        }
    }

    // MARK: Secciones

    private var delivery: some View {
        Section {
            AlarmDeliveryView(store: store, launchError: $launchError)
            HStack {
                Toggle("Notificaciones de alarma", isOn: $store.settings.notificationsEnabled)
                    .onChange(of: store.settings.notificationsEnabled) { _, enabled in
                        if enabled { Task { await store.notifier.requestAuthorization() } }
                    }
                if store.settings.notificationsEnabled, store.notifier.authorization == .allowed {
                    Button("Probar notificación") { store.notifier.postTest() }.controlSize(.small)
                }
            }
            HStack {
                Toggle("Leer las alarmas en voz alta", isOn: $store.settings.speakAlarms)
                if store.settings.speakAlarms {
                    Button("Probar voz") { store.notifier.speakTest() }.controlSize(.small)
                }
            }
        } header: {
            Text("Cómo te avisa")
        } footer: {
            note("Las alarmas se repiten cada 5 min mientras dura el problema. Desde la notificación se pueden posponer, y en una baja, elegir «Ya comí» para que te recuerde volver a medir en 15 min.")
        }
    }

    private var low: some View {
        Section {
            Toggle("Alarma de baja", isOn: $store.settings.lowEnabled)
            Stepper(value: $store.settings.lowThreshold, in: AlarmSettings.lowRange, step: 5) {
                Text("Por debajo de \(unit.withSymbol(store.settings.lowThreshold))")
            }
            .disabled(!store.settings.lowEnabled)
            Toggle("Baja en camino (~15 min antes, estimado)", isOn: $store.settings.lowSoonEnabled)
                .disabled(!store.settings.lowEnabled)
            Toggle("Bajando rápido (más de \(unit.withSymbol(2)) por minuto, aunque esté en rango)", isOn: $store.settings.fallingFastEnabled)
            Toggle("Insistir si no se atiende una baja", isOn: $store.settings.escalationEnabled)
        } header: {
            Text("Baja")
        } footer: {
            note("La baja grave (< \(unit.withSymbol(AlarmSettings.urgentLowThreshold))) siempre se muestra y avisa. Si una baja sigue 10 min sin que toques la notificación, se repite cada 2 min y se lee en voz alta aunque la voz esté apagada. «Baja en camino» es una estimación con las lecturas de los últimos 15 min.")
        }
    }

    private var high: some View {
        Section {
            Toggle("Alarma de alta", isOn: $store.settings.highEnabled)
            Stepper(value: $store.settings.highThreshold, in: AlarmSettings.highRange, step: 10) {
                Text("Por encima de \(unit.withSymbol(store.settings.highThreshold))")
            }
            .disabled(!store.settings.highEnabled)
            Picker("Avisar", selection: $store.settings.highDelay) {
                ForEach(AlarmSettings.highDelayOptions, id: \.self) { Text(Self.delayLabel($0)).tag($0) }
            }
            .disabled(!store.settings.highEnabled)
        } header: {
            Text("Alta")
        } footer: {
            note("Con una demora, un pico corto después de comer no avisa, pero una alta que no baja sí. La barra de menú muestra la alta enseguida igual.")
        }
    }

    private var night: some View {
        Section {
            Toggle("Usar otros umbrales de noche", isOn: $store.settings.nightEnabled)
            if store.settings.nightEnabled {
                DatePicker("Desde", selection: time($store.settings.nightStart), displayedComponents: .hourAndMinute)
                DatePicker("Hasta", selection: time($store.settings.nightEnd), displayedComponents: .hourAndMinute)
                Stepper(value: $store.settings.nightLowThreshold, in: AlarmSettings.lowRange, step: 5) {
                    Text("Baja de noche: < \(unit.withSymbol(store.settings.nightLowThreshold))")
                }
                .disabled(!store.settings.lowEnabled)
                Stepper(value: $store.settings.nightHighThreshold, in: AlarmSettings.highRange, step: 10) {
                    Text("Alta de noche: > \(unit.withSymbol(store.settings.nightHighThreshold))")
                }
                .disabled(!store.settings.highEnabled)
                Toggle("No avisar la alta de noche", isOn: $store.settings.nightSilencesHigh)
                    .disabled(!store.settings.highEnabled)
            }
        } header: {
            Text("Noche")
        } footer: {
            if store.settings.nightEnabled {
                note(store.settings.isNight(at: store.now)
                     ? String(localized: "Ahora rigen los umbrales de noche. Las bajas siempre avisan.")
                     : String(localized: "Ahora rigen los umbrales de día. Las bajas siempre avisan."))
            }
        }
    }

    private var other: some View {
        Section("Otros avisos") {
            Toggle("Sin señal (20 min sin lecturas)", isOn: $store.settings.signalLossEnabled)
            Toggle("Avisos del sensor (nuevo, listo y fin)", isOn: $store.settings.sensorNoticesEnabled)
        }
    }

    private var shortcuts: some View {
        Section {
            ForEach(ShortcutEvent.allCases) { event in
                Picker(event.settingsLabel, selection: shortcutBinding(event)) {
                    Text("Ninguno").tag("")
                    let current = store.preferences.shortcut(for: event)
                    // El elegido aunque ya no exista (o mientras se carga la lista).
                    if let current, !(userShortcuts ?? []).contains(current) {
                        Text(current).tag(current)
                    }
                    ForEach(userShortcuts ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Button("Abrir Atajos") { UserShortcuts.openApp() }
                Button("Actualizar la lista") { Task { userShortcuts = await UserShortcuts.list() } }
            }
            .controlSize(.small)
        } header: {
            Text("Atajos en alarmas")
        } footer: {
            note("Corre un atajo tuyo de la app Atajos una vez al empezar cada episodio, aunque las notificaciones estén apagadas o la alarma pospuesta. Recibe un texto como «Glucosa baja · 64 mg/dL ↘». Por ejemplo: pausar la música en una baja y reanudarla al volver al rango.")
        }
        .task { userShortcuts = await UserShortcuts.list() }
    }

    private var mac: some View {
        Section {
            Picker("Atajo de teclado para abrir el panel", selection: $store.preferences.hotKey) {
                ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Modo discreto", isOn: $store.preferences.discreet)
            Toggle("Modo discreto automático en llamadas", isOn: $store.preferences.discreetInCalls)
        } header: {
            Text("Barra de menú")
        } footer: {
            note("El modo discreto oculta el valor en la barra y en los widgets; si hay un problema, se sigue viendo su ícono. El automático se activa mientras alguna app usa la cámara o el micrófono (Zoom, Meet, Teams, FaceTime…); macOS no permite saber si se está compartiendo la pantalla. Los widgets se agregan con clic derecho en el escritorio ▸ Editar widgets.")
        }
    }

    private var display: some View {
        Section {
            Picker("Unidad", selection: $store.display.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper(value: $store.display.targetLow, in: DisplaySettings.targetLowRange, step: 5) {
                Text("Rango objetivo desde \(unit.withSymbol(store.display.targetLow))")
            }
            Stepper(value: $store.display.targetHigh, in: DisplaySettings.targetHighRange, step: 10) {
                Text("hasta \(unit.withSymbol(store.display.targetHigh))")
            }
        } header: {
            Text("Visualización")
        } footer: {
            note("Es muy importante elegir la misma unidad que usa tu medidor. El rango objetivo pinta los gráficos y el tiempo en rango; no cambia las alarmas.")
        }
    }

    private var general: some View {
        Section {
            Toggle("Abrir al iniciar sesión", isOn: Binding(
                get: { store.launchAtLogin },
                set: { enabled in
                    do { try store.setLaunchAtLogin(enabled); launchError = nil }
                    catch { launchError = error.localizedDescription }
                }
            ))
            .disabled(!AlarmNotifier.isBundled)
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.orange)
            }
            if store.phase != .needsLogin {
                Button("Cerrar sesión de LibreLinkUp") { store.signOut() }
            }
        } header: {
            Text("General")
        } footer: {
            note("No reemplaza las alarmas oficiales de LibreLink. Ante síntomas, medí con glucómetro. No usar para decidir dosis.")
        }
    }

    // MARK: Ayudas

    private func note(_ key: LocalizedStringKey) -> some View {
        note(Text(key))
    }

    /// Texto ya traducido (`String(localized:)`); los literales usan la de arriba.
    @_disfavoredOverload
    private func note(_ text: String) -> some View {
        note(Text(text))
    }

    private func note(_ text: Text) -> some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcutBinding(_ event: ShortcutEvent) -> Binding<String> {
        Binding(
            get: { store.preferences.shortcut(for: event) ?? "" },
            set: { store.preferences.shortcuts[event.rawValue] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Minutos desde la medianoche ↔ hora del día, para los `DatePicker`.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private static func delayLabel(_ delay: TimeInterval) -> String {
        if delay == 0 { return String(localized: "Enseguida") }
        if delay < 3600 { return String(localized: "Si dura \(Int(delay / 60)) min") }
        return String(localized: "Si dura \(Int(delay / 3600)) h")
    }
}

/// "¿Por qué no me llegan las alarmas?": lo que impide que avisen, con el arreglo a mano.
private struct AlarmDeliveryView: View {
    let store: GlucoseStore
    @Binding var launchError: String?

    var body: some View {
        let issues = store.deliveryIssues
        if issues.isEmpty {
            Label("Las alarmas pueden avisarte mientras la Mac esté encendida y despierta.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(issues, id: \.self) { issue in
                HStack(alignment: .firstTextBaseline) {
                    Label(issue.text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    fix(for: issue)
                }
            }
        }
    }

    @ViewBuilder private func fix(for issue: AlarmDeliveryIssue) -> some View {
        switch issue {
        case .permissionNotRequested:
            Button("Permitir") { Task { await store.notifier.requestAuthorization() } }.controlSize(.small)
        case .permissionDenied, .bannersOff, .soundOff, .timeSensitiveOff:
            Button("Abrir Ajustes") { AlarmNotifier.openNotificationSettings() }.controlSize(.small)
        case .muted:
            Button("Abrir Sonido") { AlarmNotifier.openSoundSettings() }.controlSize(.small)
        case .launchAtLoginOff:
            Button("Activar") {
                do { try store.setLaunchAtLogin(true); launchError = nil }
                catch { launchError = error.localizedDescription }
            }
            .controlSize(.small)
        case .nothingEnabled, .notBundled, .noData:
            EmptyView()
        }
    }
}

private extension AlarmDeliveryIssue {
    var text: String {
        switch self {
        case .nothingEnabled: String(localized: "Notificaciones y voz apagadas: nada te va a avisar.")
        case .notBundled: String(localized: "Las notificaciones requieren abrir LibreLibreLink.app, no `swift run`.")
        case .permissionNotRequested: String(localized: "macOS todavía no dio permiso para notificar.")
        case .permissionDenied: String(localized: "macOS bloquea las notificaciones de LibreLibreLink.")
        case .bannersOff: String(localized: "Las notificaciones no se muestran en pantalla (estilo «Ninguno»).")
        case .soundOff: String(localized: "Las notificaciones no tienen sonido.")
        case .timeSensitiveOff: String(localized: "Notificaciones urgentes desactivadas: Concentración puede silenciarlas.")
        case .muted: String(localized: "La Mac está en silencio.")
        case .launchAtLoginOff: String(localized: "No se abre al iniciar sesión: tras reiniciar no hay alarmas hasta abrirla.")
        case .noData: String(localized: "Sin datos de LibreLinkUp: no hay lecturas que vigilar.")
        }
    }
}

private extension ShortcutEvent {
    var settingsLabel: LocalizedStringKey {
        switch self {
        case .low: "Al empezar una baja"
        case .high: "Al empezar una alta"
        case .signalLoss: "Al perder la señal"
        case .backInRange: "Al volver al rango"
        }
    }
}
