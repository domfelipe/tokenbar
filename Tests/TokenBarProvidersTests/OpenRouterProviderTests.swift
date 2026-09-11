import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (fonte MIT: plugin openrouter.js)

enum OpenRouterFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .openrouter, key: "local"), label: "local")

    /// `/credits`: total adicionado 100.00, usado 37.20 → saldo 62.80.
    static let creditsBody = #"{"data":{"total_credits":100.00,"total_usage":37.20}}"#

    /// `/key`: limit 50, limit_remaining 25.50 → uso 24.50 → 49%.
    static let keyBody = """
    {"data":{"limit":50,"limit_remaining":25.5,"usage":37.2,"usage_daily":1.5,
             "usage_weekly":8.25,"usage_monthly":30.0,"limit_reset":"monthly",
             "rate_limit":{"requests":1000,"interval":"10s"}}}
    """

    /// `/key` sem limit (cap não configurado) → nenhuma janela (referência:
    /// "No limit configured" — não há percent a calcular).
    static let keyNoLimitBody = #"{"data":{"limit":null,"usage":12.0,"limit_reset":null}}"#

    /// Saldo com clamping: remaining acima do limit → 0% usado (não fração
    /// negativa); remaining negativo satura o uso no limit → 100%.
    static let keyClampAboveBody = #"{"data":{"limit":10,"limit_remaining":99}}"#
    static let keyClampBelowBody = #"{"data":{"limit":10,"limit_remaining":-5}}"#

    /// `limit_reset` escolhe a janela de uso quando `limit_remaining` falta.
    static let keyWeeklyBody = #"{"data":{"limit":40,"usage":4,"usage_weekly":10,"limit_reset":"weekly"}}"#
    static let keyUsageFallbackBody = #"{"data":{"limit":40,"usage":13,"limit_reset":"daily"}}"#
}

// MARK: - OpenRouterCredentialReader

@Suite(.serialized)
final class OpenRouterCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ content: String) throws -> URL {
        let url = dir.appendingPathComponent("key.txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsKeyFileTrimmedAndUnquoted() throws {
        #expect(try OpenRouterCredentialReader.readKeyFile(at: write("fake-or-key\n")) == "fake-or-key")
        #expect(try OpenRouterCredentialReader.readKeyFile(at: write("  \"fake-or-key\"\n")) == "fake-or-key")
    }

    @Test func envFallbackAndMissing() throws {
        #expect(
            OpenRouterCredentialReader(environment: ["OPENROUTER_API_KEY": "fake-env-key"]).read()
                == "fake-env-key")
        #expect(OpenRouterCredentialReader(environment: ["OPENROUTER_API_KEY": "  "]).read() == nil)
        #expect(OpenRouterCredentialReader(environment: [:]).read() == nil)
    }

    /// Arquivo de conta registrada vence a env (a conta é mais específica).
    @Test func keyFileBeatsEnvironment() throws {
        let reader = OpenRouterCredentialReader(
            keyFileURL: try write("fake-file-key"),
            environment: ["OPENROUTER_API_KEY": "fake-env-key"])
        #expect(reader.read() == "fake-file-key")
    }
}

// MARK: - OpenRouterProvider

@Suite(.serialized)
final class OpenRouterProviderBasicsTests {
    func makeProvider(key: String? = nil) -> OpenRouterProvider {
        OpenRouterProvider(
            credentialReader: OpenRouterCredentialReader(
                environment: key.map { ["OPENROUTER_API_KEY": $0] } ?? [:]),
            client: UsageHTTPClient(baseURL: URL(string: "https://or.example.com/api/v1")!))
    }

    @Test func conformsToUsageProviderBasics() async throws {
        let provider = makeProvider(key: "fake-or-key")
        #expect(provider.id == .openrouter)
        #expect(provider.capabilities == [.apiUsage, .credits, .multiAccount])
        #expect(await provider.discoverAccounts() == [OpenRouterFixtures.localRef])
    }

    @Test func discoverAccountsWithoutKeyIsEmpty() async {
        #expect(await makeProvider().discoverAccounts() == [])
    }

