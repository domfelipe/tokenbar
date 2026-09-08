import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F3 Task 2 — custo do dia no painel e no heartbeat v2:
/// linha do painel ganha "~$X.XX" (tokens ou % — o que vier primeiro),
/// provider sem custo mantém só tokens, e a string do MENU BAR não muda
/// formato nenhum (render gate F1: "C:12.4k X:0% Z:17%").
@Suite
struct PricingDisplayTests {
    // MARK: - Formatação do custo

    @Test("formatEstimatedUSD: 2 decimais; abaixo de 1 centavo, 4")
    func costFormatting() {
        #expect(formatEstimatedUSD(0) == "~$0.00")
        #expect(formatEstimatedUSD(0.08) == "~$0.08")
        #expect(formatEstimatedUSD(12.456) == "~$12.46")   // arredondamento p/ cima
        #expect(formatEstimatedUSD(1234.5) == "~$1234.50")
        // Custo pequeno real não pode virar "~$0.00" (esconderia gasto).
        #expect(formatEstimatedUSD(0.000759) == "~$0.0008")
        #expect(formatEstimatedUSD(0.009) == "~$0.0090")
    }

    // MARK: - Linha do painel

    @Test("linha de tokens ganha o custo do dia")
    func tokensLineWithCost() {
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400, todayCostUsd: 0.08, source: .localOnly),
        ])
        #expect(content.menuLines() == ["C Claude: 12.4k hoje ~$0.08 (local)"])
    }

    @Test("linha de percent também exibe o custo do dia")
    func percentLineWithCost() {
        let content = MenuBarContent(providers: [
            .codex: ProviderDisplay(
                percent: 62, todayCostUsd: 1.23, authState: .ok, source: .api,
                resetsAt: Date(timeIntervalSince1970: 7_200),
                fetchedAt: Date(timeIntervalSince1970: 0)),
        ])
        // Custo vem logo após a métrica, ANTES do sufixo de reset.
        #expect(content.menuLines(now: Date(timeIntervalSince1970: 0)) == [
            "X Codex: 62% ~$1.23 — reseta em 2h",
        ])
    }

    @Test("provider sem custo nenhum mantém só tokens")
    func providerWithoutCostKeepsTokensOnly() {
        let content = MenuBarContent(providers: [
            .zai: ProviderDisplay(todayTokens: 3_100, source: .localOnly),
        ])
        #expect(content.menuLines() == ["Z Z.ai: 3.1k hoje (local)"])
    }

    // MARK: - Render gate: menu bar NÃO muda

    @Test("custo não aparece na string do menu bar (formato F1 preservado)")
    func menuBarStringUnchangedByCost() {
        let withoutCost = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
            .codex: ProviderDisplay(percent: 0),
            .zai: ProviderDisplay(percent: 17),
        ])
        let withCost = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400, todayCostUsd: 0.08),
            .codex: ProviderDisplay(percent: 0, todayCostUsd: 0.5),
            .zai: ProviderDisplay(percent: 17, todayCostUsd: 2),
        ])
        #expect(withCost.displayString() == withoutCost.displayString())
        #expect(withCost.displayString() == "C:12.4k X:0% Z:17%")
    }

    @Test("render gate: custo novo NÃO re-renderiza o label do ícone")
    @MainActor
    func renderGateIgnoresCostChange() {
        let store = SnapshotStore()
        store.apply(MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400, todayCostUsd: nil),
        ]))
        #expect(store.menuBarText == "C:12.4k")
        // Só o custo mudou → mesma string exibida → label intocado.
        store.apply(MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400, todayCostUsd: 0.08),
        ]))
        #expect(store.menuBarText == "C:12.4k")
        #expect(store.providers[.claude]?.todayCostUsd == 0.08)
        #expect(store.menuLines == ["C Claude: 12.4k hoje ~$0.08 (local)"])
    }

    // MARK: - Heartbeat v2 (todayCostUsd opcional)

    @Test("heartbeat: todayCostUsd presente como número quando há custo")
    func heartbeatIncludesCostAsNumber() throws {
        let payload = E2EHeartbeat.payload(
            menuBarText: "C:12.4k",
            providers: [
                .claude: ProviderDisplay(todayTokens: 12_400, todayCostUsd: 0.0805, authState: .ok),
            ],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let claude = try #require(
            (payload["providers"] as? [String: Any])?["claude"] as? [String: Any])
        let cost = try #require(claude["todayCostUsd"] as? Double)
        #expect(cost == 0.0805)
    }

    @Test("heartbeat: sem custo o campo é OMITIDO (contrato v2 não muda)")
    func heartbeatOmitsCostWhenNil() throws {
        let payload = E2EHeartbeat.payload(
            menuBarText: "TB",
            providers: [
                .zai: ProviderDisplay(todayTokens: 10, authState: .ok),
            ],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let zai = try #require(
            (payload["providers"] as? [String: Any])?["zai"] as? [String: Any])
        #expect(zai["todayCostUsd"] == nil)
        #expect(Set(zai.keys) == ["menuBar", "percent", "todayTokens", "authState", "fetchedAt"])
    }

    // MARK: - Wiring do coordinator (custo do dia sai do DB pro display)

    @Test("coordinator: ciclo com DB publica todayCostUsd no display e heartbeat")
    @MainActor
    func coordinatorPublishesTodayCost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t2-cost-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Corpus sintético claude-sonnet-4-6: (33×3 + 44×15)/1e6 = 0.000759.
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

        let expected = (Double(33) * 3 + Double(44) * 15) / 1_000_000
        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 77)
        let cost = try #require(display.todayCostUsd)
        #expect(abs(cost - expected) < 1e-12)

        // E o heartbeat reflete o mesmo número (campo numérico).
        let data = try Data(contentsOf: e2e.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let claudeEntry = try #require((json["providers"] as? [String: Any])?["claude"] as? [String: Any])
        let heartbeatCost = try #require(claudeEntry["todayCostUsd"] as? Double)
        #expect(abs(heartbeatCost - expected) < 1e-12)

        // A string do ícone segue o formato F1 (custo não vaza pro menu bar).
        #expect(json["menuBarText"] as? String == "C:77")
    }
}
