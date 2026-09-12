import Foundation
import Testing
import Observation
import TokenBarCore
@testable import TokenBarUI

// Swift 6: onChange é @Sendable, então var local não pode ser capturado/mutado.
// Box mínimo equivalente ao `var changes = 0` do brief (mesma semântica).
private final class ChangeCounter: @unchecked Sendable {
    var count = 0
}

// T7: display multi-provider (siglas D5, % vs tokens, ordem fixa, provider sem
// dado some) + render gate por-provider do SnapshotStore + heartbeat v2.
struct MenuBarContentTests {
    @Test
    func testAbbrevTokens() {
        #expect(abbrevTokens(0) == "0")
        #expect(abbrevTokens(999) == "999")
        #expect(abbrevTokens(1_000) == "1.0k")
        #expect(abbrevTokens(1_234) == "1.2k")
        #expect(abbrevTokens(12_345) == "12.3k")
        #expect(abbrevTokens(2_300_000) == "2.3M")
        #expect(abbrevTokens(1_200_000_000) == "1.2G")
    }

    // MARK: - Siglas D5

    @Test
    func testSiglasD5() {
        #expect(MenuBarContent.sigla(for: .claude) == "C")
        #expect(MenuBarContent.sigla(for: .codex) == "X")
        #expect(MenuBarContent.sigla(for: .gemini) == "G")
        #expect(MenuBarContent.sigla(for: .zai) == "Z")
        // F5 (ruling F5-SIGLAS): cursor=U, openrouter=O, qwen/alibaba=Q,
        // antigravity=V, deepseek=D, grok=K — G conflita com gemini; todas
        // únicas (docs/specs/f5-providers.md + decisões F5 na T7).
        #expect(MenuBarContent.sigla(for: .cursor) == "U")
        #expect(MenuBarContent.sigla(for: .openrouter) == "O")
        #expect(MenuBarContent.sigla(for: .alibaba) == "Q")
        #expect(MenuBarContent.sigla(for: .antigravity) == "V")
        #expect(MenuBarContent.sigla(for: .deepseek) == "D")
        #expect(MenuBarContent.sigla(for: .grok) == "K")
        // Tabela toda sem colisão de siglas.
        let all = Set(MenuBarContent.siglas.values)
        #expect(all.count == MenuBarContent.siglas.count)
    }

    // MARK: - String do menu bar

    @Test
    func testEmptyContentShowsPlaceholder() {
        #expect(MenuBarContent.empty.displayString() == "TB")
    }

