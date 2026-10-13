import AppKit
import LibreKit
import SwiftUI

@main
struct LibreLibreLinkApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Solo barra de menú: sin ícono en el Dock (también cuando corre con `swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("LibreLibreLink", id: MainWindow.id) {
            MainWindow(store: delegate.store)
        }
        .defaultSize(width: 980, height: 760)
        .defaultLaunchBehavior(.suppressed)
        // Las URLs `librelibrelink://` las atiende el delegado; no abren ventanas.
        .handlesExternalEvents(matching: [])
    }
}

/// Recibe las URLs `librelibrelink://` que mandan las acciones de Atajos y los widgets.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = GlucoseStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.startMacIntegration()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for command in urls.compactMap(AppCommand.init(url:)) {
            store.handle(command)
        }
    }
}
