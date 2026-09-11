import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (fonte MIT: DeepSeekUsageFetcher)

enum DeepSeekFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .deepseek, key: "local"), label: "local")
    static let host = "deepseek.example.com"

    /// Shape real da API pública: saldo como STRING,Granted/topped-up extras.
    static let balanceBody = """
    {"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"62.80",
      "granted_balance":"5.00","topped_up_balance":"57.80"}]}
    """

    /// Conta sem saldo utilizável (sem balance_infos) → erro tipado.
    static let emptyBalanceBody = #"{"is_available":true,"balance_infos":[]}"#
}

// MARK: - Reader

@Suite
final class DeepSeekCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepseekreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func envAndFileSources() throws {
        #expect(DeepSeekCredentialReader(environment: ["DEEPSEEK_API_KEY": " fake-sk "]).read() == "fake-sk")
        #expect(DeepSeekCredentialReader(environment: [:]).read() == nil)

        let url = dir.appendingPathComponent("key.txt")
        try "fake-file-sk\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(
            DeepSeekCredentialReader(environment: ["DEEPSEEK_API_KEY": "fake-env"], keyFileURL: url).read()
                == "fake-file-sk", "arquivo vence a env")
    }
}

// MARK: - Provider

@Suite
final class DeepSeekProviderBasicsTests {
    func makeProvider(key: String? = nil) -> DeepSeekProvider {
        DeepSeekProvider(
            credentialReader: DeepSeekCredentialReader(
                environment: key.map { ["DEEPSEEK_API_KEY": $0] } ?? [:]),
            client: UsageHTTPClient(baseURL: URL(string: "https://\(DeepSeekFixtures.host)")!))
    }

    @Test func conformsToUsageProviderBasics() async {
        let provider = makeProvider(key: "fake-sk")
        #expect(provider.id == .deepseek)
        #expect(provider.capabilities == [.apiUsage, .credits, .multiAccount])
        #expect(await provider.discoverAccounts() == [DeepSeekFixtures.localRef])
        #expect(await makeProvider().discoverAccounts() == [])
    }

    @Test func rejectsUnknownAccount() async {
        await #expect(throws: DeepSeekProviderError.self) {
            try await makeProvider(key: "fake-sk")
                .fetchUsage(AccountRef(id: AccountID(provider: .deepseek, key: "outra"), label: "?"))
        }
    }
}

@Suite(.serialized)
final class DeepSeekUsageAPITests {
    func makeProvider(key: String?) -> DeepSeekProvider {
        DeepSeekProvider(
            credentialReader: DeepSeekCredentialReader(
                environment: key.map { ["DEEPSEEK_API_KEY": $0] } ?? [:]),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(DeepSeekFixtures.host)")!,
                session: f5StubbedSession()))
    }

    /// Contrato: GET `user/balance` com Bearer; saldo string → credits.
    @Test func fetchUsageMapsBalance() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(DeepSeekFixtures.balanceBody.utf8), error: nil)
        }, host: DeepSeekFixtures.host)
        let provider = makeProvider(key: "fake-sk")

        let snapshot = try await provider.fetchUsage(DeepSeekFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: DeepSeekFixtures.host).count == 1)
        let request = try #require(F5StubURLProtocol.lastRequest(host: DeepSeekFixtures.host))
        #expect(request.url?.absoluteString == "https://\(DeepSeekFixtures.host)/user/balance")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-sk")

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.isEmpty, "API de saldo não devolve quota — sem janela inventada")
        #expect(snapshot.credits == CreditsInfo(remaining: 62.80, unlimited: false))
    }

    /// 200 sem balance_infos → erro tipado (rethrow, nunca snapshot falso).
    @Test func emptyBalanceThrows() async {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(DeepSeekFixtures.emptyBalanceBody.utf8), error: nil)
        }, host: DeepSeekFixtures.host)
        await #expect(throws: DeepSeekAPIError.self) {
            try await makeProvider(key: "fake-sk").fetchUsage(DeepSeekFixtures.localRef)
        }
    }

    /// 401/403 → `.invalid` + snapshot vazio.
    @Test func unauthorizedDegrades() async throws {
        for status in [401, 403] {
            F5StubURLProtocol.configure({ _ in
                F5StubURLProtocol.Exchange(status: status, body: Data(), error: nil)
            }, host: DeepSeekFixtures.host)
            let snapshot = try await makeProvider(key: "fake-sk").fetchUsage(DeepSeekFixtures.localRef)
            #expect(snapshot.source == .localOnly)
            #expect(snapshot.authState == .invalid)
            #expect(snapshot.credits == nil)
        }
    }

    /// Sem key → `.missing` sem request.
    @Test func withoutKeyReportsMissing() async throws {
        F5StubURLProtocol.configure(nil, host: DeepSeekFixtures.host)
        let snapshot = try await makeProvider(key: nil).fetchUsage(DeepSeekFixtures.localRef)
        #expect(snapshot.authState == .missing)
        #expect(F5StubURLProtocol.requests(host: DeepSeekFixtures.host).isEmpty)
    }

    /// Erro de rede → rethrow (backoff).
    @Test func networkErrorRethrows() async {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }, host: DeepSeekFixtures.host)
        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await makeProvider(key: "fake-sk").fetchUsage(DeepSeekFixtures.localRef)
        }
    }
}
