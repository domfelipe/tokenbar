import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - URLProtocol stub (mesmo padrão de CodexProviderTests, com log de requests
// p/ verificar a ordem apiKey → OAuth da spec §2.2)

/// Fixtures 100% sintéticas (`fake-token`, hosts `.example.com`) — spec F2 §5.
final class ZaiStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Exchange {
        var status: Int = 500
        var body: Data = Data()
        var error: URLError?
    }

    private final class StubState: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Exchange)?
        var requests: [URLRequest] = []
    }

    private static let state = StubState()

    static var requests: [URLRequest] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requests
    }

    static var lastRequest: URLRequest? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requests.last
    }

    static func configure(_ handler: (@Sendable (URLRequest) -> Exchange)?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.handler = handler
        state.requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.requests.append(request)
        let handler = Self.state.handler
        Self.state.lock.unlock()

        let exchange = handler?(request) ?? Exchange(error: URLError(.unsupportedURL))
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: exchange.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures sintéticas (spec F2 §2.2 auth local / §2.3 shape quota/limit)

enum ZaiFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .zai, key: "local"), label: "local")

    // nextResetTime é epoch em MILISSEGUNDOS (spec §2.3) — pinados aqui
    // (÷1000 → segundos; mesmos instantes dos fixtures Codex, que usam s):
    //   1_800_086_400_000 ms → Date(timeIntervalSince1970: 1_800_086_400)
    //   1_800_003_600_000 ms → Date(timeIntervalSince1970: 1_800_003_600)
    //   1_800_000_000_000 ms → Date(timeIntervalSince1970: 1_800_000_000)
    //   1_800_060_000_000 ms → Date(timeIntervalSince1970: 1_800_060_000)

    /// Resposta `quota/limit` sintética cobrindo os 3 types e units 1/3/5/6
    /// (spec §2.3): TOKENS semanal 12%, TOKENS 5h 81% (o "Z:81%" do menu),
    /// TOKENS diário 44%, CREDIT diário 30% e o marcador MCP (TIME unit 5
    /// number 1 = janela mensal de 30 dias, NÃO "1 minuto").
    static let quotaBody = """
    {
      "success": true,
      "code": 200,
      "msg": "",
      "data": {
        "planName": "GLM Coding Plan",
        "limits": [
          { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 12,
            "usage": 100000, "currentValue": 12000, "remaining": 88000,
            "nextResetTime": 1800086400000,
            "usageDetails": [ { "modelCode": "glm-4.7", "usage": 8000 } ] },
          { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 81,
            "usage": 120000, "currentValue": 97200, "remaining": 22800,
            "nextResetTime": 1800003600000, "usageDetails": [] },
          { "type": "TOKENS_LIMIT", "unit": 1, "number": 1, "percentage": 44,
            "usage": 20000, "currentValue": 8800, "remaining": 11200,
            "nextResetTime": 1800000000000, "usageDetails": [] },
          { "type": "CREDIT_LIMIT", "unit": 1, "number": 1, "percentage": 30,
            "usage": 5000, "currentValue": 1500, "remaining": 3500,
            "nextResetTime": 1800000000000, "usageDetails": [] },
          { "type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 0,
            "usage": null, "currentValue": null, "remaining": null,
            "nextResetTime": 1800060000000,
            "usageDetails": [ { "modelCode": "glm-4.7-mcp", "usage": 3 } ] }
        ]
      }
    }
    """

    /// Tolerância de shape (spec §2.3/§2.7): type NOVO, unit NOVA, números como
    /// string, elemento não-objeto no array, limit sem percentage (não vira
    /// janela), TIME sem nextResetTime (resetsAt nil) — nada derruba o resto.
    static let quotaTolerantBody = """
    {
      "success": true,
      "code": 200,
      "data": {
        "planName": "GLM Coding Plan",
        "limits": [
          { "type": "SOMETHING_NEW", "unit": 9, "number": 1, "percentage": "25",
            "nextResetTime": "1800086400000" },
          { "type": "TOKENS_LIMIT", "unit": "3", "number": "5", "percentage": "105",
            "nextResetTime": 1800003600000 },
          { "type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 7 },
          "elemento-lixo-nao-objeto",
          { "type": "TOKENS_LIMIT", "unit": 3, "usage": 1000, "percentage": null }
        ]
      }
    }
    """

    /// Violação explícita do contrato `success === true && code === 200`.
    static let rejectedBody = #"{"success": false, "code": 403, "msg": "fake-rejection"}"#
    static let wrongCodeBody = #"{"success": true, "code": 500, "msg": ""}"#

    /// config.json sintético do ZCode (shape da spec §2.2 — chaves reais,
    /// valores fake).
    static func configJSON(entries: [String]) -> String {
        #"{"provider":{\#(entries.joined(separator: ","))}}"#
    }

    static func zaiEntry(
        apiKey: String? = "fake-api-key",
        baseURL: String? = "https://api.z.ai/api/anthropic"
    ) -> String {
        entry(key: "builtin:zai-coding-plan", apiKey: apiKey, baseURL: baseURL)
    }

    static func bigmodelEntry(
        apiKey: String? = "fake-cn-key",
        baseURL: String? = "https://open.bigmodel.cn/api/anthropic"
    ) -> String {
        entry(key: "builtin:bigmodel-coding-plan", apiKey: apiKey, baseURL: baseURL)
    }

    private static func entry(key: String, apiKey: String?, baseURL: String?) -> String {
        let parts = [
            apiKey.map { #""apiKey":"\#($0)""# },
            baseURL.map { #""baseURL":"\#($0)""# },
        ].compactMap { $0 }
        return #""\#(key)":{"options":{\#(parts.joined(separator: ","))}}"#
    }

    /// credentials.json plano (shape da spec §2.2, valores fake).
    static func credentialsJSON(token: String? = "fake-oauth-token") -> String {
        if let token {
            return #"{"oauth:zai:access_token":"\#(token)","oauth:zai:user_info":"fake-user-info","oauth:active_provider":"builtin:zai-coding-plan"}"#
        }
        return #"{"oauth:zai:user_info":"fake-user-info","oauth:active_provider":"builtin:zai-coding-plan"}"#
    }
}

// MARK: - ZaiCredentialReader

@Suite
final class ZaiCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zaireader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeReader(config: String?, credentials: String?) throws -> ZaiCredentialReader {
        let configURL: URL
        if let config {
            configURL = dir.appendingPathComponent("config.json")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } else {
            configURL = dir.appendingPathComponent("ausente-config.json")
        }
        let credentialsURL: URL
        if let credentials {
            credentialsURL = dir.appendingPathComponent("credentials.json")
            try credentials.write(to: credentialsURL, atomically: true, encoding: .utf8)
        } else {
            credentialsURL = dir.appendingPathComponent("ausente-credentials.json")
        }
        return ZaiCredentialReader(configFileURL: configURL, credentialsFileURL: credentialsURL)
    }

    @Test func readParsesAPIKeyAndRegionFromConfig() throws {
        let reader = try makeReader(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: nil
        )
        let credential = try #require(reader.read())
        #expect(credential.apiKey == "fake-api-key")
        #expect(credential.oauthToken == nil)
        #expect(credential.regionBaseURL == URL(string: "https://api.z.ai"))
        #expect(credential.hasCredential)
    }

    @Test func readFallsBackToOAuthTokenWithoutConfig() throws {
        let reader = try makeReader(config: nil, credentials: ZaiFixtures.credentialsJSON())
        let credential = try #require(reader.read())
        #expect(credential.apiKey == nil)
        #expect(credential.oauthToken == "fake-oauth-token")
        #expect(credential.regionBaseURL == nil)
        #expect(credential.hasCredential)
    }

    @Test func readCollectsAPIKeyAndOAuthTogether() throws {
        let reader = try makeReader(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )
        let credential = try #require(reader.read())
        #expect(credential.apiKey == "fake-api-key")
        #expect(credential.oauthToken == "fake-oauth-token")
        #expect(credential.regionBaseURL == URL(string: "https://api.z.ai"))
    }

    /// Região CN: entrada `builtin:bigmodel-coding-plan` com host
    /// `open.bigmodel.cn` → base canônica CN (spec §2.2/§2.7).
    @Test func bigmodelEntryAloneYieldsCNRegion() throws {
        let reader = try makeReader(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.bigmodelEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )
        let credential = try #require(reader.read())
        #expect(credential.apiKey == "fake-cn-key")
        #expect(credential.regionBaseURL == URL(string: "https://open.bigmodel.cn"))
    }

    /// Preferência da spec §2.2: `builtin:zai-coding-plan` (global) vence quando
    /// as duas entradas existem — chave e região saem da MESMA entrada.
    @Test func zaiEntryPreferredOverBigmodel() throws {
        let reader = try makeReader(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry(), ZaiFixtures.bigmodelEntry()]),
            credentials: nil
        )
        let credential = try #require(reader.read())
        #expect(credential.apiKey == "fake-api-key")
        #expect(credential.regionBaseURL == URL(string: "https://api.z.ai"))
    }

    /// Entrada sem apiKey ainda indica a região — pareia o fallback OAuth com
    /// o host certo (spec §2.7: região errada → 404/401).
    @Test func entryWithoutAPIKeyStillHintsRegionForOAuth() throws {
        let reader = try makeReader(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry(apiKey: nil)]),
            credentials: ZaiFixtures.credentialsJSON()
        )
        let credential = try #require(reader.read())
        #expect(credential.apiKey == nil)
        #expect(credential.oauthToken == "fake-oauth-token")
        #expect(credential.regionBaseURL == URL(string: "https://api.z.ai"))
    }

    /// Host desconhecido (proxy custom) → sem hint de região; default global vale.
    @Test func unknownBaseHostGivesNoRegionHint() throws {
        let reader = try makeReader(
            config: ZaiFixtures.configJSON(entries: [
                ZaiFixtures.zaiEntry(baseURL: "https://proxy.example.org/v1")
            ]),
            credentials: nil
        )
        let credential = try #require(reader.read())
        #expect(credential.regionBaseURL == nil)
    }

    @Test func missingFilesReturnNil() throws {
        let reader = try makeReader(config: nil, credentials: nil)
        #expect(reader.read() == nil)
    }

    @Test func malformedFilesReturnNil() throws {
        let reader = try makeReader(config: "not json {{{", credentials: "lixo")
        #expect(reader.read() == nil)
    }

    /// credentials.json sem a chave do token (só user_info) + config vazio →
    /// nada utilizável → nil (nenhuma conta visível).
    @Test func filesWithoutUsableKeysReturnNil() throws {
        let reader = try makeReader(
            config: #"{"provider":{}}"#,
            credentials: ZaiFixtures.credentialsJSON(token: nil)
        )
        #expect(reader.read() == nil)
    }

    @Test func resolveHonorsEnvOverridesAndDefaults() {
        let overridden = ZaiCredentialReader.resolve(
            environment: [
                "TOKENBAR_ZAI_CONFIG": "/tmp/fake/cfg.json",
                "TOKENBAR_ZAI_AUTH": "/tmp/fake/cred.json",
            ],
            home: URL(filePath: "/Users/fake")
        )
        #expect(overridden.configFileURL.path == "/tmp/fake/cfg.json")
        #expect(overridden.credentialsFileURL.path == "/tmp/fake/cred.json")

        let defaults = ZaiCredentialReader.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
        #expect(defaults.configFileURL.path == "/Users/fake/.zcode/v2/config.json")
        #expect(defaults.credentialsFileURL.path == "/Users/fake/.zcode/v2/credentials.json")
    }
}

