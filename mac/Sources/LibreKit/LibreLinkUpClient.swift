import CryptoKit
import Foundation

public enum LibreLinkUpError: Error, Equatable, LocalizedError {
    case invalidCredentials(String?)
    case mustAcceptTerms
    case mustAcceptPrivacyPolicy
    case mustVerifyEmail
    case unsupportedLoginStep(String)
    case badRedirect(String?)
    case tooManyRedirects
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let message):
            "Email o contraseña incorrectos" + (message.map { " (\($0))" } ?? "")
        case .mustAcceptTerms:
            "Tenés que aceptar los términos de uso en la app LibreLinkUp del teléfono."
        case .mustAcceptPrivacyPolicy:
            "Tenés que aceptar la política de privacidad en la app LibreLinkUp del teléfono."
        case .mustVerifyEmail:
            "Tenés que verificar el email de la cuenta LibreLinkUp."
        case .unsupportedLoginStep(let step):
            "LibreLinkUp pide un paso extra (\(step)); completalo en la app LibreLinkUp."
        case .badRedirect(let region):
            "Redirección a una región desconocida: \(region ?? "nil")"
        case .tooManyRedirects:
            "Demasiadas redirecciones de región."
        case .rateLimited(let retryAfter):
            "Demasiados pedidos a LibreLinkUp" + (retryAfter.map { "; reintentar en \(Int($0)) s" } ?? "")
        case .http(let code):
            "Error HTTP \(code) de LibreLinkUp."
        case .unexpectedResponse:
            "Respuesta inesperada de LibreLinkUp."
        }
    }
}

/// Cliente mínimo de la API de LibreLinkUp (la que usa la app de seguidores).
/// Se loguea solo cuando hace falta y reintenta una vez ante un 401.
public actor LibreLinkUpClient {
    /// Versión de la app que se anuncia; la API rechaza versiones viejas.
    public static let appVersion = "4.16.0"

    private let email: String
    private let password: String
    private let session: URLSession
    public private(set) var region: Region

    private var token: String?
    private var tokenExpiry: Date?
    private var accountIDHash: String?

    public init(email: String, password: String, region: Region = .global, session: URLSession = .shared) {
        self.email = email
        self.password = password
        self.region = region
        self.session = session
    }

    // MARK: API pública

    public func login() async throws {
        var redirects = 0
        while true {
            let body = try JSONEncoder().encode(["email": email, "password": password])
            let data = try await send(path: "/llu/auth/login", method: "POST", body: body, authenticated: false)
            switch try Self.interpretLogin(data) {
            case .redirect(let newRegion):
                redirects += 1
                guard redirects <= 2 else { throw LibreLinkUpError.tooManyRedirects }
                region = newRegion
            case .success(let ticket, let userID):
                token = ticket.token
                tokenExpiry = ticket.expires.map { Date(timeIntervalSince1970: $0) }
                accountIDHash = Self.sha256Hex(userID)
                return
            }
        }
    }

    public func patients() async throws -> [Patient] {
        let data = try await authorizedGET("/llu/connections")
        return try Self.decodePatients(data)
    }

    /// Medición actual (con tendencia) + ~12 h de historial.
    public func graph(patientID: String) async throws -> GraphResult {
        let encoded = patientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? patientID
        let data = try await authorizedGET("/llu/connections/\(encoded)/graph")
        return try Self.decodeGraph(data)
    }

    // MARK: Decodificación (estática para poder testearla con fixtures)

    enum LoginOutcome {
        case redirect(Region)
        case success(AuthTicket, userID: String)
    }

    static func interpretLogin(_ data: Data) throws -> LoginOutcome {
        let envelope: LoginEnvelope
        do { envelope = try JSONDecoder().decode(LoginEnvelope.self, from: data) }
        catch { throw LibreLinkUpError.unexpectedResponse }

        if let payload = envelope.data {
            if payload.redirect == true {
                guard let code = payload.region, let region = Region(code: code) else {
                    throw LibreLinkUpError.badRedirect(payload.region)
                }
                return .redirect(region)
            }
            if let step = payload.step?.type {
                switch step {
                case "tou": throw LibreLinkUpError.mustAcceptTerms
                case "pp": throw LibreLinkUpError.mustAcceptPrivacyPolicy
                case "verifyEmail": throw LibreLinkUpError.mustVerifyEmail
                default: throw LibreLinkUpError.unsupportedLoginStep(step)
                }
            }
            if let ticket = payload.authTicket, let user = payload.user, !ticket.token.isEmpty {
                return .success(ticket, userID: user.id)
            }
        }
        throw LibreLinkUpError.invalidCredentials(envelope.error?.message)
    }

    static func decodePatients(_ data: Data) throws -> [Patient] {
        do {
            return try JSONDecoder().decode(ConnectionsEnvelope.self, from: data).data.map {
                Patient(id: $0.patientId, firstName: $0.firstName ?? "", lastName: $0.lastName ?? "")
            }
        } catch {
            throw LibreLinkUpError.unexpectedResponse
        }
    }

    static func decodeGraph(_ data: Data) throws -> GraphResult {
        let envelope: GraphEnvelope
        do { envelope = try JSONDecoder().decode(GraphEnvelope.self, from: data) }
        catch { throw LibreLinkUpError.unexpectedResponse }
        let history = (envelope.data.graphData ?? [])
            .compactMap { $0.measurement() }
            .sorted { $0.date < $1.date }
        return GraphResult(
            current: envelope.data.connection?.glucoseMeasurement?.measurement(),
            history: history,
            sensor: envelope.data.connection?.sensor?.info()
        )
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: HTTP

    private func authorizedGET(_ path: String) async throws -> Data {
        if token == nil || (tokenExpiry.map { $0 < Date().addingTimeInterval(60) } ?? false) {
            try await login()
        }
        do {
            return try await send(path: path, method: "GET", body: nil, authenticated: true)
        } catch LibreLinkUpError.http(401) {
            token = nil
            try await login()
            return try await send(path: path, method: "GET", body: nil, authenticated: true)
        }
    }

    private func send(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        var request = URLRequest(url: region.baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("no-cache", forHTTPHeaderField: "cache-control")
        request.setValue("llu.android", forHTTPHeaderField: "product")
        request.setValue(Self.appVersion, forHTTPHeaderField: "version")
        if authenticated {
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
            if let accountIDHash { request.setValue(accountIDHash, forHTTPHeaderField: "account-id") }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LibreLinkUpError.unexpectedResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw LibreLinkUpError.rateLimited(retryAfter: retryAfter)
        default:
            throw LibreLinkUpError.http(http.statusCode)
        }
    }
}
