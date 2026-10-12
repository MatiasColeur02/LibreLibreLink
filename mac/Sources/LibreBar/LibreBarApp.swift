import AppKit
import SwiftUI

@main
struct LibreBarApp: App {
    @State private var store = GlucoseStore()

    init() {
        // Solo barra de menú: sin ícono en el Dock (también cuando corre con `swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
