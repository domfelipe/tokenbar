import Foundation
import Testing
@testable import TokenBarCore
@testable import TokenBarProviders

/// F4 Task 3 — providers multi-conta: descoberta MERGE (auto + registry,
/// dedupe por key), instância por conta registrada (events stampados com a
/// key da conta) e isolamento (`guardKnownAccount` continua valendo entre
/// instâncias). Fixtures 100% sintéticas.
@Suite
final class MultiAccountProviderTests {
    let dir: URL
    let now = Date(timeIntervalSince1970: 1_788_000_000)

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiacct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeRegistry() throws -> (AppDatabase, AccountRegistry) {
        let db = try AppDatabase.open(
            at: dir.appendingPathComponent("db-\(UUID().uuidString).sqlite"), calendar: calendar)
        return (db, AccountRegistry(database: db))
    }

    func writeTranscript(_ name: String, input: Int64, output: Int64) throws -> URL {
        let project = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line =
            #"{"type":"assistant","timestamp":"\#(f.string(from: now))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
        let file = project.appendingPathComponent("s1.jsonl")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Resolve o path como o `FileManager.enumerator` faz (realpath) — as
    /// chaves de marca d'água usam o path resolvido do scan.
    private func resolved(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    // MARK: - Descoberta MERGE

    @Test("claude: descoberta merge registry + auto, sem registry fica [local]")
    func claudeMergesRegistryWithAuto() async throws {
        let (_, registry) = try makeRegistry()
        let a = try registry.add(provider: .claude, label: "Work", credentialPath: "/tmp/w.json")
        let b = try registry.add(provider: .claude, label: "Personal", credentialPath: "/tmp/p.json")
        let inactive = try registry.add(provider: .claude, label: "Off", credentialPath: "/tmp/o.json")
        try registry.setActive(false, provider: .claude, accountKey: inactive.accountKey)

        let provider = ClaudeProvider(
            projectsDirectory: dir,
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accounts: registry)
        let refs = await provider.discoverAccounts()

        // Registry lista ordenado por label: "Personal" < "Work"; inativa fora.
        #expect(refs.count == 3)  // local + 2 ativas
        #expect(refs[0].id.key == "local")
        #expect(refs[1] == AccountRef(id: AccountID(provider: .claude, key: b.accountKey), label: "Personal"))
        #expect(refs[2] == AccountRef(id: AccountID(provider: .claude, key: a.accountKey), label: "Work"))
        #expect(!refs.contains { $0.id.key == inactive.accountKey }, "inativa não entra na descoberta")
        #expect(provider.capabilities == [.localIngest, .multiAccount])

        // Sem registry: comportamento F2 intacto.
        let plain = ClaudeProvider(
            projectsDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        #expect(await plain.discoverAccounts() == [plain.accountRef])
    }

    @Test("dedupe por key: registrada com key já visível não repete")
    func dedupeByKey() async throws {
        let (db, registry) = try makeRegistry()
        // INSERT direto com a key "local" — o add geraria acct-*, então
        // simulamos uma conta que colide com a auto-descoberta.
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (provider, account_id, label, kind, active, credential_path, directory_path)
                    VALUES ('claude', 'local', 'Duplicated', 'oauth', 1, '/tmp/x.json', '')
                    """)
        }

        let provider = ClaudeProvider(
            projectsDirectory: dir,
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accounts: registry)
        let refs = await provider.discoverAccounts()
        #expect(refs.map(\.id.key) == ["local"], "dedupe: 1 ocorrência só")
        #expect(refs[0].label == "local", "a auto-descoberta vence")
    }

    @Test("codex: merge com auth sintética + 2 registradas; zai idem sem credencial")
    func codexAndZaiMerge() async throws {
        let (_, registry) = try makeRegistry()
        let codexEntry = try registry.add(provider: .codex, label: "Team", credentialPath: "/tmp/team-auth.json")
        try registry.add(provider: .codex, label: "Side", credentialPath: "/tmp/side-auth.json")

        // Sem auth.json local: descoberta = só as registradas.
        let noAuth = CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("missing-auth.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://example.invalid")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accounts: registry)
        let refsNoAuth = await noAuth.discoverAccounts()
        #expect(refsNoAuth.map(\.label) == ["Side", "Team"])  // ordenação por label

        // Com auth.json local: local primeiro, registradas depois (dedupe por key).
        let authFile = dir.appendingPathComponent("auth.json")
        try Data("""
        {"tokens": {"access_token": "synthetic-never-real", "account_id": "acct1"}, "auth_mode": "chatgpt"}
        """.utf8).write(to: authFile)
        let withAuth = CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: authFile),
            client: UsageHTTPClient(baseURL: URL(string: "https://example.invalid")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accounts: registry)
        let refs = await withAuth.discoverAccounts()
        #expect(refs.first?.id.key == "local")
        #expect(refs.count == 3)
        #expect(refs.dropFirst().map(\.label).sorted() == ["Side", "Team"])
        #expect(refs[2].id.key == codexEntry.accountKey)  // "Team" (ordenação por label)

        // Zai: sem credencial local + 1 registrada → só a registrada.
        let zaiEntry = try registry.add(provider: .zai, label: "CN", credentialPath: "/tmp/zai-config.json")
        let zai = ZaiProvider(
            credentialReader: ZaiCredentialReader(
                configFileURL: dir.appendingPathComponent("missing-config.json"),
                credentialsFileURL: dir.appendingPathComponent("missing-creds.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://example.invalid")!),
            accounts: registry)
        let zaiRefs = await zai.discoverAccounts()
        #expect(zaiRefs == [AccountRef(id: AccountID(provider: .zai, key: zaiEntry.accountKey), label: "CN")])
        #expect(zai.capabilities == [.apiUsage, .multiAccount])
        #expect(noAuth.capabilities == [.apiUsage, .localIngest, .multiAccount])
    }

    // MARK: - Instância por conta registrada

    @Test("claude por conta: instância com accountKey próprio stampa eventos da conta")
    func claudePerAccountStampsEvents() async throws {
        let db = try AppDatabase.open(
            at: dir.appendingPathComponent("db-\(UUID().uuidString).sqlite"), calendar: calendar)
        let file = try writeTranscript("work-projects", input: 10, output: 20)

        let work = ClaudeProvider(
            projectsDirectory: dir.appendingPathComponent("work-projects"),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            persisting: db,
            accountKey: "acct-work",
            label: "Work")

        #expect(work.account == AccountID(provider: .claude, key: "acct-work"))
        let batch = try await work.ingestLocal(work.accountRef, from: IngestCursor(), now: now)
        #expect(batch.eventsApplied == 1)
        #expect(try db.dailyAggRows(provider: .claude).map(\.account) == ["acct-work"])
        // O scan resolve symlinks (realpath: /var → /private/var) — o hwm é
        // chaveado pelo path resolvido, igual ao corpus canônico da F1.
        #expect(try db.highWater(provider: .claude, path: resolved(file.path), accountKey: "acct-work") != nil)
        // Namespace por conta: a chave LEGADA (conta default) não é tocada.
        #expect(try db.highWater(provider: .claude, path: resolved(file.path)) == nil)

        // Snapshot local da conta registrada carrega a identidade dela.
        let snapshot = try await work.fetchUsage(work.accountRef)
        #expect(snapshot.account == AccountID(provider: .claude, key: "acct-work"))
    }

    @Test("isolamento: instância canônica rejeita conta de outra instância")
    func canonicalInstanceRejectsForeignAccount() async throws {
        let plain = ClaudeProvider(
            projectsDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        let foreign = AccountRef(id: AccountID(provider: .claude, key: "acct-work"), label: "Work")
        await #expect(throws: ClaudeProviderError(account: foreign.id)) {
            _ = try await plain.ingestLocal(foreign, from: IngestCursor(), now: now)
        }
        await #expect(throws: ClaudeProviderError(account: foreign.id)) {
            _ = try await plain.fetchUsage(foreign)
        }
    }

    @Test("codex por conta: auth file registrado alimenta o snapshot da conta")
    func codexPerAccountUsesRegisteredCredential() async throws {
        let authFile = dir.appendingPathComponent("team-auth.json")
        try Data("""
        {"tokens": {"access_token": "synthetic-never-real", "account_id": "team-acct"}, "auth_mode": "chatgpt"}
        """.utf8).write(to: authFile)

        let team = CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: authFile),
            client: UsageHTTPClient(baseURL: URL(string: "https://example.invalid")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accountKey: "acct-team",
            label: "Team")

        // Rede morta → rethrow (spec §5 regra 3) — mas a credencial FOI lida
        // (o request saiu com a identidade da conta; sem credencial seria
        // snapshot .missing sem request). Verificamos via erro de rede.
        do {
            _ = try await team.fetchUsage(team.accountRef)
            Issue.record("base morta deveria lançar network")
        } catch let error as UsageHTTPError {
            if case .network = error {
                // esperado: request saiu (credencial lida) contra base morta
            } else {
                Issue.record("erro esperado era .network, veio \(error)")
            }
        }
        // Auth ausente → degrada .missing SEM request (spec §1.6).
        let missing = CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("nope.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://example.invalid")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            accountKey: "acct-broken",
            label: "Broken")
        let degraded = try await missing.fetchUsage(missing.accountRef)
        #expect(degraded.authState == .missing)
        #expect(degraded.source == .localOnly)
        #expect(degraded.account.key == "acct-broken")
    }
}
