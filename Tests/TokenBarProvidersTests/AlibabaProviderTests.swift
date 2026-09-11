import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (fonte MIT: AlibabaCodingPlanUsageFetcher/Snapshot)

enum AlibabaFixtures {
    static let localRef = AccountRef(id: AccountID(provider: .alibaba, key: "local"), label: "local")
    static let host = "alibaba.example.com"
    static let cnHost = "bailian.console.aliyun.com"

    /// Payload com `codingPlanQuotaInfo` NESTADO (shape real do console: o
    /// bloco vem dentro de data/instance) — 5h 40/100, semana 120/200 (epoch
    /// ms de reset), mês 500/1000 (datas OneConsole "yyyy-MM-dd HH:mm:ss").
    static let quotaBody = """
    {
      "code": 0,
      "data": {
        "codingPlanInstanceInfos": [ { "planName": "Qwen Code Pro",
          "codingPlanQuotaInfo": {
            "per5HourUsedQuota": 40, "per5HourTotalQuota": 100,
            "per5HourQuotaNextRefreshTime": 1800036000000,
            "perWeekUsedQuota": 120, "perWeekTotalQuota": 200,
            "perWeekQuotaNextRefreshTime": 1800086400000,
            "perBillMonthUsedQuota": 500, "perBillMonthTotalQuota": 1000,
            "perBillMonthQuotaNextRefreshTime": "2027-01-17 00:00:00"
          } } ]
      }
    }
    """

    /// `coding_plan_quota_info` no ROOT (alias snake) + valores como STRING —
    /// tolerância de shape da referência.
    static let snakeRootBody = """
    {
      "plan_name": "Qwen Code",
      "coding_plan_quota_info": {
        "per5HourUsedQuota": "9", "per5HourTotalQuota": "100",
        "perFiveHourQuotaNextRefreshTime": 1800036000
      }
    }
    """

    /// Payload 200 SEM quota nenhuma (modo API key indisponível nesta
    /// região/conta — mensagem real da referência) → fallback de região.
    static let noQuotaBody = #"{"code":0,"data":{"message":"Coding Plan quota is not available through Coding Plan API keys for this account/region."}}"#
}

// MARK: - Reader

@Suite
final class AlibabaCredentialReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibabareader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func envKeyOrderAndFile() throws {
        #expect(
            AlibabaCredentialReader(environment: [
                "ALIBABA_CODING_PLAN_API_KEY": "fake-plan-key",
                "ALIBABA_QWEN_API_KEY": "fake-qwen-key",
            ]).read() == "fake-plan-key", "ordem da referência")
        #expect(
            AlibabaCredentialReader(environment: ["ALIBABA_QWEN_API_KEY": "fake-qwen-key"]).read()
                == "fake-qwen-key")
        #expect(AlibabaCredentialReader(environment: ["DASHSCOPE_API_KEY": " fake-dash "]).read() == "fake-dash")

        let url = dir.appendingPathComponent("key.txt")
        try #"fake-file-key"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(
            AlibabaCredentialReader(
                environment: ["ALIBABA_CODING_PLAN_API_KEY": "fake-env"],
                keyFileURL: url).read() == "fake-file-key", "arquivo vence a env")
    }
}

// MARK: - Provider (basics + parse puro)

@Suite
final class AlibabaProviderBasicsTests {
    func makeProvider(env: [String: String] = [:]) -> AlibabaProvider {
        AlibabaProvider(
            credentialReader: AlibabaCredentialReader(environment: env),
            client: UsageHTTPClient(baseURL: URL(string: "https://\(AlibabaFixtures.host)")!))
    }

    @Test func conformsToUsageProviderBasics() async {
        let provider = makeProvider(env: ["ALIBABA_CODING_PLAN_API_KEY": "fake-key"])
        #expect(provider.id == .alibaba)
        #expect(provider.capabilities == [.apiUsage, .multiAccount])
        #expect(await provider.discoverAccounts() == [AlibabaFixtures.localRef])
        #expect(await makeProvider().discoverAccounts() == [])
    }

    @Test func resolveBaseURLRegionOverride() {
        #expect(
            AlibabaProvider.resolveBaseURL(environment: ["TOKENBAR_ALIBABA_REGION": "cn"])
                == URL(string: "https://bailian.console.aliyun.com"))
        #expect(
            AlibabaProvider.resolveBaseURL(environment: [:])
                == URL(string: "https://modelstudio.console.alibabacloud.com"))
    }

    /// Parse recursivo: quota nestada em instância, alias snake no root,
    /// números como string, datas epoch s/ms e OneConsole.
    @Test func findQuotaInfoAndWindowMapping() throws {
        let nested = try JSONSerialization.jsonObject(with: Data(AlibabaFixtures.quotaBody.utf8))
        let quota = try #require(AlibabaProvider.findQuotaInfo(in: nested))
        #expect(AlibabaProvider.findPlanName(in: nested) == "Qwen Code Pro")

        let snake = try JSONSerialization.jsonObject(with: Data(AlibabaFixtures.snakeRootBody.utf8))
        #expect(AlibabaProvider.findQuotaInfo(in: snake) != nil)
        #expect(AlibabaProvider.findPlanName(in: snake) == "Qwen Code")

        // Mapeamento de janelas testado via fetchUsage (stub) abaixo.
        _ = quota
    }

    @Test func rejectsUnknownAccount() async {
        await #expect(throws: AlibabaProviderError.self) {
            try await makeProvider(env: ["ALIBABA_CODING_PLAN_API_KEY": "fake-key"])
                .fetchUsage(AccountRef(id: AccountID(provider: .alibaba, key: "outra"), label: "?"))
        }
    }
}

