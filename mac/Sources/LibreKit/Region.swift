import Foundation

/// Servidor regional de LibreLinkUp. El login contra cualquier región responde
/// con `redirect` + `region` si la cuenta vive en otra (Argentina → "la").
public struct Region: Hashable, Sendable, CustomStringConvertible {
    public let code: String

    /// Región por defecto para el primer login; el servidor redirige si hace falta.
    public static let global = Region(validatedCode: "us")

    /// Devuelve `nil` si el código no es un identificador de región plausible
    /// (evita armar hosts arbitrarios a partir de la respuesta del servidor).
    public init?(code: String) {
        let lower = code.lowercased()
        guard (2...4).contains(lower.count),
              lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        self.code = lower
    }

    private init(validatedCode: String) { code = validatedCode }

    public var baseURL: URL {
        switch code {
        case "us", "global": URL(string: "https://api.libreview.io")!
        case "ru": URL(string: "https://api.libreview.ru")!
        default: URL(string: "https://api-\(code).libreview.io")!
        }
    }

    public var description: String { code.uppercased() }
}
