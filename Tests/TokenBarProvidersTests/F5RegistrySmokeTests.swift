import Foundation
import Testing
@testable import TokenBarCore
@testable import TokenBarProviders

/// Smoke F5 (Tasks 4–5): os 6 providers novos registrados no `ProviderRegistry`
/// junto com os 4 existentes, com conta REGISTRADA via `AccountRegistry`
/// (multi-conta real, fixtures sintéticas em temp dir). Prova de integração
/// do contrato F4 — descoberta MERGE (auto + registro, dedupe por key) — e de
/// que nenhum provider novo quebra os existentes.
@Suite
final class F5RegistrySmokeTests {
    let dir: URL
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("f5smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Todos os 10 providers com registry real (DB SQLite em temp dir).
    func makeRegistry() throws -> (ProviderRegistry, AccountRegistry) {
        let db = try AppDatabase.open(
            at: dir.appendingPathComponent("db-\(UUID().uuidString).sqlite"), calendar: calendar)
        let accountRegistry = AccountRegistry(database: db)
        let emptyURL = dir.appendingPathComponent("ausente.json")

        let claude = ClaudeProvider(
            projectsDirectory: dir,
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accounts: accountRegistry)
        let codex = CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: emptyURL),
            client: UsageHTTPClient(baseURL: URL(string: "https://codex.example.com")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accounts: accountRegistry)
        let gemini = GeminiProvider(geminiDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        let zai = ZaiProvider(
            credentialReader: ZaiCredentialReader(
                configFileURL: emptyURL,
                credentialsFileURL: emptyURL),
            client: UsageHTTPClient(baseURL: URL(string: "https://zai.example.com")!),
            accounts: accountRegistry)
        let cursor = CursorProvider(
            credentialReader: CursorCredentialReader(databaseFileURL: nil),
            client: UsageHTTPClient(baseURL: URL(string: "https://cursor.example.com")!),
            accounts: accountRegistry)
        let openrouter = OpenRouterProvider(
            credentialReader: OpenRouterCredentialReader(environment: [:]),
            client: UsageHTTPClient(baseURL: URL(string: "https://or.example.com/api/v1")!),
            accounts: accountRegistry)
        let alibaba = AlibabaProvider(
            credentialReader: AlibabaCredentialReader(environment: [:]),
            client: UsageHTTPClient(baseURL: URL(string: "https://alibaba.example.com")!),
            accounts: accountRegistry)
        let antigravity = AntigravityProvider(
            credentialReader: AntigravityCredentialReader(credentialsFileURL: nil),
            client: UsageHTTPClient(baseURL: URL(string: "https://antigravity.example.com")!),
            accounts: accountRegistry)
        let deepseek = DeepSeekProvider(
            credentialReader: DeepSeekCredentialReader(environment: [:]),
            client: UsageHTTPClient(baseURL: URL(string: "https://deepseek.example.com")!),
            accounts: accountRegistry)
        let grok = GrokProvider(
            credentialReader: GrokCredentialReader(authFileURL: emptyURL),
            client: UsageHTTPClient(baseURL: URL(string: "https://grok.example.com")!),
            accounts: accountRegistry)

        let registry = ProviderRegistry(providers: [
            claude, codex, gemini, zai, cursor, openrouter, alibaba, antigravity, deepseek, grok,
        ])
        return (registry, accountRegistry)
    }

    @Test("registry: 10 providers registrados, ids e capabilities corretos")
    func allProvidersRegistered() throws {
        let (registry, _) = try makeRegistry()
        #expect(registry.all.count == 10)
        #expect(Set(registry.all.map(\.id)) == Set(ProviderID.allCases).subtracting([.copilot]))

        // Capabilities F5: API-only + multiAccount; OpenRouter/DeepSeek com credits.
        for id in [ProviderID.cursor, .openrouter, .alibaba, .antigravity, .deepseek, .grok] {
            let provider = try #require(registry.provider(for: id))
            #expect(provider.capabilities.contains(.apiUsage), "\(id)")
            #expect(provider.capabilities.contains(.multiAccount), "\(id)")
            #expect(!provider.capabilities.contains(.localIngest), "\(id) é API-only")
        }
        #expect(registry.provider(for: .openrouter)!.capabilities.contains(.credits))
        #expect(registry.provider(for: .deepseek)!.capabilities.contains(.credits))
    }

    /// Multi-conta real (fixtures): cada provider novo com uma conta
    /// REGISTRADA via `AccountRegistry` (arquivo de credencial sintético) →
    /// descoberta MERGE contém a conta; provider sem credencial auto segue
    /// com a conta registrada apenas.
    @Test("multi-conta: conta registrada aparece na descoberta dos 6 novos")
    func registeredAccountsAreDiscovered() async throws {
        let (registry, accountRegistry) = try makeRegistry()

        // Arquivo de credencial sintético (mesmo arquivo servindo a todos os
        // casos de "arquivo cru"): só os leitores de key crua o consomem.
        let keyFile = dir.appendingPathComponent("fake-credential.txt")
        try "fake-key".write(to: keyFile, atomically: true, encoding: .utf8)

        var registeredKeys: [ProviderID: String] = [:]
        for id in [ProviderID.cursor, .openrouter, .alibaba, .antigravity, .deepseek, .grok] {
            let account = try accountRegistry.add(
                provider: id, label: "Fake \(id.rawValue)",
                credentialPath: keyFile.path, kind: "apikey")
            registeredKeys[id] = account.accountKey
        }

        for id in [ProviderID.cursor, .openrouter, .alibaba, .antigravity, .deepseek, .grok] {
            let provider = try #require(registry.provider(for: id))
            let refs = await provider.discoverAccounts()
            #expect(
                refs.contains { $0.id.key == registeredKeys[id] },
                "\(id): conta registrada descoberta (merge do registry)")
            #expect(refs.count == 1, "\(id): sem credencial auto, só a registrada")
        }

        // Toggle inativo: conta some da descoberta no ciclo seguinte.
        let openrouterKey = try #require(registeredKeys[.openrouter])
        try accountRegistry.setActive(false, provider: .openrouter, accountKey: openrouterKey)
        let openrouterProvider = try #require(registry.provider(for: .openrouter))
        let refs = await openrouterProvider.discoverAccounts()
        #expect(!refs.contains { $0.id.key == openrouterKey })
    }

    /// Isolamento: fetchUsage em conta ALHEIA lança erro tipado do provider
    /// (guardKnownAccount continua valendo entre instâncias — F4).
    @Test("isolamento: guardKnownAccount nos 6 novos")
    func accountGuardHolds() async throws {
        let (registry, accountRegistry) = try makeRegistry()
        let stranger = AccountRef(id: AccountID(provider: .cursor, key: "outra"), label: "?")

        let cursor = try #require(registry.provider(for: .cursor))
        await #expect(throws: CursorProviderError.self) {
            try await cursor.fetchUsage(stranger)
        }

        // A conta registrada de openrouter recebe instância própria com a key
        // dela — fetchUsage na key de OUTRA conta continua bloqueado.
        let keyFile = dir.appendingPathComponent("fake-key-2.txt")
        try "fake-key".write(to: keyFile, atomically: true, encoding: .utf8)
        let account = try accountRegistry.add(
            provider: .openrouter, label: "Fake OR", credentialPath: keyFile.path, kind: "apikey")
        let openrouter = try #require(registry.provider(for: .openrouter))
        await #expect(throws: OpenRouterProviderError.self) {
            try await openrouter.fetchUsage(
                AccountRef(id: AccountID(provider: .openrouter, key: account.accountKey), label: "Fake OR"))
        }
    }
}
