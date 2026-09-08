import AppKit
import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

// MARK: - Seleção de abas (view-model puro)

@Suite
struct PanelSelectionTests {
    private func sampleProviders() -> [ProviderID: ProviderDisplay] {
        [
            .claude: ProviderDisplay(todayTokens: 12_400),
            .codex: ProviderDisplay(percent: 62),
            // gemini/zai SEM dado: não ganham aba (aba = provider com dado).
        ]
    }

    @Test("abas = providers com dado, ordem D5 (C, X, G, Z)")
    func tabOrderIsD5WithDataOnly() {
        let order = ProviderPanelModel.tabOrder(providers: sampleProviders())
        #expect(order == [.claude, .codex])
    }

    @Test("seleção nil → primeira aba com dado; escolha válida é preservada")
    func selectionDefaultsAndPreserves() {
        let providers = sampleProviders()
        #expect(ProviderPanelModel.effectiveSelection(selected: nil, providers: providers) == .claude)
        #expect(ProviderPanelModel.effectiveSelection(selected: .codex, providers: providers) == .codex)
    }

    @Test("seleção de provider que perdeu dado cai na primeira aba viva (nunca aba morta)")
    func selectionFallsBackWhenTabLosesData() {
        var providers = sampleProviders()
        providers[.claude] = nil
        #expect(ProviderPanelModel.effectiveSelection(selected: .claude, providers: providers) == .codex)
        #expect(ProviderPanelModel.effectiveSelection(selected: nil, providers: providers) == .codex)
    }
}

// MARK: - Countdown relativo de reset

@Suite
struct PanelCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("formato '6d 16h' acima de um dia")
    func daysAndHours() {
        let resets = now.addingTimeInterval(6 * 86_400 + 16 * 3_600)
        #expect(ProviderPanelModel.countdownText(from: now, to: resets) == "6d 16h")
    }

    @Test("formato '2h 44m' entre 1h e 24h")
    func hoursAndMinutes() {
        let resets = now.addingTimeInterval(2 * 3_600 + 44 * 60)
        #expect(ProviderPanelModel.countdownText(from: now, to: resets) == "2h 44m")
        let sub = now.addingTimeInterval(90 * 60)
        #expect(ProviderPanelModel.countdownText(from: now, to: sub) == "1h 30m")
    }

    @Test("abaixo de 1h só minutos; mínimo 1m")
    func minutesOnly() {
        #expect(ProviderPanelModel.countdownText(from: now, to: now.addingTimeInterval(44 * 60)) == "44m")
        #expect(ProviderPanelModel.countdownText(from: now, to: now.addingTimeInterval(20)) == "1m")
    }

    @Test("reset no passado → 'renewed' / 'Renewed' (nada a prometer da janela velha)")
    func pastRenews() {
        let resets = now.addingTimeInterval(-5 * 60)
        #expect(ProviderPanelModel.countdownText(from: now, to: resets) == "renewed")
        #expect(ProviderPanelModel.renewText(from: now, to: resets) == "Renewed")
        #expect(ProviderPanelModel.renewText(from: now, to: now.addingTimeInterval(6 * 86_400)) == "Renews in 6d 0h")
    }
}

// MARK: - WindowBarRow (estado puro da linha de janela)

