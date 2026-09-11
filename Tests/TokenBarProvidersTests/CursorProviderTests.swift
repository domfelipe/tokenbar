import Foundation
import SQLite3
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (fonte MIT: CursorStatusProbe/CursorAppAuth)

enum CursorFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .cursor, key: "local"), label: "local")

    /// Payload Pro com percentuais explícitos + on-demand em centavos
    /// (unidades da referência: 2500 = $25.00).
    static let summaryBody = """
    {
      "billingCycleStart": "2027-01-01T00:00:00Z",
      "billingCycleEnd": "2027-01-17T00:00:00Z",
      "membershipType": "pro",
      "individualUsage": {
        "plan": {
          "enabled": true,
          "used": 3058, "limit": 20000, "remaining": 16942,
          "autoPercentUsed": 30.5, "apiPercentUsed": 11.5, "totalPercentUsed": 21.0
        },
        "onDemand": { "enabled": true, "used": 2500, "limit": 10000, "remaining": 7500 }
      }
    }
    """

    /// Enterprise: sem `plan` — percent cai na razão do bloco `overall`
    /// (cap individual em centavos); sem datas de ciclo.
    static let enterpriseBody = """
    {
      "membershipType": "enterprise",
      "individualUsage": {
        "overall": { "used": 10000, "limit": 40000 }
      }
    }
    """

    /// Sem base de percent nenhuma (payload hostil/vazio): nenhuma janela —
    /// nada inventado.
    static let emptyBody = #"{"membershipType": "hobby"}"#
}

// MARK: - CursorCredentialReader

@Suite(.serialized)
final class CursorCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursorreader-\(UUID().uuidString)", isDirectory: true)
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

    @Test func readsRawJWTTokenFileAndBuildsCookie() throws {
        let jwt = F5Fixtures.cursorJWT()
        let url = try write("token.txt", jwt + "\n")
        let credential = try #require(CursorCredentialReader.readTokenFile(at: url))
        #expect(credential.userID == "user_fake123")
        #expect(credential.cookieHeader == "WorkosCursorSessionToken=user_fake123%3A%3A\(jwt)")
    }

    @Test func readsCookieHeaderFileAsIs() throws {
        let jwt = F5Fixtures.cursorJWT(sub: "auth0|user_cookie")
        let cookie = "WorkosCursorSessionToken=user_cookie%3A%3A\(jwt)"
        let url = try write("cookie.txt", cookie)
        let credential = try #require(CursorCredentialReader.readTokenFile(at: url))
        #expect(credential.cookieHeader == cookie)
        #expect(credential.userID == "user_cookie")
    }

    /// `exp` no passado → sem credencial (referência `isUsable`: evita 401
    /// garantido; o relogin resolve, não inventamos renovação).
    @Test func expiredTokenIsNotUsable() throws {
        let expired = F5Fixtures.cursorJWT(exp: 1_000_000_000)
        let url = try write("expired.txt", expired)
        #expect(CursorCredentialReader.readTokenFile(at: url) == nil)
    }

    /// `sub` hostil (userID com caractere fora de [A-Za-z0-9._-], ou sem
    /// userID após o `|`) → nil (guard anti-injeção de header da referência).
    @Test func hostileSubjectRejected() throws {
        for sub in ["weird|user;rm"] {
            let url = try write("hostile.txt", F5Fixtures.cursorJWT(sub: sub))
            #expect(CursorCredentialReader.readTokenFile(at: url) == nil, "sub=\(sub)")
        }
    }

    @Test func nonJWTContentRejected() throws {
        let url = try write("garbage.txt", "not-a-jwt")
        #expect(CursorCredentialReader.readTokenFile(at: url) == nil)
    }

    /// Fixture real de SQLite: `ItemTable(key, value)` com o access token —
    /// lido READONLY (nunca escrito).
    @Test func readsAccessTokenFromAppDatabase() throws {
        let dbURL = dir.appendingPathComponent("state.vscdb")
        try Self.makeStateVSCDB(at: dbURL, accessToken: F5Fixtures.cursorJWT(sub: "auth0|user_db"))
        let credential = try #require(CursorCredentialReader.readAppDatabase(at: dbURL))
        #expect(credential.userID == "user_db")
        #expect(credential.cookieHeader.contains("WorkosCursorSessionToken=user_db%3A%3AeyJ"))
    }

    @Test func missingOrInvalidDatabaseYieldsNil() throws {
        #expect(CursorCredentialReader.readAppDatabase(at: dir.appendingPathComponent("ausente.db")) == nil)
        let garbage = try write("garbage.db", "not a database")
        #expect(CursorCredentialReader.readAppDatabase(at: garbage) == nil)
        let empty = dir.appendingPathComponent("empty.vscdb")
        try Self.makeStateVSCDB(at: empty, accessToken: nil)
        #expect(CursorCredentialReader.readAppDatabase(at: empty) == nil)
    }

    @Test func resolveHonorsEnvOverrideAndDefault() {
        let overridden = CursorCredentialReader.resolve(
            environment: ["TOKENBAR_CURSOR_DB": "/tmp/fake/state.vscdb"],
            home: URL(filePath: "/Users/fake"))
        #expect(overridden.databaseFileURL?.path == "/tmp/fake/state.vscdb")

        let defaults = CursorCredentialReader.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
        #expect(defaults.databaseFileURL?.path == "/Users/fake/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Cria um SQLite mínimo com o schema da ItemTable do VS Code/Cursor.
    static func makeStateVSCDB(at url: URL, accessToken: String?) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let accessToken else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?);", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, accessToken, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - CursorProvider (identidade / degradação sem rede)

