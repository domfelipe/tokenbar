import AppKit
import Foundation
import SwiftUI
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

// MARK: - Pacing condicional (formato da referência MIT — F5)

@Suite
struct PanelPacingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("forecast com déficit e esgotamento → '20% in deficit · Exhausts in 2h 44m'")
    func exhaustText() {
        let forecast = PacingForecast(exhaustedIn: 2 * 3_600 + 44 * 60, projectedFraction: 1.2, deficitPct: 20)
        #expect(ProviderPanelModel.pacingText(forecast, now: now) == "20% in deficit · Exhausts in 2h 44m")
    }

    @Test("forecast sem déficit mas com folga → 'N% in reserve · Lasts until reset'")
    func reserveText() {
        let forecast = PacingForecast(exhaustedIn: nil, projectedFraction: 0.4, deficitPct: nil)
        #expect(ProviderPanelModel.pacingText(forecast, now: now) == "60% in reserve · Lasts until reset")
    }

    @Test("forecast encostando em 100% sem déficit → 'On pace · Lasts until reset'")
    func onPaceText() {
        let forecast = PacingForecast(exhaustedIn: nil, projectedFraction: 1.0, deficitPct: nil)
        #expect(ProviderPanelModel.pacingText(forecast, now: now) == "On pace · Lasts until reset")
    }

    @Test("sem forecast → linha some (menos de 2 pontos, janela sem reset/fração)")
    func nilForecastHidesRow() {
        #expect(ProviderPanelModel.pacingText(nil, now: now) == nil)
    }

    @Test("disclaimer de estimativa (port do hint da referência) acompanha o dashboard")
    func disclaimer() {
        #expect(ProviderPanelModel.estimateDisclaimer == "Estimated from token usage · not a subscription bill")
    }
}

// MARK: - Faixa de pacing na barra (janela crítica)

@Suite
struct PanelPaceStripeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("faixa de pacing vai na janela CRÍTICA (âncora do engine); déficit → vermelha")
    func stripeOnCriticalWindow() {
        let windows = [
            UsageWindow(kind: .session, usedFraction: 0.42, resetsAt: now.addingTimeInterval(4_860), label: "5h"),
            UsageWindow(kind: .weekly, usedFraction: 0.74, resetsAt: now.addingTimeInterval(6 * 86_400), label: "Semanal"),
        ]
        let pacing = PacingForecast(exhaustedIn: 9_840, projectedFraction: 1.2, deficitPct: 20)
        let rows = ProviderPanelModel.windowRows(windows: windows, now: now, pacing: pacing)
        #expect(rows[0].paceStripePercent == nil, "janela não-âncora não ganha faixa")
        #expect(rows[1].paceStripePercent == 100, "projeção > 1 satura no fim da barra")
        #expect(rows[1].paceIsDeficit)
    }

    @Test("projeção dentro da janela → faixa verde na posição projetada")
    func greenStripeInsideWindow() {
        let window = UsageWindow(kind: .weekly, usedFraction: 0.3, resetsAt: now.addingTimeInterval(86_400), label: "w")
        let pacing = PacingForecast(exhaustedIn: nil, projectedFraction: 0.55, deficitPct: nil)
        let rows = ProviderPanelModel.windowRows(windows: [window], now: now, pacing: pacing)
        #expect(rows[0].paceStripePercent == 55)
        #expect(!rows[0].paceIsDeficit)
    }

    @Test("sem pacing → nenhuma faixa (nada inventado)")
    func noStripeWithoutPacing() {
        let window = UsageWindow(kind: .weekly, usedFraction: 0.3, resetsAt: now.addingTimeInterval(86_400), label: "w")
        let rows = ProviderPanelModel.windowRows(windows: [window], now: now)
        #expect(rows[0].paceStripePercent == nil)
    }
}

// MARK: - Dashboard: KPIs (formato da referência MIT — F5)

@Suite
struct PanelKPITests {
    @Test("grid completo: 'Today $0.08' (ênfase) · '30d $2.10' · 'Recent tokens 12.4K' · '30d tokens 8.9B'")
    func fullGrid() {
        let cells = ProviderPanelModel.kpiCells(
            todayCostUsd: 0.08, monthCostUsd: 2.1, todayTokens: 12_400, monthTokens: 8_900_000_000)
        #expect(cells?.map(\.value) == ["$0.08", "$2.10", "12K", "8.9B"])
        #expect(cells?.first?.emphasis == true)
        #expect(cells?.first?.title == "Today")
        #expect(cells?.count == 4)
    }

