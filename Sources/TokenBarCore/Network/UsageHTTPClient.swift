import Foundation

/// Erro tipado da camada HTTP de usage (spec §5 regra 3).
/// 401/403 mapeiam para `.unauthorized`; nunca há retry interno.
/// `@unchecked Sendable` por causa do `any Error` de `.decode`.
public enum UsageHTTPError: Error, @unchecked Sendable, Equatable {
    case network(URLError)
    case http(status: Int)
    case decode(any Error)
    case unauthorized

    /// Igualdade por caso (payload de `.decode` não é comparável — basta o caso).
    public static func == (lhs: UsageHTTPError, rhs: UsageHTTPError) -> Bool {
        switch (lhs, rhs) {
        case (.network(let a), .network(let b)): return a.code == b.code
        case (.http(let a), .http(let b)): return a == b
        case (.decode, .decode): return true
        case (.unauthorized, .unauthorized): return true
        default: return false
        }
    }
}

/// Cliente HTTP GET-JSON para as APIs de usage (consumido pelas Tasks 4–5).
///
/// Contrato (spec §5 regra 3 / §7): uma única tentativa — nunca retry interno
/// (o backoff é do AdaptiveScheduler); timeout configurável (padrão 10 s);
/// cache desabilitado; erros tipados `UsageHTTPError`.
/// Segurança (spec §9): nenhuma credencial é logada — este arquivo não tem
/// print/log e nunca vai ter bearer ou headers em mensagem de erro.
public struct UsageHTTPClient: Sendable {
    public let baseURL: URL
    public let timeout: Duration

    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: base injetável (a default por provider é decisão das Tasks 4–5).
    ///   - timeout: limite da requisição (padrão do contrato: 10 s).
    ///   - session: URLSession injetável para testes via URLProtocol stub.
    public init(baseURL: URL, timeout: Duration = .seconds(10), session: URLSession = .shared) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.session = session
    }

    /// GET JSON com Authorization bearer opcional e headers extras.
    ///
    /// - Returns: corpo cru (`Data`) — o decode tipado é responsabilidade do
    ///   provider; aqui só se valida que o corpo de um 2xx é JSON válido.
    /// - Throws: `UsageHTTPError` (`.network` | `.http(status:)` | `.decode` | `.unauthorized`).
    public func getJSON(path: String, bearer: String?, headers: [String: String] = [:]) async throws -> Data {
        try await getJSON(url: baseURL.appending(path: path), bearer: bearer, headers: headers)
    }

    /// Variante por URL ABSOLUTA — para endpoints com query string na própria
    /// URI (F5: Alibaba `data/api.json?action=...`, Grok `billing?format=...`),
    /// onde `appending(path:)` percent-encodaria `?`/`&` e quebraria a rota.
    public func getJSON(url: URL, bearer: String?, headers: [String: String] = [:]) async throws -> Data {
        try await run(request(url: url, method: "GET", bearer: bearer, headers: headers, body: nil, contentType: nil))
    }

    /// POST com corpo cru (F5 Tasks 4–5: Alibaba/Antigravity exigem POST;
    /// contrato de erro e single-attempt idênticos ao GET — nunca retry).
    public func postJSON(
        path: String, bearer: String?, headers: [String: String] = [:],
        body: Data, contentType: String = "application/json") async throws -> Data
    {
        try await postJSON(url: baseURL.appending(path: path), bearer: bearer, headers: headers, body: body, contentType: contentType)
    }

    /// Variante por URL ABSOLUTA do POST (mesma razão do `getJSON(url:)`).
    public func postJSON(
        url: URL, bearer: String?, headers: [String: String] = [:],
        body: Data, contentType: String = "application/json") async throws -> Data
    {
        try await run(request(url: url, method: "POST", bearer: bearer, headers: headers, body: body, contentType: contentType))
    }

    private func request(
        url: URL, method: String, bearer: String?, headers: [String: String],
        body: Data?, contentType: String?) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeoutIntervalSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        return request
    }

    /// Uma única tentativa (spec §5 regra 3): mapeia transporte/HTTP, valida
    /// JSON do corpo 2xx e devolve os bytes — sem retry interno.
    private func run(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UsageHTTPError.network(error)
        } catch {
            throw UsageHTTPError.network(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error]))
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageHTTPError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw UsageHTTPError.unauthorized
        default:
            throw UsageHTTPError.http(status: http.statusCode)
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageHTTPError.decode(error)
        }
        return data
    }

    private var timeoutIntervalSeconds: TimeInterval {
        let components = timeout.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