@Suite
struct PanelWindowRowTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("janela com fração: 'Weekly 74% used' + barra + countdown 'Renews in 6d 16h'")
    func weeklyWindowRow() {
        let window = UsageWindow(
            kind: .weekly, usedFraction: 0.74,
            resetsAt: now.addingTimeInterval(6 * 86_400 + 16 * 3_600),
            label: "Semanal")
        let rows = ProviderPanelModel.windowRows(windows: [window], now: now)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.usageText == "Weekly 74% used")
        #expect(row.fraction == 0.74)
        #expect(row.countdownText == "Renews in 6d 16h")
    }

    @Test("fração desconhecida (modo local): sem barra, título 'Daily window', countdown mantido")
    func localDailyWindowRow() {
        let window = UsageWindow(
            kind: .daily, usedFraction: nil,
            resetsAt: now.addingTimeInterval(8 * 3_600),
            label: "Hoje")
        let rows = ProviderPanelModel.windowRows(windows: [window], now: now)
        #expect(rows[0].usageText == "Daily window")
        #expect(rows[0].fraction == nil)
        #expect(rows[0].countdownText == "Renews in 8h 0m")
    }

    @Test("janela sem resetsAt → só contagem (sem countdown inventado); ids únicos p/ janelas repetidas")
    func windowWithoutResetAndUniqueIds() {
        let windows = [
            UsageWindow(kind: .session, usedFraction: 0.5, resetsAt: nil, label: "5h"),
            UsageWindow(kind: .daily, usedFraction: 0.2, resetsAt: nil, label: "d1"),
            UsageWindow(kind: .daily, usedFraction: 0.1, resetsAt: nil, label: "d2"),
        ]
        let rows = ProviderPanelModel.windowRows(windows: windows, now: now)
        #expect(rows[0].countdownText == nil)
        #expect(rows[1].countdownText == nil)
        #expect(Set(rows.map(\.id)).count == 3)
    }
}

// MARK: - Pacing condicional

@Suite
struct PanelPacingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("forecast com esgotamento → 'Estimated — exhausts in 2h 44m'")
    func exhaustText() {
        let forecast = PacingForecast(exhaustedIn: 2 * 3_600 + 44 * 60, projectedFraction: 1.2, deficitPct: 20)
        #expect(ProviderPanelModel.pacingText(forecast, now: now) == "Estimated — exhausts in 2h 44m")
    }

    @Test("forecast sem esgotamento (taxa flat/queda) → 'should last until renew'")
    func lastUntilRenew() {
        let forecast = PacingForecast(exhaustedIn: nil, projectedFraction: 0.4, deficitPct: nil)
        #expect(ProviderPanelModel.pacingText(forecast, now: now) == "Estimated — should last until renew")
    }

    @Test("sem forecast → linha some (menos de 2 pontos, janela sem reset/fração)")
    func nilForecastHidesRow() {
        #expect(ProviderPanelModel.pacingText(nil, now: now) == nil)
    }

    @Test("disclaimer curto acompanha a linha de pacing")
    func disclaimer() {
        #expect(ProviderPanelModel.pacingDisclaimer == "estimate — not a guarantee")
    }
}

// MARK: - Custos hoje/30d

@Suite
struct PanelCostsTests {
    @Test("custos e tokens 30d no formato 'Today ~$X · 30d ~$Y · 8.9G tok'")
    func fullLine() {
        #expect(
            ProviderPanelModel.costsText(todayCostUsd: 0.08, monthCostUsd: 2.1, monthTokens: 8_900_000_000)
                == "Today ~$0.08 · 30d ~$2.10 · 8.9G tok")
    }

    @Test("segmentos sem dado são omitidos (custo nil = NULL ≠ 0; nada vira zero fake)")
    func partialSegments() {
        #expect(ProviderPanelModel.costsText(todayCostUsd: nil, monthCostUsd: 1.5, monthTokens: 0) == "30d ~$1.50")
        #expect(ProviderPanelModel.costsText(todayCostUsd: 0.005, monthCostUsd: nil, monthTokens: 0) == "Today ~$0.0050")
    }

    @Test("nada computável → linha some")
    func emptyLine() {
        #expect(ProviderPanelModel.costsText(todayCostUsd: nil, monthCostUsd: nil, monthTokens: 0) == nil)
    }
}

// MARK: - Header (updated Xs ago + badge)

@Suite
struct PanelHeaderTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("'updated Xs ago' em segundos/minutos/horas; nunca ciclado → 'not updated yet'")
    func updatedText() {
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(-42)) == "updated 42s ago")
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(-90)) == "updated 1m ago")
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(-2 * 3_600)) == "updated 2h ago")
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: Date(timeIntervalSince1970: 0)) == "not updated yet")
    }

    @Test("badge: local / auth / no auth / auth invalid")
    func authBadge() {
        #expect(ProviderPanelModel.authBadgeText(source: .localOnly, authState: .ok) == "local")
        #expect(ProviderPanelModel.authBadgeText(source: .api, authState: .ok) == "auth")
        #expect(ProviderPanelModel.authBadgeText(source: .api, authState: .missing) == "no auth")
        #expect(ProviderPanelModel.authBadgeText(source: .api, authState: .invalid) == "auth invalid")
    }
}