    @Test("custo ausente (NULL ≠ 0) → célula '—' (formato da referência); nada computável → grid some")
    func nilCostShowsDashAndEmptyGridHides() {
        let partial = ProviderPanelModel.kpiCells(
            todayCostUsd: nil, monthCostUsd: 1.5, todayTokens: 0, monthTokens: 0)
        #expect(partial?.map(\.value) == ["—", "$1.50", "0", "0"])

        let empty = ProviderPanelModel.kpiCells(
            todayCostUsd: nil, monthCostUsd: nil, todayTokens: 0, monthTokens: 0)
        #expect(empty == nil)
    }

    @Test("sub-centavo mantém 4 decimais ($0.0050 não vira $0.00); agrupamento de milhar")
    func subCentAndGrouping() {
        let sub = ProviderPanelModel.kpiCells(
            todayCostUsd: 0.005, monthCostUsd: 1_116.52, todayTokens: 0, monthTokens: 0)
        #expect(sub?[0].value == "$0.0050")
        #expect(sub?[1].value == "$1,116.52")
    }
}

// MARK: - Dashboard: contagem compacta, chart e linhas de detalhe

@Suite
struct PanelDashboardTests {
    @Test("tokenCountString: '216M', '8.9B', '3.1K' — um decimal e '.0' cortado")
    func tokenCounts() {
        #expect(ProviderPanelModel.tokenCountString(216_000_000) == "216M")
        #expect(ProviderPanelModel.tokenCountString(8_900_000_000) == "8.9B")
        #expect(ProviderPanelModel.tokenCountString(3_100) == "3.1K")
        #expect(ProviderPanelModel.tokenCountString(42) == "42")
        #expect(ProviderPanelModel.tokenCountString(10_400_000) == "10M", "≥10 unidades → sem decimal (comportamento da referência)")
        #expect(ProviderPanelModel.tokenCountString(999_500_000) == "1B")
    }

    @Test("chartModel: série com custo → barras em USD e pico '$282'; só tokens → pico abreviado")
    func chartModelVariants() {
        let costSeries = [
            PanelDayPoint(day: "2026-09-08", tokens: 1_000, costUSD: 12.5),
            PanelDayPoint(day: "2026-09-09", tokens: 2_000, costUSD: 282.0),
        ]
        let costChart = ProviderPanelModel.chartModel(series: costSeries)
        #expect(costChart?.values == [12.5, 282.0])
        #expect(costChart?.peakLabel == "$282")

        let tokenSeries = [
            PanelDayPoint(day: "2026-09-08", tokens: 1_000_000, costUSD: nil),
            PanelDayPoint(day: "2026-09-09", tokens: 216_000_000, costUSD: nil),
        ]
        let tokenChart = ProviderPanelModel.chartModel(series: tokenSeries)
        #expect(tokenChart?.values == [1_000_000, 216_000_000])
        #expect(tokenChart?.peakLabel == "216M")

        #expect(ProviderPanelModel.chartModel(series: []) == nil)
        let zeros = ProviderPanelModel.chartModel(
            series: [PanelDayPoint(day: "2026-09-08", tokens: 0, costUSD: nil)])
        #expect(zeros?.peakLabel == nil)
    }