// MARK: - ZaiProvider (identidade / resolve / degradação sem rede)

@Suite
final class ZaiProviderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zaiprovider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(config: String?, credentials: String?) throws -> ZaiProvider {
        let configURL: URL
        if let config {
            configURL = dir.appendingPathComponent("config.json")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } else {
            configURL = dir.appendingPathComponent("ausente-config.json")
        }
        let credentialsURL: URL
        if let credentials {
            credentialsURL = dir.appendingPathComponent("credentials.json")
            try credentials.write(to: credentialsURL, atomically: true, encoding: .utf8)
        } else {
            credentialsURL = dir.appendingPathComponent("ausente-credentials.json")
        }
        return ZaiProvider(
            credentialReader: ZaiCredentialReader(configFileURL: configURL, credentialsFileURL: credentialsURL),
            client: UsageHTTPClient(baseURL: URL(string: "https://zai.example.com")!)
        )
    }

    @Test func conformsToUsageProviderBasics() throws {
        let provider: any UsageProvider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )
        #expect(provider.id == .zai)
        #expect(provider.capabilities == [.apiUsage, .multiAccount], "API-only na F2 (spec §2.5); F4: contas com config registrado")
    }

    /// Ordem de base URL: env `TOKENBAR_ZAI_API` → hint de região (config.json,
    /// §2.2) → global canônica `https://api.z.ai` (§2.1).
    @Test func resolveBaseURLPrefersEnvThenRegionHintThenDefault() {
        let cn = URL(string: "https://open.bigmodel.cn")
        #expect(
            ZaiProvider.resolveBaseURL(environment: ["TOKENBAR_ZAI_API": "https://proxy.example.com"], regionHint: cn)
                == URL(string: "https://proxy.example.com")
        )
        #expect(ZaiProvider.resolveBaseURL(environment: [:], regionHint: cn) == cn)
        #expect(ZaiProvider.resolveBaseURL(environment: ["TOKENBAR_ZAI_API": ""], regionHint: cn) == cn)
        #expect(ZaiProvider.resolveBaseURL(environment: [:]) == URL(string: "https://api.z.ai"))
    }

    @Test func discoverAccountsRequiresCredential() async throws {
        let withCredential = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )
        #expect(await withCredential.discoverAccounts() == [ZaiFixtures.localRef])

        let oauthOnly = try makeProvider(config: nil, credentials: ZaiFixtures.credentialsJSON())
        #expect(await oauthOnly.discoverAccounts() == [ZaiFixtures.localRef], "OAuth sozinho já é conta")

        let withoutCredential = try makeProvider(config: nil, credentials: nil)
        #expect(await withoutCredential.discoverAccounts() == [])
    }

    /// Sem credencial (spec §2.6): snapshot VAZIO — Z.ai não tem ingest local,
    /// então não há janela nenhuma pra mostrar; `.missing` + `.localOnly`.
    @Test func fetchUsageWithoutCredentialReportsMissing() async throws {
        let provider = try makeProvider(config: nil, credentials: nil)

        let snapshot = try await provider.fetchUsage(ZaiFixtures.localRef)

        #expect(snapshot.provider == .zai)
        #expect(snapshot.account == ZaiFixtures.localRef.id)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.credits == nil)
    }

    @Test func fetchUsageRejectsUnknownAccount() async throws {
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )
        let stranger = AccountRef(id: AccountID(provider: .zai, key: "outra"), label: "?")
        await #expect(throws: ZaiProviderError.self) {
            try await provider.fetchUsage(stranger)
        }
    }
}