    @Test
    func testSingleProviderTokens() {
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
        ])
        #expect(content.displayString() == "C:12.4k")
    }

    @Test
    func testPercentBeatsTokensWhenWindowKnown() {
        // Provider com janela conhecida mostra % (D5), mesmo com tokens locais.
        let content = MenuBarContent(providers: [
            .codex: ProviderDisplay(percent: 62.4, todayTokens: 999),
        ])
        #expect(content.displayString() == "X:62%")
    }

    @Test
    func testTokensWhenNoWindow() {
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400, source: .localOnly),
            .gemini: ProviderDisplay(todayTokens: 3_100, source: .localOnly),
        ])
        #expect(content.displayString() == "C:12.4k G:3.1k")
    }

    @Test
    func testFixedOrderClaudeCodexGeminiZai() {
        // Ordem fixa C, X, G, Z — independe da ordem de inserção no dicionário.
        let content = MenuBarContent(providers: [
            .zai: ProviderDisplay(percent: 81),
            .gemini: ProviderDisplay(todayTokens: 3_100),
            .codex: ProviderDisplay(percent: 62),
            .claude: ProviderDisplay(todayTokens: 12_400),
        ])
        #expect(content.displayString() == "C:12.4k X:62% G:3.1k Z:81%")
    }

    @Test
    func testProviderWithoutDataDisappears() {
        // Sem % e sem tokens → some da string (não vira "Z:0").
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
            .zai: ProviderDisplay(),  // sem dado nenhum (degradado)
        ])
        #expect(content.displayString() == "C:12.4k")
        #expect(content.displayFragment(for: .zai) == nil)
    }

    @Test
    func testCriticalWindowPicksHighestFraction() {
        // Regra D5: janela com usedFraction mais próximo de 1 = mais crítica.
        let windows = [
            UsageWindow(kind: .weekly, usedFraction: 0.40, resetsAt: nil, label: "Semanal"),
            UsageWindow(kind: .session, usedFraction: 0.62, resetsAt: nil, label: "5h"),
        ]
        let critical = criticalWindow(in: windows)
        #expect(critical?.label == "5h")
        #expect(criticalWindow(in: [UsageWindow(kind: .daily, usedFraction: nil, resetsAt: nil, label: "Hoje")]) == nil)
        #expect(criticalWindow(in: []) == nil)
    }

    @Test
    func testDisplayFragmentAndMenuLines() {
        let content = MenuBarContent(providers: [
            .codex: ProviderDisplay(
                percent: 62, todayTokens: 0, authState: .ok, source: .api,
                resetsAt: Date(timeIntervalSince1970: 7_200),  // "2h" a partir de 0
                fetchedAt: Date(timeIntervalSince1970: 0)
            ),
            .claude: ProviderDisplay(
                percent: nil, todayTokens: 12_400, authState: .ok, source: .localOnly,
                resetsAt: Date(timeIntervalSince1970: 46_800),  // 13h
                fetchedAt: Date(timeIntervalSince1970: 0)
            ),
            .zai: ProviderDisplay(),  // sem dado → sem linha
        ])
        let now = Date(timeIntervalSince1970: 0)
        #expect(content.displayFragment(for: .codex) == "X:62%")
        #expect(content.displayFragment(for: .claude) == "C:12.4k")
        #expect(content.menuLines(now: now) == [
            "C Claude: 12.4k hoje — reseta em 13h (local)",
            "X Codex: 62% — reseta em 2h",
        ])
    }

    @Test
    func testResetSuffixBounds() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(MenuBarContent.resetSuffix(from: now, to: now.addingTimeInterval(59)) == "reseta em 1min")
        #expect(MenuBarContent.resetSuffix(from: now, to: now.addingTimeInterval(3_600)) == "reseta em 1h")
        #expect(MenuBarContent.resetSuffix(from: now, to: now.addingTimeInterval(432_000)) == "reseta em 5d")
        // Janela vencida → sem sufixo (nada a prometer).
        #expect(MenuBarContent.resetSuffix(from: now, to: now.addingTimeInterval(-1)) == nil)
    }

    // MARK: - Render gate (SnapshotStore per-provider)

    @Test
    @MainActor
    func testRenderGateSkipsEqualContent() {
        let store = SnapshotStore()
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
        ])
        store.apply(content)
        #expect(store.providers[.claude]?.todayTokens == 12_400)

        let counter = ChangeCounter()
        withObservationTracking {
            _ = store.menuBarText
        } onChange: { counter.count += 1 }

        store.apply(content)                                         // igual → NÃO marca
        #expect(counter.count == 0)
        #expect(store.menuBarText == "C:12.4k")

        // Conteúdo diferente mas mesma string renderizada (12_401 → "C:12.4k"):
        // o gate compara a string — label não re-renderiza, estado atualiza.
        let changedTokens = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_401),
        ])
        store.apply(changedTokens)
        #expect(counter.count == 0)
        #expect(store.menuBarText == "C:12.4k")
        #expect(store.providers[.claude]?.todayTokens == 12_401)

        // String exibida diferente → marca exatamente 1×.
        store.apply(MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_500),
        ]))
        #expect(counter.count == 1)
        #expect(store.menuBarText == "C:12.5k")
    }

    @Test
    @MainActor
    func testMenuLinesExposePanelState() {
        let store = SnapshotStore()
        #expect(store.menuLines.isEmpty)
        store.apply(MenuBarContent(providers: [
            .zai: ProviderDisplay(percent: 81, authState: .ok, source: .api),
        ]))
        #expect(store.menuLines == ["Z Z.ai: 81%"])
    }

    // MARK: - Heartbeat v2

    @Test
    func testHeartbeatV2PayloadShape() throws {
        let providers: [ProviderID: ProviderDisplay] = [
            .claude: ProviderDisplay(todayTokens: 12_400, authState: .ok, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .codex: ProviderDisplay(percent: 62, todayTokens: 0, authState: .ok, source: .api, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .gemini: ProviderDisplay(),
            .zai: ProviderDisplay(authState: .invalid),
        ]
        let payload = E2EHeartbeat.payload(
            menuBarText: "C:12.4k X:62%",
            providers: providers,
            errors: [.zai: "unauthorized"],
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["menuBarText"] as? String == "C:12.4k X:62%")
        #expect(json["updatedAt"] as? String == "2023-11-14T22:15:00Z")  // 1_700_000_100

        let providersJSON = try #require(json["providers"] as? [String: Any])
        #expect(Set(providersJSON.keys) == ["claude", "codex", "gemini", "zai"])

        let claude = try #require(providersJSON["claude"] as? [String: Any])
        #expect(claude["menuBar"] as? String == "C:12.4k")
        #expect(claude["percent"] is NSNull)
        #expect(claude["todayTokens"] as? Int64 == 12_400)
        #expect(claude["authState"] as? String == "ok")

        let codex = try #require(providersJSON["codex"] as? [String: Any])
        #expect(codex["menuBar"] as? String == "X:62%")
        #expect(codex["percent"] as? Int == 62)

        let gemini = try #require(providersJSON["gemini"] as? [String: Any])
        #expect(gemini["menuBar"] is NSNull)  // sem dado → null (degradado visível)
        #expect(gemini["percent"] is NSNull)

        let zai = try #require(providersJSON["zai"] as? [String: Any])
        #expect(zai["authState"] as? String == "invalid")
        #expect(zai["error"] as? String == "unauthorized")
        // Chaves fixas por provider (contrato v2) + error opcional.
        #expect(Set(zai.keys) == ["menuBar", "percent", "todayTokens", "authState", "fetchedAt", "error"])
    }
}

// MARK: - Visibilidade de providers no texto (F5 Task 3)

/// Checkbox da janela de Settings: provider fora do conjunto NÃO aparece no
/// texto do menu bar/linhas mesmo com dados; default = todos (comportamento
/// de quem nunca abriu settings). O gate da F1 segue: mudança que não altera
/// a string não re-renderiza o label.
struct MenuBarVisibilityTests {
    private func contentWithAllProviders() -> [ProviderID: ProviderDisplay] {
        [
            .claude: ProviderDisplay(percent: 20.0, todayTokens: 12_400),
            .codex: ProviderDisplay(percent: 62.4, todayTokens: 999),
            .gemini: ProviderDisplay(todayTokens: 3_100, source: .localOnly),
            .zai: ProviderDisplay(percent: 17.0),
        ]
    }

    @Test
    func defaultVisibilityKeepsEverything() {
        let content = MenuBarContent(providers: contentWithAllProviders())
        #expect(content.displayString() == "C:20% X:62% G:3.1k Z:17%")
    }

    @Test
    func hiddenProviderWithDataDisappearsFromText() {
        var visible = Set(ProviderID.allCases)
        visible.remove(.codex)
        visible.remove(.zai)
        let content = MenuBarContent(
            providers: contentWithAllProviders(), visibleProviders: visible)
        #expect(content.displayString() == "C:20% G:3.1k")
        // Linhas do painel/legado respeitam o mesmo conjunto.
        #expect(content.menuLines(now: Date()).allSatisfy { !$0.hasPrefix("X ") && !$0.hasPrefix("Z ") })
    }

    @Test
    func hidingEverythingShowsTB() {
        let content = MenuBarContent(
            providers: contentWithAllProviders(), visibleProviders: [])
        #expect(content.displayString() == "TB")
    }

    @Test
    func hidingProviderWithoutDataChangesNothing() {
        var providers = contentWithAllProviders()
        providers[.copilot] = ProviderDisplay()  // sem dados: nunca aparece
        let all = MenuBarContent(providers: providers)
        let withoutCopilot = MenuBarContent(
            providers: providers, visibleProviders: Set(ProviderID.allCases).subtracting([.copilot]))
        // Mesma string exibida → o render gate NÃO re-renderiza o label.
        #expect(all.displayString() == withoutCopilot.displayString())
    }
}

// MARK: - Extras visuais do label (M1: pace compacto + reset)

/// Fragmentos SÓ de pintura (`ProviderMenuBarLabel`): a string canônica
/// (`displayString`, AX, heartbeat) nunca os contém — Regra 9: teste cobre
/// o requisito (visual ≠ canônico) sem redefinir sucesso dos gates.
struct MenuBarVisualFragmentsTests {
    @Test
    func paceFragmentMatchesCodexBarCompactForm() {
        // Déficit → "+N%"; reserva → "-N%"; no ritmo → "0%"; sem forecast → nil.
        #expect(menuBarPaceFragment(nil) == nil)
        #expect(menuBarPaceFragment(PacingForecast(
            exhaustedIn: 9_600, projectedFraction: 1.69, deficitPct: 69)) == "+69%")
        #expect(menuBarPaceFragment(PacingForecast(
            exhaustedIn: nil, projectedFraction: 0.5, deficitPct: nil)) == "-50%")
        #expect(menuBarPaceFragment(PacingForecast(
            exhaustedIn: nil, projectedFraction: 1.0, deficitPct: nil)) == "0%")
        // Forecast degenerado (projeção não-positiva) → sem token, nunca chute.
        #expect(menuBarPaceFragment(PacingForecast(
            exhaustedIn: nil, projectedFraction: 0, deficitPct: nil)) == nil)
    }

    @Test
    func resetFragmentUsesPanelCountdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(menuBarResetFragment(resetsAt: nil, now: now) == nil)
        #expect(menuBarResetFragment(
            resetsAt: now.addingTimeInterval(-60), now: now) == nil)  // vencido
        #expect(menuBarResetFragment(
            resetsAt: now.addingTimeInterval(2 * 3_600 + 44 * 60),
            now: now) == "↻ 2h 44m")
    }

    @Test
    func visualFragmentsNeverLeakIntoCanonicalString() {
        // Mesmo com pacing + reset, a string canônica é só sigla:valor.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let content = MenuBarContent(providers: [
            .codex: ProviderDisplay(
                percent: 74,
                resetsAt: now.addingTimeInterval(6 * 86_400 + 16 * 3_600),
                fetchedAt: now,
                pacing: PacingForecast(
                    exhaustedIn: 9_840, projectedFraction: 1.69, deficitPct: 69)),
        ])
        #expect(content.displayString() == "X:74%")
    }
}