    @Test("detailLines: 7d com custo+tokens, top model truncado em 26, disclaimer condicional")
    func detailLinesAssembly() {
        let full = ProviderPanelModel.detailLines(
            weekCostUsd: 585.43, weekTokens: 3_100_000_000,
            topModel: "gpt-5.6-sonnet", showsEstimate: true)
        #expect(full == [
            "Last 7 days: $585.43 · 3.1B tokens",
            "Top model: gpt-5.6-sonnet",
            "Estimated from token usage · not a subscription bill",
        ])

        // Sem custo na semana → só tokens; sem tokens → só custo.
        #expect(
            ProviderPanelModel.detailLines(
                weekCostUsd: nil, weekTokens: 45_600, topModel: nil, showsEstimate: false)
                == ["Last 7 days: 46K tokens"])
        #expect(
            ProviderPanelModel.detailLines(
                weekCostUsd: 1.5, weekTokens: 0, topModel: nil, showsEstimate: false)
                == ["Last 7 days: $1.50"])

        // Nada → nenhuma linha.
        #expect(
            ProviderPanelModel.detailLines(
                weekCostUsd: nil, weekTokens: 0, topModel: nil, showsEstimate: false).isEmpty)
    }

    @Test("shortModelName: nomes longos truncam em 25 + '…'; curtos passam intactos")
    func modelTruncation() {
        #expect(ProviderPanelModel.shortModelName("gpt-5.6-sonnet") == "gpt-5.6-sonnet")
        let long = String(repeating: "m", count: 40)
        let cut = ProviderPanelModel.shortModelName(long)
        #expect(cut.count == 26)
        #expect(cut.hasSuffix("…"))
    }

    @Test("showsDashboard: qualquer dado de histórico/custo/tokens/série liga; sem nada, some")
    func dashboardVisibility() {
        #expect(ProviderPanelModel.showsDashboard(
            weekHistoryAvailable: false, monthHistoryAvailable: false,
            todayCostUsd: nil, monthCostUsd: nil, todayTokens: 0, monthTokens: 0, series: []) == false)
        #expect(ProviderPanelModel.showsDashboard(
            weekHistoryAvailable: true, monthHistoryAvailable: false,
            todayCostUsd: nil, monthCostUsd: nil, todayTokens: 0, monthTokens: 0, series: []))
        #expect(ProviderPanelModel.showsDashboard(
            weekHistoryAvailable: false, monthHistoryAvailable: false,
            todayCostUsd: nil, monthCostUsd: nil, todayTokens: 0, monthTokens: 0,
            series: [PanelDayPoint(day: "2026-09-08", tokens: 10, costUSD: nil)]))
        #expect(ProviderPanelModel.showsDashboard(
            weekHistoryAvailable: false, monthHistoryAvailable: false,
            todayCostUsd: 0.5, monthCostUsd: nil, todayTokens: 0, monthTokens: 0, series: []))
    }
}

// MARK: - Header (updated Xs ago + badge)

@Suite
struct PanelHeaderTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("'Updated just now' (<60s) / 'Updated Xm ago' / 'Updated Xh ago' — capitalização CONFERIDA contra UsageFormatter MIT (T6); nunca ciclado → 'not updated yet'")
    func updatedText() {
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(-42)) == "Updated just now")
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(-90)) == "Updated 1m ago")
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(-2 * 3_600)) == "Updated 2h ago")
        #expect(ProviderPanelModel.updatedText(now: now, fetchedAt: Date(timeIntervalSince1970: 0)) == "not updated yet")
    }

    @Test("creditsText (F5 T6): saldo real → 'Credits: $X'; unlimited → texto; nil/null → linha omitida (verdicto wham/usage)")
    func creditsText() {
        // Sem credits no snapshot → linha NÃO existe (nada inventado).
        #expect(ProviderPanelModel.creditsText(nil) == nil)
        // Shape observado do wham/usage em contas Plus/Pro: balance null.
        #expect(ProviderPanelModel.creditsText(CreditsInfo(remaining: nil, unlimited: false)) == nil)
        // Saldo real → formato monetário do painel (2 decimais; sub-centavo 4).
        #expect(ProviderPanelModel.creditsText(CreditsInfo(remaining: 4.2, unlimited: false)) == "Credits: $4.20")
        #expect(ProviderPanelModel.creditsText(CreditsInfo(remaining: 1_116.52, unlimited: false)) == "Credits: $1,116.52")
        #expect(ProviderPanelModel.creditsText(CreditsInfo(remaining: 0.005, unlimited: false)) == "Credits: $0.0050")
        // unlimited → texto honesto, sem número.
        #expect(ProviderPanelModel.creditsText(CreditsInfo(remaining: nil, unlimited: true)) == "Credits: unlimited")
        #expect(ProviderPanelModel.creditsText(CreditsInfo(remaining: 0, unlimited: true)) == "Credits: unlimited")
    }

    @Test("badge: local / auth / no auth / auth invalid")
    func authBadge() {
        #expect(ProviderPanelModel.authBadgeText(source: .localOnly, authState: .ok) == "local")
        #expect(ProviderPanelModel.authBadgeText(source: .api, authState: .ok) == "auth")
        #expect(ProviderPanelModel.authBadgeText(source: .api, authState: .missing) == "no auth")
        #expect(ProviderPanelModel.authBadgeText(source: .api, authState: .invalid) == "auth invalid")
    }
}