@Suite(.serialized)
final class AlibabaUsageAPITests {
    func makeProvider(env: [String: String] = [:]) -> AlibabaProvider {
        AlibabaProvider(
            credentialReader: AlibabaCredentialReader(environment: env),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(AlibabaFixtures.host)")!,
                session: f5StubbedSession()))
    }

    /// Contrato da referência: POST no gateway injetado com action/product/api/
    /// currentRegionId, Bearer + x-api-key + X-DashScope-API-Key + Origin/
    /// Referer da região (carry-forward T7), corpo com commodityCode da região.
    /// Janelas 5h/semana/mês mapeadas.
    @Test func fetchUsageMapsQuotaWindowsAndSendsContract() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AlibabaFixtures.quotaBody.utf8), error: nil)
        }, host: AlibabaFixtures.host)
        let provider = makeProvider(env: ["ALIBABA_CODING_PLAN_API_KEY": "fake-key"])

        let snapshot = try await provider.fetchUsage(AlibabaFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: AlibabaFixtures.host).count == 1)
        let request = try #require(F5StubURLProtocol.lastRequest(host: AlibabaFixtures.host))
        let url = try #require(request.url)
        #expect(url.host == AlibabaFixtures.host)
        #expect(url.path == "/data/api.json")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try #require(components.queryItems)
        #expect(query.first(where: { $0.name == "action" })?.value?.hasSuffix("queryCodingPlanInstanceInfoV2") == true)
        #expect(query.first(where: { $0.name == "currentRegionId" })?.value == "ap-southeast-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-key")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fake-key")
        #expect(request.value(forHTTPHeaderField: "X-DashScope-API-Key") == "fake-key")
        // Carry-forward T7: Origin = gateway da região; Referer = dashboard da
        // região (`dashboardURL` da referência, bit-a-bit).
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://\(AlibabaFixtures.host)")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan")
        #expect(request.httpBody != nil)

        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 3)

        let fiveHours = snapshot.windows[0]
        #expect(fiveHours.kind == .session)
        #expect(fiveHours.label == "5h")
        #expect(fiveHours.usedFraction == 0.40)
        #expect(fiveHours.resetsAt == Date(timeIntervalSince1970: 1_800_036_000), "epoch em ms → ÷1000")

        let weekly = snapshot.windows[1]
        #expect(weekly.label == "Semanal")
        #expect(weekly.usedFraction == 0.60)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_800_086_400))

        let monthly = snapshot.windows[2]
        #expect(monthly.label == "Mensal")
        #expect(monthly.usedFraction == 0.50)
        #expect(monthly.resetsAt == UsageDates.oneConsole("2027-01-17 00:00:00"))
    }

    /// Alias snake no root + números como string.
    @Test func fetchUsageToleratesSnakeRootAndStringNumbers() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AlibabaFixtures.snakeRootBody.utf8), error: nil)
        }, host: AlibabaFixtures.host)
        let snapshot = try await makeProvider(env: ["ALIBABA_QWEN_API_KEY": "fake-key"])
            .fetchUsage(AlibabaFixtures.localRef)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].usedFraction == 0.09)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_036_000), "epoch em segundos")
    }

    /// Quota indisponível na região primária → fallback p/ gateway canônico
    /// da outra região (1 retry por ciclo).
    @Test func regionFallbackOnMissingQuota() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AlibabaFixtures.noQuotaBody.utf8), error: nil)
        }, host: AlibabaFixtures.host)
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: Data(AlibabaFixtures.quotaBody.utf8), error: nil)
        }, host: AlibabaFixtures.cnHost)

        let snapshot = try await makeProvider(env: ["DASHSCOPE_API_KEY": "fake-key"])
            .fetchUsage(AlibabaFixtures.localRef)

        #expect(F5StubURLProtocol.requests(host: AlibabaFixtures.host).count == 1)
        #expect(F5StubURLProtocol.requests(host: AlibabaFixtures.cnHost).count == 1)
        let cnRequest = try #require(F5StubURLProtocol.lastRequest(host: AlibabaFixtures.cnHost))
        let cnURL = try #require(cnRequest.url)
        let cnComponents = try #require(URLComponents(url: cnURL, resolvingAgainstBaseURL: false))
        let query = try #require(cnComponents.queryItems)
        #expect(query.first(where: { $0.name == "currentRegionId" })?.value == "cn-beijing")
        #expect(snapshot.authState == .ok)
        #expect(snapshot.windows.count == 3)
    }

    /// 401 nas duas regiões → `.invalid` (nunca erro na barra).
    @Test func unauthorizedOnBothRegionsDegrades() async throws {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 401, body: Data(), error: nil)
        }, host: AlibabaFixtures.host)
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 403, body: Data(), error: nil)
        }, host: AlibabaFixtures.cnHost)

        let snapshot = try await makeProvider(env: ["ALIBABA_CODING_PLAN_API_KEY": "fake-key"])
            .fetchUsage(AlibabaFixtures.localRef)

        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .invalid)
        #expect(snapshot.windows.isEmpty)
    }

    /// Sem credencial → `.missing` sem request nenhum.
    @Test func withoutCredentialReportsMissing() async throws {
        F5StubURLProtocol.configure(nil, host: AlibabaFixtures.host)
        let snapshot = try await makeProvider().fetchUsage(AlibabaFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
        #expect(snapshot.windows.isEmpty)
        #expect(F5StubURLProtocol.requests(host: AlibabaFixtures.host).isEmpty)
    }

    /// Erro de rede → rethrow (backoff; spec §5 regra 3).
    @Test func networkErrorRethrows() async {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }, host: AlibabaFixtures.host)
        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await makeProvider(env: ["ALIBABA_CODING_PLAN_API_KEY": "fake-key"])
                .fetchUsage(AlibabaFixtures.localRef)
        }
    }
}
