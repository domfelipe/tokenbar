import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F3 Task 4 — heartbeat v3: campo OPCIONAL `history7d` por provider
/// (`{"tokens": N, "costUsd": X|null}`) para o E2E validar persistência →
/// consulta. Presente SOMENTE quando a leitura do ciclo foi bem-sucedida
/// (`weekHistoryAvailable`); omitido sem DB/na falha — nunca fake. O resto do
/// contrato v2 (chaves, menuBarText) NÃO muda.
@Suite
struct HeartbeatHistoryTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func providers(_ display: ProviderDisplay) -> [ProviderID: ProviderDisplay] {
        [.claude: display]
    }

    private func claudeEntry(_ display: ProviderDisplay) throws -> [String: Any] {
        let payload = E2EHeartbeat.payload(
            menuBarText: "C:12.4k", providers: providers(display), now: now)
        return try #require(
            (payload["providers"] as? [String: Any])?["claude"] as? [String: Any])
    }

    // MARK: - history7d presente/omitido

    @Test("history7d presente com tokens e custo numérico quando a leitura foi bem-sucedida")
    func historyPresentWithCost() throws {
        let entry = try claudeEntry(ProviderDisplay(
            todayTokens: 12_400, todayCostUsd: 0.08,
            weekTokens: 45_600, weekCostUsd: 0.31, weekHistoryAvailable: true))
        let history = try #require(entry["history7d"] as? [String: Any])
        #expect(history["tokens"] as? Int64 == 45_600)
        #expect(history["costUsd"] as? Double == 0.31)
    }

    @Test("history7d com custo null EXPLÍCITO quando nada é computável (nulo ≠ omitido)")
    func historyWithExplicitNullCost() throws {
        let entry = try claudeEntry(ProviderDisplay(
            weekTokens: 0, weekCostUsd: nil, weekHistoryAvailable: true))
        let history = try #require(entry["history7d"] as? [String: Any])
        #expect(history["tokens"] as? Int64 == 0)
        // A chave existir prova que a consulta rodou; o valor null diz que
        // não há custo computável (sem preço — nunca 0 inventado).
        #expect(history["costUsd"] is NSNull)
    }

    @Test("history7d OMITIDO quando a leitura não ocorreu/falhou (flag false)")
    func historyOmittedWhenUnavailable() throws {
        // Valor "stale" do último ciclo bom no painel — mesmo assim o heartbeat
        // omite (falha → campo fora; nada desatualizado no contrato do E2E).
        let entry = try claudeEntry(ProviderDisplay(
            todayTokens: 10, weekTokens: 45_600, weekCostUsd: 0.31,
            weekHistoryAvailable: false))
        #expect(entry["history7d"] == nil)
        // Contrato v2 intocado quando não há nada novo a dizer.
        #expect(Set(entry.keys) == ["menuBar", "percent", "todayTokens", "authState", "fetchedAt"])
    }

    @Test("payload completo: provider com histórico e provider sem (zai) no MESMO payload")
    func mixedProviders() throws {
        let payload = E2EHeartbeat.payload(
            menuBarText: "C:12.4k Z:17%",
            providers: [
                .claude: ProviderDisplay(weekTokens: 1_077, weekCostUsd: 0.31, weekHistoryAvailable: true),
                .zai: ProviderDisplay(percent: 17, authState: .ok),
            ],
            now: now)
        let providers = try #require(payload["providers"] as? [String: Any])
        let claude = try #require(providers["claude"] as? [String: Any])
        #expect((try #require(claude["history7d"] as? [String: Any]))["tokens"] as? Int64 == 1_077)
        let zai = try #require(providers["zai"] as? [String: Any])
        #expect(zai["history7d"] == nil)
    }

    // MARK: - Render gate: menu bar NÃO muda

    @Test("history7d não aparece na string do menu bar e não re-renderiza o label")
    @MainActor
    func menuBarGateUntouched() {
        let withoutHistory = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
        ])
        let withHistory = MenuBarContent(providers: [
            .claude: ProviderDisplay(
                todayTokens: 12_400, todayCostUsd: 0.08,
                weekTokens: 45_600, weekCostUsd: 0.31, weekHistoryAvailable: true),
        ])
        #expect(withHistory.displayString() == withoutHistory.displayString())
        #expect(withHistory.displayString() == "C:12.4k")

        // Só o history7d mudou entre publicações → label intocado.
        let store = SnapshotStore()
        store.apply(withoutHistory)
        let before = store.menuBarText
        store.apply(withHistory)
        #expect(store.menuBarText == before)
        #expect(store.providers[.claude]?.weekHistoryAvailable == true)
    }

    // MARK: - Wiring do coordinator (heartbeat escrito com history7d real)

    @Test("coordinator: state.json ganha history7d do DB no claude e NADA no zai")
    @MainActor
    func coordinatorWritesHistory7dToHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4-hb-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Histórico de ONTEM semeado no MESMO banco que o coordinator abre.
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
            .addingTimeInterval(2 * 3_600)
        let seed = try AppDatabase.open(at: support.appendingPathComponent(AppDatabase.databaseName))
        try seed.persistBatch(
            provider: .claude, path: "/seed/historico.jsonl",
            events: [UsageEvent(
                ts: yesterday, provider: .claude,
                account: AccountID(provider: .claude, key: "local"),
                model: "claude-sonnet-4-6", inputTokens: 400, outputTokens: 600,
                cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)],
            endOffset: 2_000, resetToZero: false)

        // Corpus de hoje: 77 tok (33/44) — mesmo fixture do T2/T3.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = #"{"type":"assistant","timestamp":"\#(f.string(from: Date()))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":33,"output_tokens":44}}}"#
        try (line + "\n").write(to: claude.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: ["TOKENBAR_CLAUDE_DIR": claude.path],
            home: root,
            supportDirectory: support,
            e2eDirectory: e2e
        ))
        await coordinator.refreshAllNow()

        let data = try Data(contentsOf: e2e.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(json["providers"] as? [String: Any])

        // claude: persistência → consulta visível no heartbeat (1077 = ontem
        // 1000 + hoje 77; custo dos dois dias > 0).
        let claudeEntry = try #require(providers["claude"] as? [String: Any])
        let history = try #require(claudeEntry["history7d"] as? [String: Any])
        #expect(history["tokens"] as? Int64 == 1_077)
        #expect((history["costUsd"] as? Double ?? 0) > 0)

        // zai: sem ingest local → sem leitura de histórico → campo OMITIDO.
        let zaiEntry = try #require(providers["zai"] as? [String: Any])
        #expect(zaiEntry["history7d"] == nil)

        // A string do ícone segue o formato F1 (histórico não vaza pro menu bar).
        #expect(json["menuBarText"] as? String == "C:77")
    }

    /// PIN do review T4 (Important): o selfcheck constrói o coordinator com
    /// support dir PRÓPRIO e NUNCA criado + fábricas injetadas (offset em
    /// memória, snapshot nil) — ninguém criava o diretório, `DatabasePool`
    /// não abria, e o history7d ficava SEMPRE omitido no selfcheck. O fix
    /// cria o diretório no init do coordinator; este teste reproda o setup
    /// EXATO do selfcheck e fica vermelho se alguém remover o createDirectory.
    @Test("modo selfcheck (support dir inexistente, stores injetados): DB abre e history7d presente")
    @MainActor
    func selfcheckModeWithOwnSupportDirectoryIncludesHistory7d() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t5-selfcheck-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)  // NÃO criado
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: support.path))

        // Corpus com dados de HOJE (mesmo fixture dos outros testes).
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = #"{"type":"assistant","timestamp":"\#(f.string(from: Date()))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":33,"output_tokens":44}}}"#
        try (line + "\n").write(to: claude.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        // Setup IGUAL ao do SelfCheck.run: offset store em memória e snapshot
        // de ledger nil (somente-leitura sobre o mundo) — nenhuma fábrica
        // default para criar o diretório no caminho.
        final class MemOffsetStore: FileOffsetStoring, @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: FileCursor] = [:]
            func cursors() -> [String: FileCursor] {
                lock.lock(); defer { lock.unlock() }
                return storage
            }
            func set(_ cursor: FileCursor?, for path: String) throws {
                lock.lock(); defer { lock.unlock() }
                if let cursor { storage[path] = cursor } else { storage.removeValue(forKey: path) }
            }
        }
        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: ["TOKENBAR_CLAUDE_DIR": claude.path],
            home: root,
            supportDirectory: support,
            e2eDirectory: e2e,
            makeOffsetStore: { _, _ in MemOffsetStore() },
            makeLedgerSnapshotStore: { _, _ in nil }
        ))
        await coordinator.refreshAllNow()

        // DB criado no dir que ninguém criara + history7d presente com os
        // tokens do corpus (77) e custo computado (modelo precificado).
        let data = try Data(contentsOf: e2e.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(json["providers"] as? [String: Any])
        let claudeEntry = try #require(providers["claude"] as? [String: Any])
        let history = try #require(claudeEntry["history7d"] as? [String: Any])
        #expect(history["tokens"] as? Int64 == 77)
        #expect((history["costUsd"] as? Double ?? 0) > 0)
        // O próprio diretório passou a existir (o DB mora lá).
        #expect(FileManager.default.fileExists(
            atPath: support.appendingPathComponent(AppDatabase.databaseName).path))
    }
}
