import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (fonte MIT: GrokCreditsProxyFetcher/GrokAuth)

enum GrokFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .grok, key: "local"), label: "local")
    static let host = "grokproxy.example.com"

    /// auth.json do CLI: mapa por scope — OIDC (SuperGrok) vence o legado.
    static let authJSON = """
    {
      "https://auth.x.ai::oidc": { "key": "fake-oidc-token", "email": "fake@example.com",
        "expires_at": "2030-01-01T00:00:00Z" },
      "https://accounts.x.ai/sign-in": { "key": "fake-legacy-token" }
    }
    """
    static let oidcExpiry = Date(timeIntervalSince1970: 1_893_456_000)  // 2030-01-01T00:00:00Z
    static let authLegacyOnly = """
    { "https://accounts.x.ai/sign-in": { "key": "fake-legacy-token" } }
    """
    static let authExpired = """
    { "https://auth.x.ai::oidc": { "key": "fake-oidc-token", "expires_at": "2001-01-01T00:00:00Z" } }
    """

    /// `creditUsagePercent` direto + currentPeriod end ISO8601.
    static let billingBody = """
    {"config":{"creditUsagePercent":62.5,"currentPeriod":{"end":"2027-01-17T00:00:00Z"},
               "subscriptionTier":"supergrok"},"subscriptionTier":"SuperGrok"}
    """

    /// Sem percent direto, mas com par on-demand cap/used (40 → 75%).
    static let billingOnDemandBody = """
    {"config":{"onDemandCap":{"val":40},"onDemandUsed":{"val":30},
               "billingPeriodEnd":"2027-01-17T00:00:00.000Z"}}
    """

    /// Sem percent calculável → contrato violado (rethrow).
    static let billingEmptyBody = #"{"config":{"subscriptionTier":"free"},"subscriptionTier":"free"}"#
}

// MARK: - Reader

@Suite
final class GrokCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ content: String) throws -> URL {
        let url = dir.appendingPathComponent("auth.json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func prefersOIDCScopeOverLegacy() throws {
        let credential = try #require(GrokCredentialReader.parse(Data(GrokFixtures.authJSON.utf8)))
        #expect(credential.accessToken == "fake-oidc-token", "OIDC (SuperGrok) vence o legado")
        #expect(credential.email == "fake@example.com")
        #expect(credential.expiresAt == GrokFixtures.oidcExpiry)

        let legacy = try #require(GrokCredentialReader.parse(Data(GrokFixtures.authLegacyOnly.utf8)))
        #expect(legacy.accessToken == "fake-legacy-token", "legado serve de fallback")
    }

    /// Entrada sem `key` não sombreia uma saudável; JSON inválido/token vazio → nil.
    @Test func invalidShapesYieldNil() throws {
        let shadowed = #"{"https://auth.x.ai::oidc":{},"https://accounts.x.ai/sign-in":{"key":"fake-legacy-token"}}"#
        #expect(GrokCredentialReader.parse(Data(shadowed.utf8))?.accessToken == "fake-legacy-token")
        #expect(GrokCredentialReader.parse(Data("not json".utf8)) == nil)
        #expect(GrokCredentialReader.parse(Data(#"{"scope":{"key":""}}"#.utf8)) == nil)
    }

    /// Conta registrada com token cru (uma linha) também é aceita.
    @Test func rawTokenFileAccepted() throws {
        let reader = GrokCredentialReader(authFileURL: try write("fake-raw-token\n"))
        #expect(reader.read()?.accessToken == "fake-raw-token")
    }

    @Test func resolveHonorsOverridesAndDefault() {
        #expect(
            GrokCredentialReader.resolve(environment: ["TOKENBAR_GROK_AUTH": "/tmp/fake/auth.json"], home: URL(filePath: "/Users/fake"))
                .authFileURL?.path == "/tmp/fake/auth.json")
        #expect(
            GrokCredentialReader.resolve(environment: ["GROK_HOME": "/tmp/grok-home"], home: URL(filePath: "/Users/fake"))
                .authFileURL?.path == "/tmp/grok-home/auth.json", "override GROK_HOME da referência")
        #expect(
            GrokCredentialReader.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
                .authFileURL?.path == "/Users/fake/.grok/auth.json")
    }
}

// MARK: - Provider

@Suite
final class GrokProviderBasicsTests {
    func makeProvider(auth: String? = nil) -> GrokProvider {
        GrokProvider(
            credentialReader: GrokCredentialReader(
                authFileURL: auth.map { URL(filePath: $0) }),
            client: UsageHTTPClient(baseURL: URL(string: "https://\(GrokFixtures.host)")!))
    }

