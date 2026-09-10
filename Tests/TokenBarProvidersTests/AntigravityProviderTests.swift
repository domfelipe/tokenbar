import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (fonte MIT: AntigravityRemoteUsageFetcher)

enum AntigravityFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .antigravity, key: "local"), label: "local")
    static let host = "cloudcode-pa.googleapis.com"

    static let oauthCreds = #"{"access_token":"fake-antigravity-token","refresh_token":"fake-refresh","project_id":"fake-project","expiry_date":1900000000}"#
    static let oauthCredsSnakeExpiryMS = #"{"accessToken":"fake-antigravity-token","expiry_date":1900000000000}"#
    static let oauthCredsExpired = #"{"access_token":"fake-antigravity-token","expiry_date":1000000000}"#

    /// Modelos com quota (remainingFraction + ISO8601 com fração) — a janela
    /// da UI é 1 − remaining.
    static let modelsBody = """
    {
      "models": {
        "gemini-3-pro": { "displayName": "Gemini 3 Pro",
          "quotaInfo": { "remainingFraction": 0.75, "resetTime": "2027-01-17T00:00:00Z" } },
        "claude-sonnet-4-6": { "label": "Sonnet 4.6",
          "quotaInfo": { "remainingFraction": 0.1, "resetTime": "2027-01-17T00:00:00.000Z" } },
        "sem-quota": { "displayName": "Sem quota" }
      }
    }
    """

    /// 200 sem nenhuma fração → contrato violado (rethrow).
    static let emptyModelsBody = #"{"models": { "m1": { "displayName": "M1" } }}"#
}

// MARK: - Reader

@Suite
final class AntigravityCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravityreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func parsesOAuthCredsShapes() throws {
        let credential = try #require(AntigravityCredentialReader.parse(Data(AntigravityFixtures.oauthCreds.utf8)))
        #expect(credential.accessToken == "fake-antigravity-token")
        #expect(credential.projectID == "fake-project")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))

        let camelMS = try #require(
            AntigravityCredentialReader.parse(Data(AntigravityFixtures.oauthCredsSnakeExpiryMS.utf8)))
        #expect(camelMS.projectID == nil, "project é opcional")
        #expect(camelMS.expiresAt == Date(timeIntervalSince1970: 1_900_000_000), "expiry em ms → ÷1000")
    }

    @Test func invalidAndMissingYieldNil() throws {
        #expect(AntigravityCredentialReader.parse(Data("not json".utf8)) == nil)
        #expect(AntigravityCredentialReader.parse(Data(#"{"refresh_token":"x"}"#.utf8)) == nil)
        #expect(try AntigravityCredentialReader(credentialsFileURL: write("ausente.json", "")).read() == nil)
    }

    @Test func resolveHonorsEnvOverrideAndDefault() {
        #expect(
            AntigravityCredentialReader.resolve(
                environment: ["TOKENBAR_ANTIGRAVITY_CREDS": "/tmp/fake/creds.json"],
                home: URL(filePath: "/Users/fake")).credentialsFileURL?.path == "/tmp/fake/creds.json")
        #expect(
            AntigravityCredentialReader.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
                .credentialsFileURL?.path == "/Users/fake/.codexbar/antigravity/oauth_creds.json",
            "mesmo caminho da referência")
    }
}

// MARK: - Provider

@Suite
final class AntigravityProviderBasicsTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravitybasic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(creds: String?) throws -> AntigravityProvider {
        let credsURL: URL?
        if let creds {
            credsURL = dir.appendingPathComponent("oauth_creds.json")
            try creds.write(to: credsURL!, atomically: true, encoding: .utf8)
        } else {
            credsURL = nil
        }
        return AntigravityProvider(
            credentialReader: AntigravityCredentialReader(credentialsFileURL: credsURL),
            client: UsageHTTPClient(baseURL: URL(string: "https://\(AntigravityFixtures.host)")!))
    }

    /// Sem credencial local (~/.codexbar ausente) o provider entra invisível
    /// (discoverAccounts []): degradação honesta da Task 5 — desabilitado até
    /// registrar conta, nunca erro.
    @Test func withoutCredentialProviderIsDisabled() async throws {
        let provider = try makeProvider(creds: nil)
        #expect(provider.id == .antigravity)
        #expect(provider.capabilities == [.apiUsage, .multiAccount])
        #expect(await provider.discoverAccounts() == [])

        let snapshot = try await provider.fetchUsage(AntigravityFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
        #expect(snapshot.windows.isEmpty)
    }

    @Test func rejectsUnknownAccount() async throws {
        let provider = try makeProvider(creds: AntigravityFixtures.oauthCreds)
        await #expect(throws: AntigravityProviderError.self) {
            try await provider.fetchUsage(AccountRef(id: AccountID(provider: .antigravity, key: "outra"), label: "?"))
        }
    }
}

