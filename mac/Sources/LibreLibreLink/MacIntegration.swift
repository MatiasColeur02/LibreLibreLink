import AppKit
import Carbon.HIToolbox
import CoreAudio
import CoreMediaIO
import Foundation
import LibreKit

/// Combinación de teclas global (sin permiso de Accesibilidad: usa `RegisterEventHotKey`).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// Lo que hace al apretarla.
    var action: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ choice: HotKeyChoice) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let (key, modifiers) = Self.keys(choice) else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4C4C_4C4B), id: 1) // "LLLK"
        RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func keys(_ choice: HotKeyChoice) -> (UInt32, UInt32)? {
        switch choice {
        case .off: nil
        case .optionCommandG: (UInt32(kVK_ANSI_G), UInt32(optionKey | cmdKey))
        case .controlOptionG: (UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey))
        case .controlOptionCommandG: (UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey | cmdKey))
        case .optionCommandL: (UInt32(kVK_ANSI_L), UInt32(optionKey | cmdKey))
        }
    }
}

/// El ícono de LibreLibreLink en la barra de menú.
@MainActor
enum StatusItem {
    /// Abre (o cierra) el panel como si se hubiera hecho clic en el ícono. `MenuBarExtra` no
    /// tiene API para esto: se busca el botón de su ventana en la barra.
    static func togglePanel() {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = button(in: window.contentView) {
                NSApp.activate()
                button.performClick(nil)
                return
            }
        }
    }

    private static func button(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap(button(in:)).first
    }
}

/// ¿Hay una llamada o reunión? Se infiere de la cámara o el micrófono en uso por cualquier app
/// (macOS no tiene una API pública para saber si se comparte la pantalla). No pide permisos.
enum CallDetector {
    static var isInCall: Bool { cameraInUse || microphoneInUse }

    static var cameraInUse: Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == 0
                && running != 0
        }
    }

    static var microphoneInUse: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return false }

        return devices.contains { device in
            // Solo dispositivos con entrada (micrófonos).
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return false }

            var running = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &running, 0, nil, &valueSize, &value) == noErr && value != 0
        }
    }
}

/// Atajos del usuario (app Atajos), por nombre, con la herramienta `shortcuts` del sistema.
enum UserShortcuts {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Nombres de los atajos del usuario, ordenados.
    static func list() async -> [String] {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = tool
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }.value
    }

    /// Corre el atajo sin esperar a que termine. Recibe `input` como texto.
    static func run(_ name: String, input: String) {
        let file = FileManager.default.temporaryDirectory.appending(path: "librelibrelink-\(UUID().uuidString).txt")
        try? input.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name, "--input-path", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in try? FileManager.default.removeItem(at: file) }
        try? process.run()
    }

    static func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
    }
}