    @Test func conformsToUsageProviderBasics() async {
        let provider = makeProvider(auth: "/tmp/fake-auth.json")
        #expect(provider.id == .grok)
        #expect(provider.capabilities == [.apiUsage, .multiAccount])
        // Arquivo inexistente → sem conta (degradação honesta).
        #expect(await provider.discoverAccounts() == [])
    }

    @Test func rejectsUnknownAccount() async {
        await #expect(throws: GrokProviderError.self) {
            try await makeProvider(auth: "/tmp/fake-auth.json")
                .fetchUsage(AccountRef(id: AccountID(provider: .grok, key: "outra"), label: "?"))
        }
    }
}

@Suite(.serialized)
final class GrokUsageAPITests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(auth: String) throws -> GrokProvider {
        let authURL = dir.appendingPathComponent("auth.json")
        try auth.write(to: authURL, atomically: true, encoding: .utf8)
        return GrokProvider(
            credentialReader: GrokCredentialReader(authFileURL: authURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(GrokFixtures.host)")!,
                session: f5StubbedSession()))
    }

    /// Contrato: GET `v1/billing?format=credits` com Bearer + header
    /// `x-xai-token-auth: xai-grok-cli` (proxy do CLI — caminho suportado da
    /// referência). Janela Plano com percent e reset.
    @Test func fetchUsageMapsBillingPercent() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(GrokFixtures.billingBody.utf8), error: nil)
        }, host: GrokFixtures.host)
        let provider = try makeProvider(auth: GrokFixtures.authJSON)

        let snapshot = try await provider.fetchUsage(GrokFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: GrokFixtures.host).count == 1)
        let request = try #require(F5StubURLProtocol.lastRequest(host: GrokFixtures.host))
        #expect(request.url?.absoluteString == "https://\(GrokFixtures.host)/v1/billing?format=credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-oidc-token")
        #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "Plano")
        #expect(snapshot.windows[0].usedFraction == 0.625)
        #expect(snapshot.windows[0].resetsAt == F5Fixtures.resetDate)
    }

    /// Sem creditUsagePercent → razão on-demand (30/40 = 75%); reset cai no
    /// billingPeriodEnd quando currentPeriod falta.
    @Test func onDemandFallbackMapping() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(GrokFixtures.billingOnDemandBody.utf8), error: nil)
        }, host: GrokFixtures.host)
        let snapshot = try await makeProvider(auth: GrokFixtures.authLegacyOnly)
            .fetchUsage(GrokFixtures.localRef)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows[0].usedFraction == 0.75)
        #expect(snapshot.windows[0].resetsAt == F5Fixtures.resetDate, "ISO com fração")
    }

    /// Sem percent calculável → erro tipado; 401 → `.invalid`.
    @Test func emptyBillingThrowsAnd401Degrades() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(GrokFixtures.billingEmptyBody.utf8), error: nil)
        }, host: GrokFixtures.host)
        await #expect(throws: GrokAPIError.self) {
            try await makeProvider(auth: GrokFixtures.authJSON).fetchUsage(GrokFixtures.localRef)
        }

        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 401, body: Data(), error: nil)
        }, host: GrokFixtures.host)
        let snapshot = try await makeProvider(auth: GrokFixtures.authJSON).fetchUsage(GrokFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .invalid)
    }

    /// Token vencido → `.invalid` sem request.
    @Test func expiredTokenDegradesWithoutRequest() async throws {
        F5StubURLProtocol.configure(nil, host: GrokFixtures.host)
        let snapshot = try await makeProvider(auth: GrokFixtures.authExpired)
            .fetchUsage(GrokFixtures.localRef)
        #expect(snapshot.authState == .invalid)
        #expect(snapshot.windows.isEmpty)
        #expect(F5StubURLProtocol.requests(host: GrokFixtures.host).isEmpty)
    }

    /// Sem credencial → `.missing` sem request; rede → rethrow.
    @Test func missingCredentialAndNetworkError() async throws {
        F5StubURLProtocol.configure(nil, host: GrokFixtures.host)
        let authURL = dir.appendingPathComponent("ausente.json")
        let provider = GrokProvider(
            credentialReader: GrokCredentialReader(authFileURL: authURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(GrokFixtures.host)")!,
                session: f5StubbedSession()))
        let snapshot = try await provider.fetchUsage(GrokFixtures.localRef)
        #expect(snapshot.authState == .missing)
        #expect(F5StubURLProtocol.requests(host: GrokFixtures.host).isEmpty)

        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }, host: GrokFixtures.host)
        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await makeProvider(auth: GrokFixtures.authJSON).fetchUsage(GrokFixtures.localRef)
        }
    }
}