@Suite(.serialized)
final class AntigravityUsageAPITests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravityapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(creds: String) throws -> AntigravityProvider {
        let credsURL = dir.appendingPathComponent("oauth_creds.json")
        try creds.write(to: credsURL, atomically: true, encoding: .utf8)
        return AntigravityProvider(
            credentialReader: AntigravityCredentialReader(credentialsFileURL: credsURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(AntigravityFixtures.host)")!,
                session: f5StubbedSession()))
    }

    /// Contrato: POST `v1internal:fetchAvailableModels` com Bearer, corpo
    /// `{"project": id}` quando o creds traz project_id, UA "antigravity".
    /// Janela por modelo com fração (1 − remaining), ordenada por label.
    @Test func fetchUsageMapsModelQuotasAndSendsContract() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AntigravityFixtures.modelsBody.utf8), error: nil)
        }, host: AntigravityFixtures.host)
        let provider = try makeProvider(creds: AntigravityFixtures.oauthCreds)

        let snapshot = try await provider.fetchUsage(AntigravityFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: AntigravityFixtures.host).count == 1)
        let request = try #require(F5StubURLProtocol.lastRequest(host: AntigravityFixtures.host))
        #expect(request.url?.absoluteString == "https://\(AntigravityFixtures.host)/v1internal:fetchAvailableModels")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-antigravity-token")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "antigravity")
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == #"{"project":"fake-project"}"#)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 2, "modelo sem quotaInfo não vira janela")

        // Ordenado por label: "Gemini 3 Pro" < "Sonnet 4.6".
        #expect(snapshot.windows[0].label == "Gemini 3 Pro")
        #expect(snapshot.windows[0].usedFraction == 0.25)
        #expect(snapshot.windows[0].resetsAt == F5Fixtures.resetDate)
        #expect(snapshot.windows[1].label == "Sonnet 4.6")
        #expect(snapshot.windows[1].usedFraction == 0.90)
        #expect(snapshot.windows[1].resetsAt == F5Fixtures.resetDate, "ISO8601 com fração")
    }

    /// Credencial SEM project → corpo `{}`.
    @Test func withoutProjectSendsEmptyBody() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AntigravityFixtures.modelsBody.utf8), error: nil)
        }, host: AntigravityFixtures.host)
        _ = try await makeProvider(creds: AntigravityFixtures.oauthCredsSnakeExpiryMS)
            .fetchUsage(AntigravityFixtures.localRef)
        let request = try #require(F5StubURLProtocol.lastRequest(host: AntigravityFixtures.host))
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == "{}")
    }

    /// Token vencido → `.invalid` SEM request (não há refresh read-only).
    @Test func expiredTokenDegradesWithoutRequest() async throws {
        F5StubURLProtocol.configure(nil, host: AntigravityFixtures.host)
        let snapshot = try await makeProvider(creds: AntigravityFixtures.oauthCredsExpired)
            .fetchUsage(AntigravityFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .invalid)
        #expect(snapshot.windows.isEmpty)
        #expect(F5StubURLProtocol.requests(host: AntigravityFixtures.host).isEmpty)
    }

    /// 401 → `.invalid`; payload sem fração → erro tipado (rethrow).
    @Test func unauthorizedDegradesAndEmptyModelsThrows() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 401, body: Data(), error: nil)
        }, host: AntigravityFixtures.host)
        let snapshot = try await makeProvider(creds: AntigravityFixtures.oauthCreds)
            .fetchUsage(AntigravityFixtures.localRef)
        #expect(snapshot.authState == .invalid)
        #expect(snapshot.windows.isEmpty)

        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AntigravityFixtures.emptyModelsBody.utf8), error: nil)
        }, host: AntigravityFixtures.host)
        await #expect(throws: AntigravityAPIError.self) {
            try await makeProvider(creds: AntigravityFixtures.oauthCreds).fetchUsage(AntigravityFixtures.localRef)
        }
    }

    /// Erro de rede → rethrow (backoff).
    @Test func networkErrorRethrows() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }, host: AntigravityFixtures.host)
        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await makeProvider(creds: AntigravityFixtures.oauthCreds).fetchUsage(AntigravityFixtures.localRef)
        }
    }
}
