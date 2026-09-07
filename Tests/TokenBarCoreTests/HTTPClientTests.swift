import Foundation
import Testing
@testable import TokenBarCore

/// Stub de URLSession via URLProtocol (spec F2 §5: testes de rede via stub,
/// fixtures 100% sintéticas). Handler estático → suíte `.serialized`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Exchange {
        var status: Int = 500
        var body: Data = Data()
        var error: URLError?
    }

    /// Estado mutável sob lock; exposto via `static let` (imutável) p/ Swift 6.
    private final class StubState: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Exchange)?
        var requestCount = 0
        var lastRequest: URLRequest?
    }

    private static let state = StubState()

    static var requestCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requestCount
    }

    static var lastRequest: URLRequest? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lastRequest
    }

    static func configure(_ handler: (@Sendable (URLRequest) -> Exchange)?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.handler = handler
        state.requestCount = 0
        state.lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.requestCount += 1
        Self.state.lastRequest = request
        let handler = Self.state.handler
        Self.state.lock.unlock()

        let exchange = handler?(request) ?? Exchange(error: URLError(.unsupportedURL))
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: exchange.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct HTTPClientTests {
    private typealias Exchange = StubURLProtocol.Exchange

    private let base = URL(string: "https://api.example.com/v1")!

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func getJSON200ReturnsBodyWithContractedHeaders() async throws {
        let body = Data(#"{"ok":true,"plan_type":"fake-plus"}"#.utf8)
        StubURLProtocol.configure { _ in
            Exchange(status: 200, body: body, error: nil)
        }
        let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

        let data = try await client.getJSON(path: "usage", bearer: "fake-token", headers: ["X-Fake-Header": "abc"])

        #expect(data == body)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 10, "timeout padrão do contrato: 10 s")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "cache desabilitado")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Fake-Header") == "abc", "headers extras passam")
    }

    @Test func getJSONJoinsNestedPath() async throws {
        StubURLProtocol.configure { _ in Exchange(status: 200, body: Data("{}".utf8), error: nil) }
        let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

        _ = try await client.getJSON(path: "api/monitor/usage/quota/limit", bearer: nil)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/api/monitor/usage/quota/limit")
    }

    @Test func customTimeoutIsAppliedToRequest() async throws {
        StubURLProtocol.configure { _ in Exchange(status: 200, body: Data("{}".utf8), error: nil) }
        let client = UsageHTTPClient(baseURL: base, timeout: .seconds(2), session: stubbedSession())

        _ = try await client.getJSON(path: "usage", bearer: nil)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.timeoutInterval == 2)
    }

    @Test func unauthorizedOn401And403() async throws {
        for status in [401, 403] {
            StubURLProtocol.configure { _ in Exchange(status: status, body: Data(), error: nil) }
            let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

            await #expect(throws: UsageHTTPError.unauthorized) {
                try await client.getJSON(path: "usage", bearer: "fake-token")
            }
        }
    }

    @Test func otherErrorStatusesMapToHTTP() async throws {
        for status in [404, 500] {
            StubURLProtocol.configure { _ in Exchange(status: status, body: Data(), error: nil) }
            let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

            await #expect(throws: UsageHTTPError.http(status: status)) {
                try await client.getJSON(path: "usage", bearer: nil)
            }
        }
    }

    @Test func networkErrorMapsToNetworkAndNeverRetries() async throws {
        StubURLProtocol.configure { _ in
            Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }
        let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await client.getJSON(path: "usage", bearer: "fake-token")
        }
        #expect(StubURLProtocol.requestCount == 1, "contrato: nunca retry interno")
    }

    @Test func malformedJSONOn200MapsToDecode() async throws {
        StubURLProtocol.configure { _ in
            Exchange(status: 200, body: Data("<html>not json</html>".utf8), error: nil)
        }
        let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

        do {
            _ = try await client.getJSON(path: "usage", bearer: nil)
            Issue.record("corpo não-JSON em 200 deveria virar .decode")
        } catch let error as UsageHTTPError {
            guard case .decode = error else {
                Issue.record("esperava .decode, veio \(error)")
                return
            }
        }
    }

    @Test func noAuthorizationHeaderWhenBearerIsNil() async throws {
        StubURLProtocol.configure { _ in Exchange(status: 200, body: Data("{}".utf8), error: nil) }
        let client = UsageHTTPClient(baseURL: base, session: stubbedSession())

        _ = try await client.getJSON(path: "usage", bearer: nil)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