    @Test func resolveBaseURLOrder() {
        #expect(
            OpenRouterProvider.resolveBaseURL(environment: ["TOKENBAR_OPENROUTER_API": "https://a.example.com"])
                == URL(string: "https://a.example.com"))
        #expect(
            OpenRouterProvider.resolveBaseURL(environment: ["OPENROUTER_API_URL": "https://b.example.com/v1"])
                == URL(string: "https://b.example.com/v1"))
        #expect(
            OpenRouterProvider.resolveBaseURL(environment: ["OPENROUTER_API_URL": "notaurl"])
                == URL(string: "https://openrouter.ai/api/v1"), "sem scheme http(s) → default")
        #expect(
            OpenRouterProvider.resolveBaseURL(environment: ["OPENROUTER_API_URL": "ftp://b.example.com"])
                == URL(string: "https://openrouter.ai/api/v1"))
        #expect(OpenRouterProvider.resolveBaseURL(environment: [:]) == URL(string: "https://openrouter.ai/api/v1"))
    }

    /// Lógica da janela da key portada do plugin (`keyUsedForQuota`).
    @Test func mapWindowPrecedenceAndClamps() throws {
        func payload(_ body: String) throws -> OpenRouterProvider.OpenRouterKeyResponse.Payload {
            try JSONDecoder().decode(OpenRouterProvider.OpenRouterKeyResponse.self, from: Data(body.utf8)).data!
        }
        let remaining = try payload(OpenRouterFixtures.keyBody)
        let window = try #require(OpenRouterProvider.mapWindow(remaining))
        #expect(window.usedFraction == 0.49, "limit − clamp(remaining, 0, limit)")
        #expect(window.label == "Mensal")
        #expect(window.kind == .weekly)
        #expect(window.resetsAt == nil, "a API não devolve timestamp de reset")

        #expect(OpenRouterProvider.mapWindow(try payload(OpenRouterFixtures.keyNoLimitBody)) == nil, "sem limit não há percent")

        #expect(OpenRouterProvider.mapWindow(try payload(OpenRouterFixtures.keyClampAboveBody))?.usedFraction == 0.0)
        #expect(OpenRouterProvider.mapWindow(try payload(OpenRouterFixtures.keyClampBelowBody))?.usedFraction == 1.0)

        let weekly = try #require(OpenRouterProvider.mapWindow(try payload(OpenRouterFixtures.keyWeeklyBody)))
        #expect(weekly.usedFraction == 0.25, "usage_weekly escolhido por limit_reset")
        #expect(weekly.label == "Semanal")

        let fallback = try #require(OpenRouterProvider.mapWindow(try payload(OpenRouterFixtures.keyUsageFallbackBody)))
        #expect(fallback.usedFraction == 0.325, "sem usage_daily → usage cumulativo")
    }
}

@Suite(.serialized)
final class OpenRouterUsageAPITests {
    static let host = "or.example.com"