// MARK: - Logos autorais (F4-LOGOS): SVGs existem e NSImage carrega

@Suite
struct PanelLogoTests {
    @Test("os 4 SVGs existem no bundle e carregam como NSImage template")
    @MainActor
    func svgsLoadViaNSImage() throws {
        for id in [ProviderID.claude, .codex, .gemini, .zai] {
            let url = try #require(
                Bundle.module.url(
                    forResource: "logo-\(id.rawValue)",
                    withExtension: "svg",
                    subdirectory: "Resources"),
                "SVG ausente para \(id.rawValue)")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let image = try #require(ProviderLogo.image(for: id), "NSImage não carregou \(id.rawValue)")
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
            #expect(image.isTemplate)
        }
    }

    @Test("provider sem SVG (cursor) → nil: painel cai no fallback da sigla D5")
    @MainActor
    func missingLogoFallsBack() {
        #expect(ProviderLogo.image(for: .cursor) == nil)
    }
}

// MARK: - Heartbeat: campos ADITIVOS (v3 + F4)

@Suite
struct PanelHeartbeatTests {
    @Test("monthTokens/monthCostUsd/pacing aparecem só quando existem; chaves v2/v3 intactas")
    func additiveFields() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let providers: [ProviderID: ProviderDisplay] = [
            .claude: ProviderDisplay(
                todayTokens: 77,
                weekTokens: 1_077, weekCostUsd: 0.31, weekHistoryAvailable: true,
                authState: .ok,
                fetchedAt: base,
                monthTokens: 45_600,
                monthCostUsd: 0.9,
                monthHistoryAvailable: true,
                pacing: PacingForecast(exhaustedIn: 9_840, projectedFraction: 1.25, deficitPct: 25)),
            .codex: ProviderDisplay(todayTokens: 10, fetchedAt: base),
        ]
        let payload = E2EHeartbeat.payload(menuBarText: "C:77 X:0", providers: providers, now: base)
        let providersPayload = try #require(payload["providers"] as? [String: Any])

        let claude = try #require(providersPayload["claude"] as? [String: Any])
        #expect(claude["monthTokens"] as? Int64 == 45_600)
        #expect(claude["monthCostUsd"] as? Double == 0.9)
        let pacing = try #require(claude["pacing"] as? [String: Any])
        #expect(pacing["exhaustedIn"] as? Double == 9_840)
        #expect(pacing["projectedFraction"] as? Double == 1.25)
        #expect(pacing["deficitPct"] as? Double == 25)
        // Chaves do contrato v2/v3 continuam lá.
        #expect(claude["menuBar"] as? String == "C:77")
        #expect(claude["history7d"] != nil)

        // Sem dados 30d/pacing → chaves OMITIDAS (nunca fake).
        let codex = try #require(providersPayload["codex"] as? [String: Any])
        #expect(codex["monthTokens"] == nil)
        #expect(codex["monthCostUsd"] == nil)
        #expect(codex["pacing"] == nil)
    }

    @Test("query 30d não rodou → monthTokens/monthCostUsd omitidos mesmo com totais velhos")
    func monthOmittedWhenQueryNotRun() throws {
        let providers: [ProviderID: ProviderDisplay] = [
            .gemini: ProviderDisplay(
                todayTokens: 5,
                monthTokens: 999,  // último valor bom do painel…
                monthHistoryAvailable: false)  // …mas a query NÃO rodou no ciclo
        ]
        let payload = E2EHeartbeat.payload(menuBarText: "TB", providers: providers)
        let entry = try #require((payload["providers"] as? [String: Any])?["gemini"] as? [String: Any])
        #expect(entry["monthTokens"] == nil)
        #expect(entry["monthCostUsd"] == nil)
    }
}