// MARK: - ZaiProvider usage API (via stub)

@Suite(.serialized)
final class ZaiUsageAPITests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zaiapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeProvider(config: String?, credentials: String?) throws -> ZaiProvider {
        let configURL: URL
        if let config {
            configURL = dir.appendingPathComponent("config.json")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } else {
            configURL = dir.appendingPathComponent("ausente-config.json")
        }
        let credentialsURL: URL
        if let credentials {
            credentialsURL = dir.appendingPathComponent("credentials.json")
            try credentials.write(to: credentialsURL, atomically: true, encoding: .utf8)
        } else {
            credentialsURL = dir.appendingPathComponent("ausente-credentials.json")
        }
        return ZaiProvider(
            credentialReader: ZaiCredentialReader(configFileURL: configURL, credentialsFileURL: credentialsURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://zai.example.com")!,
                session: stubbedSession()
            )
        )
    }

    func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZaiStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Shape da spec §2.3 mapeado por completo + contrato da requisição
    /// (URL canônica, Bearer = apiKey PRIMEIRO, User-Agent). Janelas na ordem
    /// da resposta; kind/label conforme decisão F2:
    ///   TOKENS u6 → .weekly "Semanal" · TOKENS u3 n5 → .session "5h" ·
    ///   TOKENS u1 → .session "1d" · CREDIT u1 → .daily "1d" ·
    ///   TIME u5 n1 → .daily "MCP" (marcador mensal de 30 dias, não "1 minuto").
    @Test func fetchUsageMapsQuotaShapeAndSendsContractedHeaders() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 200, body: Data(ZaiFixtures.quotaBody.utf8), error: nil)
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        let snapshot = try await provider.fetchUsage(ZaiFixtures.localRef)

        // Requisição: endpoint canônico + auth preferencial + UA da spec §2.1
        #expect(ZaiStubURLProtocol.requests.count == 1)
        let request = try #require(ZaiStubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://zai.example.com/api/monitor/usage/quota/limit")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-api-key", "apiKey é a ordem 1 (spec §2.2)")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("TokenBar/") == true)

        // Snapshot
        #expect(snapshot.provider == .zai)
        #expect(snapshot.account == AccountID(provider: .zai, key: "local"))
        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.credits == nil, "CREDIT_LIMIT é janela de plano, não saldo USD (spec §2.4)")
        #expect(snapshot.windows.count == 5)

        let weekly = snapshot.windows[0]
        #expect(weekly.kind == .weekly)
        #expect(weekly.label == "Semanal")
        #expect(weekly.usedFraction == 0.12)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_800_086_400), "nextResetTime epoch em MILISSEGUNDOS → ÷1000")

        let fiveHours = snapshot.windows[1]
        #expect(fiveHours.kind == .session)
        #expect(fiveHours.label == "5h")
        #expect(fiveHours.usedFraction == 0.81, "o percent exibido no menu (Z:81%) vem daqui")
        #expect(fiveHours.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))

        let dailyTokens = snapshot.windows[2]
        #expect(dailyTokens.kind == .session, "decisão F2: TOKENS → .session (refinamento só p/ unit 6)")
        #expect(dailyTokens.label == "1d")
        #expect(dailyTokens.usedFraction == 0.44)
        #expect(dailyTokens.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))

        let credit = snapshot.windows[3]
        #expect(credit.kind == .daily)
        #expect(credit.label == "1d")
        #expect(credit.usedFraction == 0.30)

        let mcp = snapshot.windows[4]
        #expect(mcp.kind == .daily)
        #expect(mcp.label == "MCP", "TIME unit=5 number=1 é o marcador MCP mensal (30d), não 1 minuto")
        #expect(mcp.usedFraction == 0.0)
        #expect(mcp.resetsAt == Date(timeIntervalSince1970: 1_800_060_000))
    }

    /// Caverna nº 1 da Task 5 (spec §2.2/§2.7): auth dual. apiKey rejeitada
    /// (401) → tenta o OAuth do coding plan no MESMO ciclo; não é retry do
    /// mesmo request — é a segunda credencial (máx. 2 requests).
    @Test func fetchUsageFallsBackToOAuthWhenAPIKeyRejected() async throws {
        ZaiStubURLProtocol.configure { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-api-key" {
                return ZaiStubURLProtocol.Exchange(status: 401, body: Data(), error: nil)
            }
            return ZaiStubURLProtocol.Exchange(status: 200, body: Data(ZaiFixtures.quotaBody.utf8), error: nil)
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        let snapshot = try await provider.fetchUsage(ZaiFixtures.localRef)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 5)

        let requests = ZaiStubURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fake-api-key")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fake-oauth-token", "fallback OAuth (spec §2.2)")
    }

    /// Só OAuth disponível (sem apiKey no config): request único, sem fallback.
    @Test func oauthOnlyCredentialMakesSingleRequest() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 200, body: Data(ZaiFixtures.quotaBody.utf8), error: nil)
        }
        let provider = try makeProvider(config: nil, credentials: ZaiFixtures.credentialsJSON())

        let snapshot = try await provider.fetchUsage(ZaiFixtures.localRef)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(ZaiStubURLProtocol.requests.count == 1)
        #expect(ZaiStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-oauth-token")
    }

    /// 401/403 com as duas credenciais → authState .invalid + snapshot
    /// degradado .localOnly (nunca erro; spec §2.6).
    @Test func fetchUsageDegradesOn401And403() async throws {
        for status in [401, 403] {
            ZaiStubURLProtocol.configure { _ in ZaiStubURLProtocol.Exchange(status: status, body: Data(), error: nil) }
            let provider = try makeProvider(
                config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
                credentials: ZaiFixtures.credentialsJSON()
            )

            let snapshot = try await provider.fetchUsage(ZaiFixtures.localRef)

            #expect(snapshot.source == .localOnly)
            #expect(snapshot.authState == .invalid)
            #expect(snapshot.windows.isEmpty, "sem ingest local não há janela local (spec §2.6: snapshot vazio)")
            #expect(snapshot.credits == nil)
            #expect(ZaiStubURLProtocol.requests.count == 2, "tentou as duas credenciais antes de degradar")
        }
    }

    /// `success === false` → erro TIPADO (nunca vira snapshot com dado).
    @Test func successFalseThrowsTypedError() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 200, body: Data(ZaiFixtures.rejectedBody.utf8), error: nil)
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        do {
            _ = try await provider.fetchUsage(ZaiFixtures.localRef)
            #expect(Bool(false), "success=false deveria lançar ZaiAPIStatusError")
        } catch let error as ZaiAPIStatusError {
            #expect(error.success == false)
            #expect(error.code == 403)
            #expect(error.msg == "fake-rejection")
        } catch {
            #expect(Bool(false), "erro deveria ser ZaiAPIStatusError, foi: \(error)")
        }
    }

    /// `success: true` com code != 200 TAMBÉM viola o contrato (spec §2.3:
    /// validação é success===true && code===200).
    @Test func successTrueWithNon200CodeThrowsTypedError() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 200, body: Data(ZaiFixtures.wrongCodeBody.utf8), error: nil)
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        do {
            _ = try await provider.fetchUsage(ZaiFixtures.localRef)
            #expect(Bool(false), "code != 200 deveria lançar ZaiAPIStatusError")
        } catch let error as ZaiAPIStatusError {
            #expect(error.success == true)
            #expect(error.code == 500)
        } catch {
            #expect(Bool(false), "erro deveria ser ZaiAPIStatusError, foi: \(error)")
        }
    }

    /// Erro de rede → rethrow (o AdaptiveScheduler trata backoff; spec §5 regra 3).
    @Test func networkErrorRethrows() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await provider.fetchUsage(ZaiFixtures.localRef)
        }
    }

    /// HTTP != 401/403 (ex. 500) → rethrow SEM fallback de credencial (500 é
    /// transiente e credential-agnóstico; só 401/403 dispara a 2ª credencial).
    @Test func serverErrorRethrowsWithoutCredentialFallback() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 500, body: Data(), error: nil)
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        await #expect(throws: UsageHTTPError.http(status: 500)) {
            try await provider.fetchUsage(ZaiFixtures.localRef)
        }
        #expect(ZaiStubURLProtocol.requests.count == 1, "sem retry/fallback em erro de servidor")
    }

    /// Decode tolerante (spec §2.3/§2.7): type novo → janela .daily com label
    /// cru; unit nova → .daily com label cru; números como string; fraction
    /// satura em 1.0; elemento não-objeto e limit sem percentage não derrubam
    /// nem viram janela; TIME sem nextResetTime → resetsAt nil. Nunca crash.
    @Test func fetchUsageToleratesNewTypesStringNumbersAndLossyEntries() async throws {
        ZaiStubURLProtocol.configure { _ in
            ZaiStubURLProtocol.Exchange(status: 200, body: Data(ZaiFixtures.quotaTolerantBody.utf8), error: nil)
        }
        let provider = try makeProvider(
            config: ZaiFixtures.configJSON(entries: [ZaiFixtures.zaiEntry()]),
            credentials: ZaiFixtures.credentialsJSON()
        )

        let snapshot = try await provider.fetchUsage(ZaiFixtures.localRef)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 3, "elemento lixo e limit sem percentage não viram janela")

        let unknownType = snapshot.windows[0]
        #expect(unknownType.kind == .daily, "type novo → .daily com label cru (decisão F2)")
        #expect(unknownType.label == "SOMETHING_NEW u9")
        #expect(unknownType.usedFraction == 0.25)
        #expect(unknownType.resetsAt == Date(timeIntervalSince1970: 1_800_086_400), "nextResetTime como string em ms também mapeia")

        let saturated = snapshot.windows[1]
        #expect(saturated.kind == .session, "unit como string \"3\" = 3 horas")
        #expect(saturated.label == "5h")
        #expect(saturated.usedFraction == 1.0, "percentage 105 satura em 0...1")

        let mcp = snapshot.windows[2]
        #expect(mcp.kind == .daily)
        #expect(mcp.label == "MCP")
        #expect(mcp.usedFraction == 0.07)
        #expect(mcp.resetsAt == nil, "sem nextResetTime → resetsAt nil, janela segue viva")
    }
}