    func makeProvider(key: String?) -> OpenRouterProvider {
        OpenRouterProvider(
            credentialReader: OpenRouterCredentialReader(
                environment: key.map { ["OPENROUTER_API_KEY": $0] } ?? [:]),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://or.example.com/api/v1")!,
                session: f5StubbedSession()))
    }

    /// Contrato: 2 requests (credits → key), Bearer em ambos, base `/api/v1`.
    /// Snapshot: janela da key + credits com saldo.
    @Test func fetchUsageMapsCreditsAndKey() async throws {
        F5StubURLProtocol.configure({ request in
            if request.url?.path.hasSuffix("/credits") == true {
                return F5StubURLProtocol.Exchange(status: 200, body: Data(OpenRouterFixtures.creditsBody.utf8), error: nil)
            }
            return F5StubURLProtocol.Exchange(status: 200, body: Data(OpenRouterFixtures.keyBody.utf8), error: nil)
        }, host: Self.host)
        let provider = makeProvider(key: "fake-or-key")

        let snapshot = try await provider.fetchUsage(OpenRouterFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: Self.host).count == 2)
        for request in F5StubURLProtocol.requests(host: Self.host) {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-or-key")
        }
        let logged = F5StubURLProtocol.requests(host: Self.host)
        #expect(logged[0].url?.path.hasSuffix("/credits") == true)
        #expect(logged[1].url?.path.hasSuffix("/key") == true)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].usedFraction == 0.49)
        #expect(snapshot.credits == CreditsInfo(remaining: 62.80, unlimited: false))
    }

    /// `/key` falhou (500): degradação SOFT da referência — snapshot segue
    /// com credits, sem janela, authState ok.
    @Test func keyFailureIsSoftDegradation() async throws {
        F5StubURLProtocol.configure({ request in
            if request.url?.path.hasSuffix("/credits") == true {
                return F5StubURLProtocol.Exchange(status: 200, body: Data(OpenRouterFixtures.creditsBody.utf8), error: nil)
            }
            return F5StubURLProtocol.Exchange(status: 500, body: Data(), error: nil)
        }, host: Self.host)
        let provider = makeProvider(key: "fake-or-key")
        let snapshot = try await provider.fetchUsage(OpenRouterFixtures.localRef)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.credits?.remaining == 62.80)
    }

    /// `/key` sem limit configurado → sem janela, snapshot ok.
    @Test func keyWithoutLimitYieldsNoWindow() async throws {
        F5StubURLProtocol.configure({ request in
            if request.url?.path.hasSuffix("/credits") == true {
                return F5StubURLProtocol.Exchange(status: 200, body: Data(OpenRouterFixtures.creditsBody.utf8), error: nil)
            }
            return F5StubURLProtocol.Exchange(status: 200, body: Data(OpenRouterFixtures.keyNoLimitBody.utf8), error: nil)
        }, host: Self.host)
        let snapshot = try await makeProvider(key: "fake-or-key").fetchUsage(OpenRouterFixtures.localRef)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.credits?.remaining == 62.80)
    }

    /// 401 no credits → `.invalid` (a key está morta), sem segunda tentativa
    /// do credits.
    @Test func credits401DegradesInvalid() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 401, body: Data(), error: nil)
        }, host: Self.host)
        let snapshot = try await makeProvider(key: "fake-or-key").fetchUsage(OpenRouterFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .invalid)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.credits == nil)
        #expect(F5StubURLProtocol.requests(host: Self.host).count == 1)
    }

    /// Erro de rede no credits → rethrow (backoff; spec §5 regra 3).
    @Test func networkErrorRethrows() async {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }, host: Self.host)
        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await makeProvider(key: "fake-or-key").fetchUsage(OpenRouterFixtures.localRef)
        }
    }

    /// `/credits` 200 sem bloco `data` → erro tipado (nunca snapshot vazio
    /// disfarçado de sucesso).
    @Test func creditsWithoutDataThrows() async {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(#"{"error":"fake"}"#.utf8), error: nil)
        }, host: Self.host)
        await #expect(throws: OpenRouterAPIError.self) {
            try await makeProvider(key: "fake-or-key").fetchUsage(OpenRouterFixtures.localRef)
        }
    }

    @Test func withoutKeyReportsMissingAndSkipsNetwork() async throws {
        F5StubURLProtocol.configure(nil, host: Self.host)
        let snapshot = try await makeProvider(key: nil).fetchUsage(OpenRouterFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
        #expect(F5StubURLProtocol.requests(host: Self.host).isEmpty)
    }

    @Test func rejectsUnknownAccount() async {
        await #expect(throws: OpenRouterProviderError.self) {
            try await makeProvider(key: "fake-or-key")
                .fetchUsage(AccountRef(id: AccountID(provider: .openrouter, key: "outra"), label: "?"))
        }
    }
}

// MARK: - 2 keys simultâneas (carry-forward review T4/T5)

