import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - URLProtocol stub compartilhado dos providers F5 (Tasks 4–5)
//
// Mesmo padrão de ZaiStubURLProtocol (spec F2): fixtures 100% sintéticas
// (`fake-*`, hosts `.example.com`), log de requests para contratos de
// autenticação/ordem. Compartilhado entre os 6 providers novos — o roteamento
// é POR HOST (`configure(_:host:)`), então suítes paralelas com hosts
// distintos não se contaminam (equivalente a um stub por suíte).

final class F5StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Exchange {
        var status: Int = 500
        var body: Data = Data()
        var error: URLError?
    }

    private final class StubState: @unchecked Sendable {
        let lock = NSLock()
        var handlers: [String: @Sendable (URLRequest) -> Exchange] = [:]
        var requests: [URLRequest] = []
    }

    private static let state = StubState()

    /// Requests gravados, filtráveis por host (cada suíte usa o seu).
    static func requests(host: String) -> [URLRequest] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requests.filter { $0.url?.host == host }
    }

    static func lastRequest(host: String) -> URLRequest? {
        requests(host: host).last
    }

    /// Registra o handler das requisições para UM host e zera o log dele.
    static func configure(_ handler: (@Sendable (URLRequest) -> Exchange)?, host: String) {
        state.lock.lock(); defer { state.lock.unlock() }
        if let handler {
            state.handlers[host] = handler
        } else {
            state.handlers.removeValue(forKey: host)
        }
        state.requests.removeAll { $0.url?.host == host }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        Self.state.lock.lock()
        // URLSession move o corpo para httpBodyStream no URLProtocol —
        // reconstruímos para o log e para os handlers verem o body.
        if body != nil, request.httpBody == nil {
            var mutable = request
            mutable.httpBody = body
            Self.state.requests.append(mutable)
        } else {
            Self.state.requests.append(request)
        }
        let host = request.url?.host ?? ""
        let handler = Self.state.handlers[host]
        Self.state.lock.unlock()

        let exchange = handler?(request) ?? Exchange(error: URLError(.unsupportedURL))
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: exchange.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Drena `httpBodyStream` (quando o `httpBody` foi consumido pela sessão).
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Fixtures JWT sintéticas (Cursor)

enum F5Fixtures {
    /// JWT de 3 segmentos com payload controlado (base64url SEM padding —
    /// formato real do `cursorAuth/accessToken`). `sub`/`email`/`exp` fakes.
    static func cursorJWT(sub: String = "auth0|user_fake123", exp: Double = 1_900_000_000) -> String {
        let header = base64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = base64url(Data(#"{"sub":"\#(sub)","email":"fake@example.com","exp":\#(exp)}"#.utf8))
        return "\(header).\(payload).fake-signature"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `Date(timeIntervalSince1970:)` do fixture ISO `2027-01-17T00:00:00Z`
    /// (sem fração — formato real que os payloads devolvem).
    static let resetDate = Date(timeIntervalSince1970: 1_800_144_000)
    static let resetISO = "2027-01-17T00:00:00Z"
}

/// URLSession com o stub registrado (mesmo padrão dos testes F2–F4).
func f5StubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [F5StubURLProtocol.self]
    return URLSession(configuration: configuration)
}
