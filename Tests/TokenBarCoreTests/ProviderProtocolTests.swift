import Foundation
import Testing
import TokenBarCore  // import público de propósito: o protocolo é API pública — se algo ficou internal, falha aqui

/// Provider mínimo p/ exercitar o protocolo via existencial e o registry.
private struct MockProvider: UsageProvider {
    let id: ProviderID
    let capabilities: ProviderCapabilities
    let accounts: [AccountRef]

    func discoverAccounts() async -> [AccountRef] { accounts }

    func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        UsageSnapshot(
            provider: id,
            account: account.id,
            windows: [],
            credits: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_788_000_000),
            source: .api,
            authState: .ok
        )
    }

    func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }
}

@Suite
struct ProviderProtocolTests {
    // MARK: - Capability math (OptionSet)

    @Test
    func capabilityMath() {
        let both: ProviderCapabilities = [.apiUsage, .localIngest]
        #expect(both.contains(.apiUsage))
        #expect(both.contains(.localIngest))
        #expect(!both.contains(.credits))
        #expect(!both.contains(.multiAccount))
        #expect(both.intersection(.credits).isEmpty)
        #expect(both.subtracting(.apiUsage) == .localIngest)
        #expect(ProviderCapabilities.localIngest.union(.credits) == [.localIngest, .credits])
        #expect(ProviderCapabilities().isEmpty)
    }

    // MARK: - Domínio de snapshots

    @Test
    func snapshotCodableRoundtripFull() throws {
        let snapshot = UsageSnapshot(
            provider: .claude,
            account: AccountID(provider: .claude, key: "local"),
            windows: [
                UsageWindow(kind: .session, usedFraction: 0.42, resetsAt: Date(timeIntervalSince1970: 1_788_003_600), label: "Sessão 5h"),
                UsageWindow(kind: .weekly, usedFraction: nil, resetsAt: nil, label: "Semanal"),
            ],
            credits: CreditsInfo(remaining: 12.5, unlimited: false),
            fetchedAt: Date(timeIntervalSince1970: 1_788_000_000),
            source: .api,
            authState: .ok
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data) == snapshot)
    }

    @Test
    func snapshotCodableRoundtripLocalModeWithNils() throws {
        // Modo local (spec §5 regra 2): frações desconhecidas, sem créditos.
        let snapshot = UsageSnapshot(
            provider: .codex,
            account: AccountID(provider: .codex, key: "local"),
            windows: [
                UsageWindow(kind: .daily, usedFraction: nil, resetsAt: Date(timeIntervalSince1970: 1_788_086_400), label: "Hoje"),
            ],
            credits: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_788_000_000),
            source: .localOnly,
            authState: .missing
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data) == snapshot)
    }

    @Test
    func creditsUnlimitedCodableRoundtrip() throws {
        let credits = CreditsInfo(remaining: nil, unlimited: true)
        let data = try JSONEncoder().encode(credits)
        #expect(try JSONDecoder().decode(CreditsInfo.self, from: data) == credits)
    }

    @Test
    func enumRawValues() {
        #expect(WindowKind.session.rawValue == "session")
        #expect(WindowKind.weekly.rawValue == "weekly")
        #expect(WindowKind.daily.rawValue == "daily")
        #expect(WindowKind.allCases == [.session, .weekly, .daily, .monthly])
        #expect(AuthState(rawValue: "invalid") == .invalid)
        #expect(DataSource(rawValue: "localOnly") == .localOnly)
    }

    @Test
    func accountRefCodableRoundtrip() throws {
        let ref = AccountRef(id: AccountID(provider: .zai, key: "main"), label: "Coding plan")
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(AccountRef.self, from: data) == ref)
    }

    // MARK: - Cursor e lote de ingest

    @Test
    func ingestCursorWrapsFileOffsets() throws {
        var cursor = IngestCursor()
        #expect(cursor.fileOffsets.isEmpty)
        cursor.fileOffsets["/tmp/a.jsonl"] = FileCursor(offset: 128)
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(IngestCursor.self, from: data)
        #expect(decoded == cursor)
        #expect(decoded.fileOffsets["/tmp/a.jsonl"]?.offset == 128)
    }

    // MARK: - Registry

    @Test
    func registryRegisterAndResolve() {
        let registry = ProviderRegistry()
        let mock = MockProvider(id: .codex, capabilities: [.apiUsage, .credits], accounts: [])
        registry.register(mock)
        let resolved = registry.provider(for: .codex)
        #expect(resolved?.id == .codex)
        #expect(resolved?.capabilities == [.apiUsage, .credits])
    }

    @Test
    func registryResolveUnknownReturnsNil() {
        let registry = ProviderRegistry()
        #expect(registry.provider(for: .openrouter) == nil)
    }

    @Test
    func registryDuplicateRegistrationReplaces() {
        let registry = ProviderRegistry()
        registry.register(MockProvider(id: .gemini, capabilities: [.localIngest], accounts: []))
        registry.register(MockProvider(id: .gemini, capabilities: [.apiUsage], accounts: []))
        #expect(registry.provider(for: .gemini)?.capabilities == [.apiUsage])
        #expect(registry.all.count == 1)
    }

    @Test
    func registryAllSortedByID() {
        let registry = ProviderRegistry()
        registry.register(MockProvider(id: .zai, capabilities: [], accounts: []))
        registry.register(MockProvider(id: .claude, capabilities: [], accounts: []))
        registry.register(MockProvider(id: .gemini, capabilities: [], accounts: []))
        #expect(registry.all.map(\.id) == [.claude, .gemini, .zai])
    }

    // MARK: - Protocolo via existencial

    @Test
    func protocolDispatchThroughExistential() async throws {
        let ref = AccountRef(id: AccountID(provider: .zai, key: "main"), label: "Coding plan")
        let provider: any UsageProvider = MockProvider(
            id: .zai,
            capabilities: [.apiUsage, .credits, .multiAccount],
            accounts: [ref]
        )
        #expect(await provider.discoverAccounts() == [ref])
        let snapshot = try await provider.fetchUsage(ref)
        #expect(snapshot.provider == .zai)
        #expect(snapshot.account == ref.id)
        #expect(snapshot.source == .api)
        let batch = try await provider.ingestLocal(ref, from: IngestCursor())
        #expect(batch.eventsApplied == 0)
        #expect(batch.nextCursor.fileOffsets.isEmpty)
    }
}
