import Foundation
import CoreNFC

/// Lee UID + patchInfo de un sensor FreeStyle Libre (ISO 15693 / NFC-V)
/// y determina la generación de seguridad (gen1 / gen2) con la MISMA regla
/// que usa la app de Abbott: se decide por `patchInfo[2]`.
///
/// Esto es lo único que necesitamos para saber si el camino "Mac ↔ sensor
/// directo por Bluetooth" es viable (gen1) o está bloqueado por la caja
/// blanca (gen2). NO activa el sensor ni habilita streaming: solo lee.
@MainActor
final class SensorReader: NSObject, ObservableObject, NFCTagReaderSessionDelegate {

    struct Result: Identifiable {
        let id = UUID()
        let uid: String          // UID tal cual lo entrega iOS
        let uidReversed: String  // UID en el orden que usa Libre para el serial
        let patchInfo: String    // bytes crudos en hex
        let family: String       // interpretación tentativa de patchInfo[0]
        let generation: String   // "gen1" / "gen2" / "desconocida"
        let verdict: String      // explicación para el usuario
    }

    @Published var status: String = "Tocá «Escanear» y acercá el iPhone al sensor."
    @Published var result: Result?
    @Published var isScanning = false

    private var session: NFCTagReaderSession?

    func scan() {
        guard NFCTagReaderSession.readingAvailable else {
            status = "Este iPhone no soporta lectura NFC (necesita iPhone 7 o superior)."
            return
        }
        result = nil
        isScanning = true
        status = "Iniciando NFC…"
        session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: nil)
        session?.alertMessage = "Acercá la parte de atrás del iPhone al sensor."
        session?.begin()
    }

    // MARK: - NFCTagReaderSessionDelegate

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.isScanning = false
            if self.result == nil {
                self.status = "Sesión NFC finalizada: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard case let .iso15693(tag)? = tags.first else {
            session.restartPolling()
            return
        }
        session.connect(to: tags.first!) { error in
            if let error = error {
                session.invalidate(errorMessage: "No se pudo conectar: \(error.localizedDescription)")
                return
            }
            // UID: iOS lo entrega con el byte de IC manufacturer al final.
            let uid = [UInt8](tag.identifier)

            // Comando propietario de Abbott 0xA1 (Core NFC inserta solo el
            // código de fabricante 0x07 después del byte de comando).
            tag.customCommand(requestFlags: [.highDataRate],
                              customCommandCode: 0xA1,
                              customRequestParameters: Data()) { response, error in
                if let error = error {
                    session.invalidate(errorMessage: "Fallo al leer patchInfo: \(error.localizedDescription)")
                    return
                }
                let patch = [UInt8](response)
                Task { @MainActor in
                    self.handle(uid: uid, patchInfo: patch)
                    session.alertMessage = "Listo ✅"
                    session.invalidate()
                }
            }
        }
    }

    // MARK: - Interpretación

    private func handle(uid: [UInt8], patchInfo: [UInt8]) {
        let uidHex = uid.map { String(format: "%02X", $0) }.joined(separator: " ")
        let uidRevHex = uid.reversed().map { String(format: "%02X", $0) }.joined(separator: " ")
        let patchHex = patchInfo.map { String(format: "%02X", $0) }.joined(separator: " ")

        let generation = Self.generation(patchInfo: patchInfo)
        let family = Self.family(patchInfo: patchInfo)
        let verdict: String
        switch generation {
        case "gen1":
            verdict = "gen1 → el camino directo Mac↔sensor por Bluetooth NO requiere la caja blanca. Posible."
        case "gen2":
            verdict = "gen2 → el desbloqueo usa la caja blanca de Abbott. Camino directo bloqueado."
        default:
            verdict = "No se pudo clasificar patchInfo[2]. Pasale estos bytes a Claude."
        }

        result = Result(uid: uidHex, uidReversed: uidRevHex, patchInfo: patchHex,
                        family: family, generation: generation, verdict: verdict)
        status = "Lectura completa."
    }

    /// Regla observada en la app de Abbott (área B, Evidence E01–E45):
    /// nibble alto de patchInfo[2] == 3 → bajo < 9 es gen1; else gen2.
    /// nibble alto == 7 → bajo < 4 es gen1; else gen2.
    static func generation(patchInfo: [UInt8]) -> String {
        guard patchInfo.count >= 3 else { return "desconocida" }
        let b = patchInfo[2]
        let hi = (b >> 4) & 0x0F
        let lo = b & 0x0F
        switch hi {
        case 3: return lo < 9 ? "gen1" : "gen2"
        case 7: return lo < 4 ? "gen1" : "gen2"
        default: return "desconocida"
        }
    }

    /// Interpretación TENTATIVA de patchInfo[0] (no afecta el veredicto gen).
    static func family(patchInfo: [UInt8]) -> String {
        guard let b = patchInfo.first else { return "?" }
        switch b {
        case 0xDF, 0xA2: return "Libre 1 (tentativo)"
        case 0xE5, 0xE6: return "Libre US 14d (tentativo)"
        case 0x9D, 0x76, 0xC5: return "Libre 2 (tentativo)"
        case 0xC6: return "Libre 2 Plus (tentativo)"
        default: return String(format: "patchInfo[0]=0x%02X (sin clasificar)", b)
        }
    }
}