// MARK: - Render gate: menu bar INTOCADO pelos campos do painel

@Suite
struct PanelRenderGateTests {
    @Test("windows/30d/pacing/série não mudam a string do menu bar nem re-renderizam o label")
    @MainActor
    func richFieldsDoNotTouchMenuBar() {
        let base = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
        ])
        let rich = MenuBarContent(providers: [
            .claude: ProviderDisplay(
                todayTokens: 12_400,
                resetsAt: Date(timeIntervalSince1970: 7_200),
                windows: [UsageWindow(kind: .daily, usedFraction: nil, resetsAt: Date(timeIntervalSince1970: 7_200), label: "Hoje")],
                monthTokens: 45_600,
                monthCostUsd: 0.9,
                monthHistoryAvailable: true,
                pacing: PacingForecast(exhaustedIn: nil, projectedFraction: 0.4, deficitPct: nil),
                monthSeries: [PanelDayPoint(day: "2026-09-08", tokens: 1_000, costUSD: nil)]),
        ])
        #expect(rich.displayString() == base.displayString())
        #expect(rich.displayString() == "C:12.4k")

        let store = SnapshotStore()
        store.apply(base)
        let before = store.menuBarText
        store.apply(rich)
        #expect(store.menuBarText == before)  // gate: label não re-renderiza
        #expect(store.providers[.claude]?.monthTokens == 45_600)
        #expect(store.providers[.claude]?.pacing != nil)
    }

    @Test("seleção de aba é estado do painel e não toca no gate")
    @MainActor
    func selectionDoesNotTouchGate() {
        let content = MenuBarContent(providers: [
            .claude: ProviderDisplay(todayTokens: 12_400),
            .codex: ProviderDisplay(percent: 62),
        ])
        let store = SnapshotStore()
        store.apply(content)
        let before = store.menuBarText
        store.select(.codex)
        #expect(store.selectedProvider == .codex)
        #expect(store.menuBarText == before)
        store.select(nil)
        #expect(store.selectedProvider == nil)
    }
}

// MARK: - Wiring: o ciclo publica os dados do painel (30d, série, janelas)

@Suite
struct PanelCoordinatorF4Tests {
    @Test("coordinator: ciclo publica monthTokens/série 30d, janelas do snapshot e pacing honesto (nil local)")
    @MainActor
    func cyclePublishesPanelData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("f4-panel-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Histórico de ONTEM semeado no MESMO banco que o coordinator abre —
        // 1000 tok em claude-sonnet (modelo com preço na tabela local).
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

        // Corpus de hoje: 77 tok (33/44).
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
        // 30d inclui ontem + hoje (mesmo conteúdo do 7d neste fixture).
        #expect(display.monthHistoryAvailable)
        #expect(display.monthTokens == 1_077)
        let monthCost = try #require(display.monthCostUsd)
        #expect(monthCost > 0)
        // Série 30d: um ponto por dia com dado (ontem + hoje), ≤30 pontos.
        #expect(display.monthSeries.count == 2)
        #expect(display.monthSeries.count <= 30)
        #expect(display.monthSeries.allSatisfy { $0.tokens > 0 })

        // Janelas do snapshot publicadas (claude local: 1 janela diária sem
        // fração, com reset amanhã).
        let windows = display.windows
        #expect(windows.count == 1)
        #expect(windows.first?.kind == .daily)
        #expect(windows.first?.usedFraction == nil)
        #expect(windows.first?.resetsAt != nil)

        // Pacing honesto: janela local sem fração → forecast nil (sem chute).
        #expect(display.pacing == nil)

        // Menu bar segue F1; heartbeat ganha os campos aditivos.
        #expect(coordinator.store.menuBarText == "C:77")
        let data = try Data(contentsOf: e2e.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let claudeEntry = try #require((json["providers"] as? [String: Any])?["claude"] as? [String: Any])
        #expect(claudeEntry["monthTokens"] as? Int == 1_077)
        #expect((claudeEntry["monthCostUsd"] as? Double) ?? 0 > 0)
        #expect(claudeEntry["pacing"] == nil)  // sem forecast → omitido
    }
}