// MARK: - Logos portados da referência MIT (F5-DESIGN): SVGs existem e NSImage carrega

@Suite
struct PanelLogoTests {
    @Test("os 10 SVGs portados (ProviderIcon-*) existem no bundle e carregam como NSImage template")
    @MainActor
    func svgsLoadViaNSImage() throws {
        for id in [ProviderID.claude, .codex, .gemini, .zai, .cursor, .openrouter, .alibaba, .antigravity, .deepseek, .grok] {
            let url = try #require(
                Bundle.module.url(
                    forResource: "ProviderIcon-\(id.rawValue)",
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

    @Test("bitmaps 3x da menu bar rasterizam com pixels visíveis (nunca em branco)")
    @MainActor
    func bitmapsHaveVisiblePixels() {
        // Regressão: rasterize sem flush devolvia NSImage em branco — o item
        // media normal no AX mas pintava só texto. Pixels mandam (Regra 9).
        for id in [ProviderID.claude, .codex, .gemini, .zai, .cursor, .openrouter, .alibaba, .antigravity, .deepseek, .grok] {
            let bitmap = ProviderLogo.bitmap(for: id, points: 15)
            guard let bitmap else {
                Issue.record("bitmap nil para \(id.rawValue) — cairia no fallback de sigla")
                continue
            }
            var visible = 0
            for rep in bitmap.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                for x in 0..<rep.pixelsWide {
                    for y in 0..<rep.pixelsHigh {
                        if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                            visible += 1
                        }
                    }
                }
            }
            #expect(visible > 0, "bitmap em branco para \(id.rawValue)")
        }
    }

    @Test("provider sem SVG (copilot) → nil: painel cai no fallback da sigla D5")
    @MainActor
    func missingLogoFallsBack() {
        #expect(ProviderLogo.image(for: .copilot) == nil)
    }

    @Test("cores de marca = tokens exatos da referência MIT (ProviderBranding)")
    @MainActor
    func brandColorsMatchReference() {
        #expect(ProviderLogo.brandColor(for: .claude) == Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255))
        #expect(ProviderLogo.brandColor(for: .codex) == Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255))
        #expect(ProviderLogo.brandColor(for: .gemini) == Color(red: 171 / 255, green: 135 / 255, blue: 234 / 255))
        #expect(ProviderLogo.brandColor(for: .zai) == Color(red: 232 / 255, green: 90 / 255, blue: 106 / 255))
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

// MARK: - Altura do painel (regressão 13/09: janela colapsada em 129pt)

/// O `ScrollView` do detalhe não tem altura intrínseca: com `.frame(maxHeight:)`
/// o `MenuBarExtra` dimensionava a JANELA com o scroll em ~0 e o painel abria
/// com **129pt** — só o chip bar e o começo das barrinhas apareciam, e
/// "Usage dashboard" (y=398) ficava FORA da janela (que ia até y=161). Medido
/// com o painel aberto em 13/09 (CGWindowList + AX). DEPOIS do fix: 310x489
/// com os 7 itens (ações + rodapé) dentro da janela — ver
/// `scripts/qa-axtree.swift --panel` e o gate no `ui-smoke`.
@Suite
struct PanelSizingTests {
    @Test("scrollHeight: altura MEDIDA do conteúdo, piso de 1pt e teto em contentMaxHeight")
    func scrollHeightClampsToMeasuredContent() {
        // Não medido (0), negativo ou NaN → piso: pedir 0pt era o que colapsava a janela.
        #expect(ProviderPanelView.scrollHeight(measured: 0) == 1)
        #expect(ProviderPanelView.scrollHeight(measured: -40) == 1)
        #expect(ProviderPanelView.scrollHeight(measured: .nan) == 1)
        // Conteúdo que cabe → a altura EXATA (a janela passa a crescer com ele).
        #expect(ProviderPanelView.scrollHeight(measured: 282) == 282)
        #expect(ProviderPanelView.scrollHeight(measured: ProviderPanelView.contentMaxHeight)
            == ProviderPanelView.contentMaxHeight)
        // Acima do teto → rola dentro do teto (nunca maior).
        #expect(ProviderPanelView.scrollHeight(measured: 900) == ProviderPanelView.contentMaxHeight)
        #expect(ProviderPanelView.scrollHeight(measured: .infinity) == ProviderPanelView.contentMaxHeight)
        #expect(ProviderPanelView.scrollHeight(measured: 700, cap: 600) == 600)
    }
}
