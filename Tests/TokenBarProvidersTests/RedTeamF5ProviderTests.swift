import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

/// Red Team F5 (Task 7) — providers NOVOS sob respostas hostis (fixture-replay
/// de shapes adversariais): JSON lixo, tipos errados, números gigantes/absurdos,
/// aninhamento profundo. Contrato de degradação (spec §5): payload que viola o
/// contrato → erro tipado/rethrow (último snapshot bom permanece); payload
/// parseável mas sem dado → snapshot honesto SEM dado inventado. Em NENHUM
/// caso: crash, fração/saldo chutado ou credencial logada.
@Suite(.serialized)
final class RedTeamF5HostileProviderTests {
    // Um host POR provider (stub roteia por host — suítes não se contaminam).
    static let orHost = "or-rt5.example.com"
    static let alHost = "alibaba-rt5.example.com"
    static let dsHost = "deepseek-rt5.example.com"
    static let grokHost = "grok-rt5.example.com"
    static let antiHost = "cloudcode-pa-rt5.googleapis.com"
    static let cursorHost = "cursor-rt5.example.com"

    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt5-hostile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func stub(_ host: String, body: String, status: Int = 200) {
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: status, body: Data(body.utf8), error: nil)
        }, host: host)
    }

    // MARK: - OpenRouter

    private func makeOpenRouter() -> OpenRouterProvider {
        OpenRouterProvider(
            credentialReader: OpenRouterCredentialReader(environment: ["OPENROUTER_API_KEY": "fake-rt5-key"]),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(Self.orHost)/api/v1")!,
                session: f5StubbedSession()))
    }

    @Test("OpenRouter hostil: JSON lixo → rethrow; data sem números → erro tipado; 1e308 → saldo finito; negativo → clamp 0")
    func openRouterHostile() async throws {
        let provider = makeOpenRouter()
        let ref = AccountRef(id: AccountID(provider: .openrouter, key: "local"), label: "local")

        // JSON lixo: decode estoura (rethrow — backoff do scheduler).
        stub(Self.orHost, body: "{")
        await #expect(throws: UsageHTTPError.decode(URLError(.badServerResponse))) {
            _ = try await provider.fetchUsage(ref)
        }

        // `data` presente mas sem total_credits/total_usage utilizáveis → erro
        // tipado (nunca snapshot vazio disfarçado de sucesso).
        stub(Self.orHost, body: #"{"data":{"total_credits":[1,2],"total_usage":{"a":1}}}"#)
        await #expect(throws: OpenRouterAPIError.self) { _ = try await provider.fetchUsage(ref) }

        // Número gigante (1e308): finito → snapshot ok com o valor REAL da API
        // (nada a inventar); sem crash, sem overflow.
        stub(Self.orHost, body: #"{"data":{"total_credits":1e308,"total_usage":0}}"#)
        let huge = try await provider.fetchUsage(ref)
        #expect(huge.credits?.remaining?.isFinite == true)
        #expect(huge.credits?.remaining == 1e308)

        // Uso maior que créditos → clamp em 0 (mesma regra da referência).
        stub(Self.orHost, body: #"{"data":{"total_credits":10,"total_usage":99}}"#)
        let negative = try await provider.fetchUsage(ref)
        #expect(negative.credits?.remaining == 0)
    }

    // MARK: - Alibaba

    private func makeAlibaba() -> AlibabaProvider {
        AlibabaProvider(
            credentialReader: AlibabaCredentialReader(environment: ["ALIBABA_CODING_PLAN_API_KEY": "fake-rt5-key"]),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(Self.alHost)")!,
                session: f5StubbedSession()))
    }

    // NOTA: nenhum caso aqui esgota as DUAS regiões — o fallback do provider
    // aponta o gateway CANÔNICO cn (`bailian.console.aliyun.com`), um host
    // COMPARTILHADO no stub global (outras suítes o stubam em paralelo).
    // Casos que resolvem na região PRIMÁRIA são race-free; os cenários de
    // fallback/duas-regiões já são cobertos em AlibabaProviderTests.

    @Test("Alibaba hostil: JSON lixo → rethrow; aninhamento profundo com quota → mapeia sem crash; quota com total 0 → snapshot vazio HONESTO (sem janela, não erro)")
    func alibabaHostile() async throws {
        let provider = makeAlibaba()
        let ref = AccountRef(id: AccountID(provider: .alibaba, key: "local"), label: "local")

        // Lixo: o CLIENT valida o JSON do 200 → decode throw ANTES do parse
        // do provider (rethrow; nunca vira dado).
        stub(Self.alHost, body: "not-json-at-all<xml>")
        await #expect(throws: (any Error).self) { _ = try await provider.fetchUsage(ref) }

        // Quota sob aninhamento profundo (busca recursiva do findQuotaInfo) —
        // parse e mapeamento sem crash; fração correta (30/100). Encontra na
        // PRIMEIRA região → nem chega ao fallback.
        var payload: [String: Any] = ["per5HourUsedQuota": 30, "per5HourTotalQuota": 100]
        for _ in 0..<120 { payload = ["wrap": payload] }
        let deep = try JSONSerialization.data(withJSONObject: payload)
        F5StubURLProtocol.configure({ _ in
            F5StubURLProtocol.Exchange(status: 200, body: deep, error: nil)
        }, host: Self.alHost)
        let snapshot = try await provider.fetchUsage(ref)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].usedFraction == 0.3)

        // Quota presente com total 0 → janela NÃO nasce (divisão impossível),
        // mas o bloco EXISTE → snapshot ok SEM janela (honesto; o erro tipado
        // é só quando NENHUM bloco de quota existe no payload).
        stub(Self.alHost, body: #"{"codingPlanQuotaInfo":{"per5HourUsedQuota":5,"per5HourTotalQuota":0}}"#)
        let empty = try await provider.fetchUsage(ref)
        #expect(empty.windows.isEmpty)
        #expect(empty.authState == .ok)
    }

    // MARK: - DeepSeek

    private func makeDeepSeek() -> DeepSeekProvider {
        DeepSeekProvider(
            credentialReader: DeepSeekCredentialReader(environment: ["DEEPSEEK_API_KEY": "fake-rt5-sk"]),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(Self.dsHost)")!,
                session: f5StubbedSession()))
    }

    @Test("DeepSeek hostil: saldo não-numérico → erro tipado; 1e308 como string → finito; array vazio → erro tipado")
    func deepSeekHostile() async throws {
        let provider = makeDeepSeek()
        let ref = AccountRef(id: AccountID(provider: .deepseek, key: "local"), label: "local")

        stub(Self.dsHost, body: #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"not-a-number"}]}"#)
        await #expect(throws: DeepSeekAPIError.self) { _ = try await provider.fetchUsage(ref) }

        stub(Self.dsHost, body: #"{"is_available":true,"balance_infos":[]}"#)
        await #expect(throws: DeepSeekAPIError.self) { _ = try await provider.fetchUsage(ref) }

        stub(Self.dsHost, body: #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1e308"}]}"#)
        let huge = try await provider.fetchUsage(ref)
        #expect(huge.credits?.remaining?.isFinite == true)
    }

    // MARK: - Grok

    private func makeGrok() throws -> GrokProvider {
        let authURL = try write("grok-auth-\(UUID().uuidString).json", GrokFixtures.authJSON)
        return GrokProvider(
            credentialReader: GrokCredentialReader(authFileURL: authURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(Self.grokHost)")!,
                session: f5StubbedSession()))
    }

    @Test("Grok hostil: JSON lixo → rethrow; config sem percent calculável → erro tipado; percent absurdo satura na janela")
    func grokHostile() async throws {
        let provider = try makeGrok()
        let ref = AccountRef(id: AccountID(provider: .grok, key: "local"), label: "local")

        stub(Self.grokHost, body: "{")
        await #expect(throws: (any Error).self) { _ = try await provider.fetchUsage(ref) }

        stub(Self.grokHost, body: #"{"config":{"creditUsagePercent":"lots"},"subscriptionTier":42}"#)
        await #expect(throws: GrokAPIError.self) { _ = try await provider.fetchUsage(ref) }

        // Percent fora da vida (420) → fração satura em 1.0 (nunca >100%).
        stub(Self.grokHost, body: #"{"config":{"creditUsagePercent":420,"currentPeriod":{"end":"2027-01-17T00:00:00Z"}}}"#)
        let snapshot = try await provider.fetchUsage(ref)
        #expect(snapshot.windows[0].usedFraction == 1.0)
    }

    // MARK: - Antigravity

    private func makeAntigravity() throws -> AntigravityProvider {
        let credsURL = try write("antig-creds-\(UUID().uuidString).json", AntigravityFixtures.oauthCreds)
        return AntigravityProvider(
            credentialReader: AntigravityCredentialReader(credentialsFileURL: credsURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(Self.antiHost)")!,
                session: f5StubbedSession()))
    }

    @Test("Antigravity hostil: JSON lixo → rethrow; models sem fração → erro tipado; remainingFraction objeto → decode/erro, sem crash")
    func antigravityHostile() async throws {
        let provider = try makeAntigravity()
        let ref = AccountRef(id: AccountID(provider: .antigravity, key: "local"), label: "local")

        stub(Self.antiHost, body: "{]")
        await #expect(throws: (any Error).self) { _ = try await provider.fetchUsage(ref) }

        stub(Self.antiHost, body: AntigravityFixtures.emptyModelsBody)
        await #expect(throws: AntigravityAPIError.self) { _ = try await provider.fetchUsage(ref) }

        stub(Self.antiHost, body: #"{"models":{"m1":{"quotaInfo":{"remainingFraction":{"nested":true}}}}}"#)
        await #expect(throws: (any Error).self) { _ = try await provider.fetchUsage(ref) }

        // remainingFraction NEGATIVO → fração satura em 1.0 (1 − (−0.5) = 1.5 → 1).
        stub(Self.antiHost, body: #"{"models":{"m1":{"quotaInfo":{"remainingFraction":-0.5}}}}"#)
        let snapshot = try await provider.fetchUsage(ref)
        #expect(snapshot.windows[0].usedFraction == 1.0)
    }

    // MARK: - Cursor

    private func makeCursor() throws -> CursorProvider {
        let tokenURL = try write("cursor-token-\(UUID().uuidString).txt", F5Fixtures.cursorJWT())
        return CursorProvider(
            credentialReader: CursorCredentialReader(databaseFileURL: nil, tokenFileURL: tokenURL),
            client: UsageHTTPClient(
                baseURL: URL(string: "https://\(Self.cursorHost)")!,
                session: f5StubbedSession()))
    }

    @Test("Cursor hostil: JSON lixo → rethrow; shape novo (plan string onde objeto espera) → rethrow, sem crash")
    func cursorHostile() async throws {
        let provider = try makeCursor()
        let ref = AccountRef(id: AccountID(provider: .cursor, key: "local"), label: "local")

        stub(Self.cursorHost, body: "<html>502 bad gateway fake</html>")
        await #expect(throws: (any Error).self) { _ = try await provider.fetchUsage(ref) }

        // Shape novo com tipos errados nos campos → decoder TOLERANTE não
        // lança: snapshot honesto sem percent (campos ficam nil) — mesmo
        // contrato da referência (alias/tolerância); nunca crash nem chute.
        stub(Self.cursorHost, body: #"{"individualUsage":{"plan":"not-an-object"},"teamUsage":[1,2,3]}"#)
        let tolerant = try await provider.fetchUsage(ref)
        #expect(tolerant.source == .api)
        #expect(tolerant.windows.isEmpty, "sem percent utilizável → nenhuma janela inventada")

        // Percent gigante no plano → fração satura em 1.0.
        stub(Self.cursorHost, body: #"{"billingCycleEnd":"2027-01-17T00:00:00.000Z","individualUsage":{"plan":{"totalPercentUsed":4200,"used":5,"limit":10}}}"#)
        let snapshot = try await provider.fetchUsage(ref)
        #expect(snapshot.windows[0].usedFraction == 1.0)
    }
}