/// `.multiAccount` REAL do OpenRouter: DUAS keys registradas em paralelo, cada
/// uma com instância própria (mesmo wiring do `makeAccountProvider`) — o ciclo
/// cobre as duas e cada request carrega a Bearer DA SUA key (zero cross-talk).
@Suite(.serialized)
final class OpenRouterMultiKeyTests {
    static let host = "or-multi.example.com"
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ormulti-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func writeKey(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeRegistry() throws -> (AppDatabase, AccountRegistry) {
        let db = try AppDatabase.open(
            at: dir.appendingPathComponent("db-\(UUID().uuidString).sqlite"),
            calendar: Calendar.current)
        return (db, AccountRegistry(database: db))
    }

    @Test("2 keys simultâneas: descoberta merge + instância por key + saldo/janela ISOLADOS por conta")
    func twoKeysCycleInParallelWithoutCrossTalk() async throws {
        let keyA = try writeKey("key-a.txt", "fake-or-key-a")
        let keyB = try writeKey("key-b.txt", "fake-or-key-b")
        let (db, registry) = try makeRegistry()
        let accountA = try registry.add(provider: .openrouter, label: "Alpha", credentialPath: keyA.path)
        let accountB = try registry.add(provider: .openrouter, label: "Beta", credentialPath: keyB.path)

        // Resposta por key: saldos e janelas DISTINTOS (prova de isolamento).
        F5StubURLProtocol.configure({ request in
            guard let auth = request.value(forHTTPHeaderField: "Authorization") else {
                return F5StubURLProtocol.Exchange(status: 401, body: Data(), error: nil)
            }
            let credits: String
            let key: String
            switch auth {
            case "Bearer fake-or-key-a":
                credits = #"{"data":{"total_credits":100,"total_usage":30}}"#  // saldo 70
                key = #"{"data":{"limit":40,"limit_remaining":20}}"#           // 50%
            default:
                credits = #"{"data":{"total_credits":10,"total_usage":9}}"#    // saldo 1
                key = #"{"data":{"limit":20,"usage":5,"limit_reset":"daily"}}"# // sem remaining → usage_daily? não veio; usage 5/20 = 25%
            }
            let body = request.url?.path.hasSuffix("/credits") == true ? credits : key
            return F5StubURLProtocol.Exchange(status: 200, body: Data(body.utf8), error: nil)
        }, host: Self.host)

        func makeInstance(_ entry: RegisteredAccount) -> OpenRouterProvider {
            OpenRouterProvider(
                credentialReader: OpenRouterCredentialReader(keyFileURL: URL(filePath: entry.credentialPath)),
                client: UsageHTTPClient(
                    baseURL: URL(string: "https://\(Self.host)/api/v1")!,
                    session: f5StubbedSession()),
                accountKey: entry.accountKey,
                label: entry.label)
        }

        // Descoberta da instância canônica (sem env key): só as 2 registradas.
        let canonical = OpenRouterProvider(
            credentialReader: OpenRouterCredentialReader(environment: [:]),
            client: UsageHTTPClient(baseURL: URL(string: "https://\(Self.host)/api/v1")!),
            accounts: registry)
        let refs = await canonical.discoverAccounts()
        #expect(refs.map(\.id.key) == [accountA.accountKey, accountB.accountKey],
                "sem auto (sem env), as 2 registradas — 1 key = 1 conta")

        let registered = try registry.activeAccounts(provider: .openrouter)
        let instanceA = makeInstance(try #require(registered.first { $0.accountKey == accountA.accountKey }))
        let instanceB = makeInstance(try #require(registered.first { $0.accountKey == accountB.accountKey }))
        let snapshotA = try await instanceA.fetchUsage(instanceA.accountRef)
        let snapshotB = try await instanceB.fetchUsage(instanceB.accountRef)

        // Saldos e janelas da key CERTA em cada conta.
        #expect(snapshotA.credits == CreditsInfo(remaining: 70, unlimited: false))
        #expect(snapshotA.windows.count == 1)
        #expect(snapshotA.windows[0].usedFraction == 0.5)
        #expect(snapshotB.credits == CreditsInfo(remaining: 1, unlimited: false))
        #expect(snapshotB.windows[0].usedFraction == 0.25)

        // Cada request carregou a Bearer da PRÓPRIA key (nunca misturou).
        let auths = Set(F5StubURLProtocol.requests(host: Self.host).compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        })
        #expect(auths == ["Bearer fake-or-key-a", "Bearer fake-or-key-b"])
    }
}