@Suite(.serialized)
final class CursorProviderBasicsTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursorbasic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(token: String?, accounts: AccountRegistry? = nil) throws -> CursorProvider {
        let tokenURL: URL?
        if let token {
            tokenURL = dir.appendingPathComponent("token.txt")
            try token.write(to: tokenURL!, atomically: true, encoding: .utf8)
        } else {
            tokenURL = nil
        }
        return CursorProvider(
            credentialReader: CursorCredentialReader(databaseFileURL: nil, tokenFileURL: tokenURL),
            client: UsageHTTPClient(baseURL: URL(string: "https://cursor.example.com")!),
            accounts: accounts)
    }

    @Test func conformsToUsageProviderBasics() async throws {
        let provider: any UsageProvider = try makeProvider(token: F5Fixtures.cursorJWT())
        #expect(provider.id == .cursor)
        #expect(provider.capabilities == [.apiUsage, .multiAccount])
        #expect(await provider.discoverAccounts() == [CursorFixtures.localRef])
    }

    @Test func discoverAccountsWithoutCredentialIsEmpty() async throws {
        let provider = try makeProvider(token: nil)
        #expect(await provider.discoverAccounts() == [])
    }

    @Test func resolveBaseURLEnvThenDefault() {
        #expect(
            CursorProvider.resolveBaseURL(environment: ["TOKENBAR_CURSOR_API": "https://proxy.example.com"])
                == URL(string: "https://proxy.example.com"))
        #expect(CursorProvider.resolveBaseURL(environment: [:]) == URL(string: "https://cursor.com"))
    }

    @Test func ingestLocalIsNoOpWithoutEvents() async throws {
        let provider = try makeProvider(token: F5Fixtures.cursorJWT())
        let batch = try await provider.ingestLocal(CursorFixtures.localRef, from: IngestCursor())
        #expect(batch.eventsApplied == 0)
        #expect(batch.providerTotals.isEmpty)
    }

    /// Cadeia de precedência do percent (referência `parseUsageSummary`),
    /// testada por pares (payload → fração esperada).
    @Test func planPercentPrecedenceChain() throws {
        func decode(_ body: String) throws -> CursorUsageSummaryResponse {
            try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: Data(body.utf8))
        }
        let pro = try decode(CursorFixtures.summaryBody)
        #expect(CursorProvider.planPercent(from: pro) == 0.21, "totalPercentUsed vence todas")

        let enterprise = try decode(CursorFixtures.enterpriseBody)
        #expect(CursorProvider.planPercent(from: enterprise) == 0.25, "overall 10000/40000")

        let empty = try decode(CursorFixtures.emptyBody)
        #expect(CursorProvider.planPercent(from: empty) == nil, "sem base → sem janela")

        let lanes = try decode(#"{"individualUsage":{"plan":{"autoPercentUsed":40,"apiPercentUsed":20}}}"#)
        #expect(CursorProvider.planPercent(from: lanes) == 0.30, "média das lanes")

        let cents = try decode(#"{"individualUsage":{"plan":{"used":7384,"limit":10000}}}"#)
        #expect(CursorProvider.planPercent(from: cents) == 0.7384, "razão em centavos")
    }
}

// MARK: - CursorProvider usage API (via stub)

