import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F3 Task 3 — histórico 7d no painel: linha por provider ganha
/// "· 7d: <tok> ~$<custo>" SEM mudar a string do menu bar (render gate F1
/// permanece) e SEM mudar o contrato v2 do heartbeat (Task 4 cuida dele).
@Suite
struct PanelHistoryTests {
    // MARK: - Linha do painel

    @Test("linha de tokens ganha o segmento 7d com custo")
    func tokensLineWithWeekSegment() {
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(
                todayTokens: 12_400, todayCostUsd: 0.08,
                weekTokens: 45_600, weekCostUsd: 0.31, source: .localOnly),
        ])
        #expect(content.menuLines() == [
            "C Claude: 12.4k hoje ~$0.08 · 7d: 45.6k ~$0.31 (local)",
        ])
    }

    @Test("linha de percent também exibe o 7d (antes do sufixo de reset)")
    func percentLineWithWeekSegment() {
        let content = MenuBarContent(providers: [
            .codex: ProviderDisplay(
                percent: 62, todayCostUsd: 1.23,
                weekTokens: 210_000, weekCostUsd: 2.1,
                authState: .ok, source: .api,
                resetsAt: Date(timeIntervalSince1970: 7_200),
                fetchedAt: Date(timeIntervalSince1970: 0)),
        ])
        #expect(content.menuLines(now: Date(timeIntervalSince1970: 0)) == [
            "X Codex: 62% ~$1.23 · 7d: 210.0k ~$2.10 — reseta em 2h",
        ])
    }

    @Test("7d sem custo computável mantém só tokens (NULL ≠ 0)")
    func weekSegmentWithoutCost() {
        let content = MenuBarContent(providers: [
            .gemini: ProviderDisplay(todayTokens: 500, weekTokens: 9_800, source: .localOnly),
        ])
        #expect(content.menuLines() == ["G Gemini: 500 hoje · 7d: 9.8k (local)"])
    }

    @Test("sem histórico na janela (0 tokens) o segmento 7d é omitido")
    func weekSegmentOmittedWhenEmpty() {
        let content = MenuBarContent(providers: [
            .zai: ProviderDisplay(todayTokens: 3_100, weekTokens: 0, source: .localOnly),
        ])
        #expect(content.menuLines() == ["Z Z.ai: 3.1k hoje (local)"])
    }

    // MARK: - Render gate: menu bar NÃO muda

    @Test("7d não aparece na string do menu bar e não re-renderiza o label")
    @MainActor
    func menuBarStringUnchangedByWeek() {
        let withoutWeek = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
        ])
        let withWeek = MenuBarContent(providers: [
            .claude: ProviderDisplay(
                todayTokens: 12_400, todayCostUsd: 0.08,
                weekTokens: 45_600, weekCostUsd: 0.31),
        ])
        #expect(withWeek.displayString() == withoutWeek.displayString())
        #expect(withWeek.displayString() == "C:12.4k")

        // Gate: publicar conteúdo cuja ÚNICA diferença é o 7d não toca no label.
        let store = SnapshotStore()
        store.apply(withoutWeek)
        let before = store.menuBarText
        store.apply(withWeek)
        #expect(store.menuBarText == before)
        #expect(store.providers[.claude]?.weekTokens == 45_600)
    }

    // MARK: - Wiring: o 7d vem do DB pelo ciclo do coordinator

    @Test("coordinator: ciclo publica weekTokens/weekCostUsd do DB na linha do painel")
    @MainActor
    func coordinatorPublishesWeekTotal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-week-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Histórico de ONTEM semeado direto no MESMO banco que o coordinator
        // vai abrir (support/tokenbar.sqlite) — 1000 tok em claude-sonnet.
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

        // Corpus de hoje: 77 tok (33/44) — mesmo fixture do teste T2.
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

        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 77)
        #expect(display.weekTokens == 1_077)  // ontem (1000) + hoje (77)
        let weekCost = try #require(display.weekCostUsd)
        #expect(weekCost > 0)

        // Linha do painel com os DOIS horizontes; menu bar segue formato F1.
        let menuLine = try #require(coordinator.store.menuLines.first)
        #expect(menuLine.hasPrefix("C Claude: 77 hoje "))
        #expect(menuLine.contains("· 7d: 1.1k"))
        #expect(coordinator.store.menuBarText == "C:77")

        // Heartbeat v2 não mudou de contrato: sem campo de semana (Task 4).
        let data = try Data(contentsOf: e2e.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let claudeEntry = try #require((json["providers"] as? [String: Any])?["claude"] as? [String: Any])
        #expect(claudeEntry["weekTokens"] == nil)
    }
}
