import AppKit
import LibreKit
import SwiftUI

/// Lo que se ve arriba a la derecha. Sin problemas: valor + flecha en monocromo
/// (se adapta a barra clara/oscura). Con un problema: ícono del problema y color.
struct MenuBarLabel: View {
    let store: GlucoseStore

    var body: some View {
        Image(nsImage: Self.render(symbol: symbol, text: text, color: color))
            .accessibilityLabel(accessibilityText)
    }

    private var worst: GlucoseCondition? { store.conditions.first }

    private var text: String {
        if store.phase == .needsLogin { return "LibreLink" }
        guard let reading = store.freshReading else { return "––" }
        return "\(store.display.unit.reading(reading.mgdL)) \(reading.trend?.arrow ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    private var symbol: String? {
        if store.phase == .loading { return "arrow.triangle.2.circlepath" }
        return worst?.symbolName
    }

    private var color: NSColor? {
        guard let worst else { return nil }
        switch worst {
        case .urgentLow, .low: return .systemRed
        case .high: return .systemOrange
        default: return worst.severity >= .warning ? .systemOrange : nil
        }
    }

    private var accessibilityText: String {
        ([text] + store.conditions.map(\.title)).joined(separator: ", ")
    }

    /// Dibuja ícono + texto en una imagen. Sin color → plantilla (monocroma).
    static func render(symbol: String?, text: String, color: NSColor?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let tint = color ?? .black
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: tint])

        var icon: NSImage?
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                // Teñir conservando los huecos del símbolo (la flecha dentro del círculo, el "!").
                icon = NSImage(size: base.size, flipped: false) { rect in
                    base.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
            }
        }

        let spacing: CGFloat = icon == nil ? 0 : 3
        let textSize = attributed.size()
        let iconSize = icon?.size ?? .zero
        let height = max(18, ceil(max(textSize.height, iconSize.height)))
        let size = NSSize(width: ceil(iconSize.width + spacing + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            }
            attributed.draw(at: NSPoint(x: iconSize.width + spacing, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}