@Suite(.serialized)
final class CursorUsageAPITests {
    static let host = "cursor.example.com"
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursorapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(token: String?) throws -> CursorProvider {
        let tokenURL: URL?
        if let token {
            tokenURL = dir.appendingPathComponent("token.txt")
            try token.write(to: tokenURL!, atomically: true, encoding: .utf8)
        } else {
            tokenURL = nil
        }
        return CursorProvider(
            credentialReader: CursorCredentialReader(databaseFileURL: nil, tokenFileURL: tokenURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://cursor.example.com")!,
                session: f5StubbedSession()))
    }

    /// Contrato da requisição (cookie, sem Bearer) + snapshot Pro completo.
    @Test func fetchUsageMapsProSummaryAndSendsCookie() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(CursorFixtures.summaryBody.utf8), error: nil)
        }, host: Self.host)
        let provider = try makeProvider(token: F5Fixtures.cursorJWT())

        let snapshot = try await provider.fetchUsage(CursorFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: Self.host).count == 1)
        let request = try #require(F5StubURLProtocol.lastRequest(host: Self.host))
        #expect(request.url?.absoluteString == "https://cursor.example.com/api/usage-summary")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=user_fake123%3A%3A") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "auth é cookie de sessão, não Bearer")

        #expect(snapshot.provider == .cursor)
        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 2)

        let plan = snapshot.windows[0]
        #expect(plan.label == "Plano")
        #expect(plan.usedFraction == 0.21)
        #expect(plan.resetsAt == F5Fixtures.resetDate, "billingCycleEnd ISO8601 → resetsAt")

        let onDemand = snapshot.windows[1]
        #expect(onDemand.label == "On-demand")
        #expect(onDemand.usedFraction == 0.25, "2500/10000 centavos")
        #expect(onDemand.resetsAt == F5Fixtures.resetDate)
    }

    /// Enterprise: percent vem do bloco `overall`; sem datas de ciclo →
    /// resetsAt nil.
    @Test func fetchUsageEnterpriseOverallFallback() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(CursorFixtures.enterpriseBody.utf8), error: nil)
        }, host: Self.host)
        let provider = try makeProvider(token: F5Fixtures.cursorJWT())

        let snapshot = try await provider.fetchUsage(CursorFixtures.localRef)

        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].usedFraction == 0.25)
        #expect(snapshot.windows[0].resetsAt == nil)
    }

    /// Payload sem base de percent → nenhuma janela (nunca 0% inventado).
    @Test func fetchUsageEmptyPayloadYieldsNoWindows() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(CursorFixtures.emptyBody.utf8), error: nil)
        }, host: Self.host)
        let provider = try makeProvider(token: F5Fixtures.cursorJWT())
        let snapshot = try await provider.fetchUsage(CursorFixtures.localRef)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.isEmpty)
    }

    /// 401/403 → `.invalid` + snapshot vazio (nunca erro na barra).
    @Test func fetchUsageDegradesOn401And403() async throws {
        for status in [401, 403] {
            F5StubURLProtocol.configure({ _ in F5StubURLProtocol.Exchange(status: status, body: Data(), error: nil) }, host: Self.host)
            let provider = try makeProvider(token: F5Fixtures.cursorJWT())
            let snapshot = try await provider.fetchUsage(CursorFixtures.localRef)
            #expect(snapshot.source == .localOnly)
            #expect(snapshot.authState == .invalid)
            #expect(snapshot.windows.isEmpty)
        }
    }

    /// Sem credencial → `.missing` sem request nenhum.
    @Test func fetchUsageWithoutCredentialReportsMissing() async throws {
        F5StubURLProtocol.configure(nil, host: Self.host)
        let provider = try makeProvider(token: nil)
        let snapshot = try await provider.fetchUsage(CursorFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
        #expect(snapshot.windows.isEmpty)
        #expect(F5StubURLProtocol.requests(host: Self.host).isEmpty)
    }

    @Test func fetchUsageRejectsUnknownAccount() async throws {
        let provider = try makeProvider(token: F5Fixtures.cursorJWT())
        let stranger = AccountRef(id: AccountID(provider: .cursor, key: "outra"), label: "?")
        await #expect(throws: CursorProviderError.self) {
            try await provider.fetchUsage(stranger)
        }
    }

    /// Erro de rede → rethrow (backoff do scheduler; spec §5 regra 3).
    @Test func networkErrorRethrows() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }, host: Self.host)
        let provider = try makeProvider(token: F5Fixtures.cursorJWT())
        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await provider.fetchUsage(CursorFixtures.localRef)
        }
    }
}
