import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F3 Task 3 — view-model do Analytics (a view SwiftUI/Charts não é
/// testável headless; o QA manual da Task 5 cobre a renderização). Aqui:
/// séries, custo/dia derivado (NULL ≠ 0), breakdown top-5, janelas de
/// período e o descarte de estado no fechamento da janela.
@Suite
final class AnalyticsModelTests {
    let dir: URL
    let utc: Calendar
    let now = Date(timeIntervalSince1970: 1_788_086_400)  // 2026-08-30T10:40Z
    let db: AppDatabase

    static let pricing = PricingTable(
        version: 1, updated: "2026-01-01",
        models: [
            "m-priced": .init(input: 3, output: 15, cacheRead: nil, cacheWrite: nil),
        ])

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-analytics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        utc = utcCal
        db = try AppDatabase.open(
            at: dir.appendingPathComponent(AppDatabase.databaseName),
            calendar: utc, pricing: Self.pricing)
        try seed()
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func event(
        _ dayOffset: Int, hour: Int, model: String?, input: Int64, output: Int64,
        provider: ProviderID = .claude
    ) -> UsageEvent {
        let ts = utc.startOfDay(for: now)
            .addingTimeInterval(Double(dayOffset) * 86_400 + Double(hour) * 3_600)
        return UsageEvent(
            ts: ts, provider: provider, account: AccountID(provider: provider, key: "local"),
            model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)
    }

    /// Janela 7d: claude hoje 100 tok m-priced (custo 0.003) + 50 tok NULL;
    /// claude d-1 200 tok NULL; codex hoje 300 tok m-priced (custo 0.009);
    /// claude d-7 400 tok (fora do 7d, dentro do 30d). 6 modelos p/ o top-5.
    private func seed() throws {
        try db.persistBatch(
            provider: .claude, path: "/x/claude.jsonl",
            events: [
                event(0, hour: 3, model: "m-priced", input: 100, output: 0),
                event(0, hour: 4, model: nil, input: 50, output: 0),
                event(-1, hour: 2, model: nil, input: 200, output: 0),
                event(-7, hour: 1, model: "m-priced", input: 400, output: 0),
                event(0, hour: 1, model: "extra-1", input: 10, output: 0),
                event(0, hour: 1, model: "extra-2", input: 20, output: 0),
                event(0, hour: 1, model: "extra-3", input: 30, output: 0),
                event(0, hour: 1, model: "extra-4", input: 40, output: 0),
                event(0, hour: 1, model: "extra-5", input: 50, output: 0),
                event(0, hour: 1, model: "extra-6", input: 60, output: 0),
            ],
            endOffset: 10_000, resetToZero: false)
        try db.persistBatch(
            provider: .codex, path: "/x/codex.jsonl",
            events: [event(0, hour: 2, model: "m-priced", input: 300, output: 0, provider: .codex)],
            endOffset: 500, resetToZero: false)
    }

    @Test("reload (7d default): séries, totais, custo/dia derivado e top-5")
    @MainActor
    func reloadFillsAllSeriesForDefaultPeriod() async throws {
        let model = AnalyticsModel(database: db)
        #expect(model.period == .days7)
        await model.reload(now: now)

        // Barras (dia, provider) na janela — d-7 fica fora.
        #expect(model.providerSeries.map { "\($0.day)|\($0.provider)|\($0.tokens)" } == [
            "2026-08-29|claude|200",
            "2026-08-30|claude|360",  // 100 (m-priced) + 50 (NULL) + 210 (extras)
            "2026-08-30|codex|300",
        ])

        // Custo/dia: d-1 é 100% NULL → NÃO aparece; hoje soma os conhecidos
        // (claude 100×3 + codex 300×3, na mesma ordem da derivação).
        let expectedTodayCost = 100.0 * 3 / 1e6 + 300.0 * 3 / 1e6
        #expect(model.dayCosts.map { "\($0.day)|\($0.costUSD)" } == [
            "2026-08-30|\(expectedTodayCost)",
        ])

        // Totais por provider.
        let claudeTotal = try #require(model.totals.first { $0.provider == "claude" })
        #expect(claudeTotal.tokens == 560)  // 360 (hoje) + 200 (d-1)
        let codexTotal = try #require(model.totals.first { $0.provider == "codex" })
        #expect(codexTotal.tokens == 300)

        // Breakdown cortado no top 5, tokens desc: m-priced 400 (claude+codex)
        // vence; unknown 250; extras 60/50/40 entram — 30/20/10 ficam fora.
        #expect(model.topModels.count == AnalyticsModel.topModelsLimit)
        #expect(model.topModels.first?.model == "m-priced")
        #expect(model.topModels.map(\.tokens) == [400, 250, 60, 50, 40])
    }

    @Test("troca de período: 24h mostra só hoje (buckets diários)")
    @MainActor
    func periodSwitchNarrowsWindow() async {
        let model = AnalyticsModel(database: db)
        model.setPeriod(.day24h)
        await model.reload(now: now)

        #expect(model.period == .day24h)
        #expect(model.providerSeries.map { "\($0.day)|\($0.provider)" } == [
            "2026-08-30|claude", "2026-08-30|codex",
        ])
        #expect(!model.providerSeries.contains { $0.day == "2026-08-29" })

        model.setPeriod(.days30)
        await model.reload(now: now)
        // 30 dias inclui o d-7 (2026-08-23).
        #expect(model.providerSeries.contains { $0.day == "2026-08-23" && $0.tokens == 400 })
    }

    @Test("clear: fechar a janela solta os dados (orçamento de RAM)")
    @MainActor
    func clearDropsAllData() async {
        let model = AnalyticsModel(database: db)
        await model.reload(now: now)
        #expect(!model.providerSeries.isEmpty)
        model.clear()
        #expect(model.providerSeries.isEmpty)
        #expect(model.dayCosts.isEmpty)
        #expect(model.ledgerRows.isEmpty)
        #expect(model.heatmapCells.isEmpty)
        #expect(model.budgetRows.isEmpty)
        #expect(model.totals.isEmpty)
        #expect(model.topModels.isEmpty)
        #expect(!model.isLoading)
    }

    @Test("sem banco (degradação F2): reload mantém janela vazia, nada inventado")
    @MainActor
    func missingDatabaseStaysEmpty() async {
        let model = AnalyticsModel(database: nil)
        #expect(!model.hasDatabase)
        await model.reload()
        #expect(model.providerSeries.isEmpty)
        #expect(model.totals.isEmpty)
        #expect(!model.isLoading)
    }

    @Test("reload em banco vazio: vazio, não nil-ruim")
    @MainActor
    func emptyDatabaseReloadsEmpty() async throws {
        let emptyDir = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyDB = try AppDatabase.open(
            at: emptyDir.appendingPathComponent(AppDatabase.databaseName), calendar: utc)
        let model = AnalyticsModel(database: emptyDB)
        await model.reload(now: now)
        #expect(model.providerSeries.isEmpty)
        #expect(model.dayCosts.isEmpty)
    }

    // MARK: - Derivação do custo/dia (mesma semântica do SUM do SQL)

    @Test("dayCosts: dia misto soma conhecidos; dia 100% NULL sai do chart; 0 real fica")
    func dayCostDerivation() {
        func row(_ day: String, _ cost: Double?) -> AppDatabase.DailySeriesRow {
            .init(day: day, provider: "claude", tokens: 1, costUSD: cost)
        }
        let derived = AnalyticsModel.dayCosts(from: [
            row("2026-08-30", 0.003), row("2026-08-30", nil),   // misto → 0.003
            row("2026-08-29", nil), row("2026-08-29", nil),     // 100% NULL → fora
            row("2026-08-28", 0),                               // zero REAL → barra 0
            row("2026-08-27", 1.5),                             // fora de ordem
        ])
        #expect(derived.map { "\($0.day)|\($0.costUSD)" } == [
            "2026-08-27|1.5", "2026-08-28|0.0", "2026-08-30|0.003",
        ])

        #expect(AnalyticsModel.dayCosts(from: []).isEmpty)
        #expect(AnalyticsModel.dayCosts(from: [row("2026-08-30", nil)]).isEmpty)
    }

    /// Review T3 (finding Important): provider nil-custo ANTES do precificado
    /// no MESMO dia — a guarda antiga usava o dicionário de soma (que só
    /// popula com custo não-nil) e o dia entrava DUPLICADO em `order` →
    /// id duplicado no Chart = barra sobreposta. Dia tem que aparecer 1×.
    @Test("dayCosts: dia com provider nil-custo antes do precificado aparece 1×")
    func dayCostsNilCostProviderBeforePricedAppearsOnce() {
        func row(_ day: String, _ cost: Double?) -> AppDatabase.DailySeriesRow {
            .init(day: day, provider: "claude", tokens: 1, costUSD: cost)
        }
        let nilFirst = AnalyticsModel.dayCosts(from: [
            row("2026-08-30", nil), row("2026-08-30", 0.5),
        ])
        #expect(nilFirst.map { "\($0.day)|\($0.costUSD)" } == ["2026-08-30|0.5"])

        // E com 3+ providers no mesmo dia, ordens variadas.
        let mixed = AnalyticsModel.dayCosts(from: [
            row("2026-08-30", nil), row("2026-08-30", 0.5), row("2026-08-30", nil),
            row("2026-08-30", 0.25),
        ])
        #expect(mixed.map { "\($0.day)|\($0.costUSD)" } == ["2026-08-30|0.75"])
    }

    // MARK: - Usage & Spend: ledger diário + heatmap

    private func seriesRow(
        _ day: String, _ provider: String, _ tokens: Int64, _ cost: Double?
    ) -> AppDatabase.DailySeriesRow {
        .init(day: day, provider: provider, tokens: tokens, costUSD: cost)
    }

    @Test("ledgerRows: desc, tokens somados entre providers; dia 100% NULL vira custo nil")
    func ledgerRowsAggregateByDay() {
        let rows = AnalyticsModel.ledgerRows(from: [
            seriesRow("2026-08-29", "claude", 200, nil),
            seriesRow("2026-08-30", "claude", 100, 0.003),
            seriesRow("2026-08-30", "codex", 300, 0.009),
            seriesRow("2026-08-30", "gemini", 50, nil),
            seriesRow("2026-08-28", "claude", 0, 0),  // zero real: dia entra com custo 0
        ])
        #expect(rows.map(\.day) == ["2026-08-30", "2026-08-29", "2026-08-28"])
        #expect(rows[0].tokens == 450)  // 100 + 300 + 50 (NULL entra nos tokens)
        #expect(rows[0].costUSD == 0.012)  // só os precificados
        #expect(rows[1].costUSD == nil)  // NULL ≠ 0 → a tabela mostra "—"
        #expect(rows[2].costUSD == 0)  // zero real preservado
        #expect(rows[2].tokens == 0)
        #expect(AnalyticsModel.ledgerRows(from: []).isEmpty)
    }

    @Test("heatmapCells: grade inteira da janela, intensidade relativa ao maior custo")
    func heatmapCellsCoverWindowAndNormalize() {
        let window = db.windowDays(days: 4, now: now)  // 08-27..08-30
        let cells = AnalyticsModel.heatmapCells(from: [
            seriesRow("2026-08-30", "claude", 100, 0.5),
            seriesRow("2026-08-29", "claude", 40, 0.25),
            seriesRow("2026-08-28", "claude", 60, nil),  // tokens sim, custo não
        ], window: window)

        #expect(cells.map(\.day) == ["2026-08-27", "2026-08-28", "2026-08-29", "2026-08-30"])
        #expect(cells.map(\.intensity) == [0, 0, 0.5, 1])
        #expect(cells.map(\.tokens) == [0, 60, 40, 100])  // 08-27 sem evento = célula vazia
        #expect(cells.map(\.costUSD) == [nil, nil, 0.25, 0.5])
        // Coluna da semana vem do banco: 08-27 qui … 08-30 dom (Mon = 1).
        #expect(cells.map(\.weekday) == [4, 5, 6, 7])
        // 00:00 do dia no MESMO calendar do banco (UTC no teste), não uma data qualquer.
        #expect(cells.first?.date == utc.date(from: DateComponents(year: 2026, month: 8, day: 27)))
        #expect(cells.first?.id == "2026-08-27")
    }

    @Test("heatmapCells: período sem custo computável → todas as células vazias (0/nil)")
    func heatmapWithoutComputableCost() {
        let window = db.windowDays(days: 2, now: now)
        let cells = AnalyticsModel.heatmapCells(from: [
            seriesRow("2026-08-30", "claude", 10, nil),
        ], window: window)
        #expect(cells.count == 2)
        #expect(cells.allSatisfy { $0.intensity == 0 && $0.costUSD == nil })
        #expect(cells[1].tokens == 10)  // o dia TEM evento; o que falta é preço
        #expect(AnalyticsModel.heatmapCells(from: [], window: []).isEmpty)
    }

    // MARK: - Orçamento do mês (F7 Spend control)

    @Test("budgetRows: linha global e por provider; sem teto não há linha")
    func budgetRowsDerivation() {
        func row(_ provider: String, _ cost: Double?) -> AppDatabase.MonthSpendRow {
            .init(provider: provider, tokens: 100, costUSD: cost)
        }
        // agosto/2026, dia 30 de 31 dias.
        // Sem teto nenhum → nada (a seção orienta a configurar).
        #expect(AnalyticsModel.budgetRows(
            budget: .empty, monthRows: [row("claude", 30)], now: now, calendar: utc).isEmpty)

        // Teto global: uma linha, gasto = total do mês, projeção pelo mês real.
        let global = AnalyticsModel.budgetRows(
            budget: BudgetConfig(monthlyUSD: 100, perProvider: [:]),
            monthRows: [row("claude", 30), row("codex", nil)], now: now, calendar: utc)
        #expect(global.count == 1)
        #expect(global[0].provider == nil)
        #expect(global[0].spentUSD == 30)  // codex sem preço NÃO entra como zero
        #expect(global[0].budgetUSD == 100)
        #expect(global[0].projectedUSD == 31)  // 30/30 dias × 31 dias

        // Por provider: teto próprio + GLOBAL; provider sem evento no mês entra
        // com gasto nil ("—"), nunca 0 nem projeção inventada.
        let mixed = AnalyticsModel.budgetRows(
            budget: BudgetConfig(monthlyUSD: 100, perProvider: [.codex: 50, .zai: 20]),
            monthRows: [row("claude", 30), row("codex", 25)], now: now, calendar: utc)
        #expect(mixed.map(\.id) == ["all", "codex", "zai"])
        #expect(mixed[1].spentUSD == 25)
        #expect(mixed[1].budgetUSD == 50)
        #expect(mixed[2].spentUSD == nil)
        #expect(mixed[2].projectedUSD == nil)

        // Mês sem NENHUM custo computável: total nil → linha sem projeção.
        let allNull = AnalyticsModel.budgetRows(
            budget: BudgetConfig(monthlyUSD: 100, perProvider: [:]),
            monthRows: [row("claude", nil)], now: now, calendar: utc)
        #expect(allNull.first?.spentUSD == nil)
        #expect(allNull.first?.projectedUSD == nil)
    }

    @Test("reload: orçamento do mês chega pronto na janela (global + por provider)")
    @MainActor
    func reloadFillsBudgetRows() async throws {
        AppSettingsStore(database: db).saveBudget(
            BudgetConfig(monthlyUSD: 100, perProvider: [.codex: 50]))
        let model = AnalyticsModel(database: db)
        await model.reload(now: now)

        #expect(model.budgetRows.map(\.id) == ["all", "codex"])
        // Hoje: claude 100 m-priced (0,0003) + codex 300 m-priced (0,0009);
        // d-7: claude 400 m-priced (0,0012) → mês = 0,0024 (d-1 é 100% NULL).
        let expectedMonth = (100.0 * 3 + 300 * 3 + 400 * 3) / 1e6
        let global = try #require(model.budgetRows.first { $0.id == "all" })
        #expect(abs((global.spentUSD ?? -1) - expectedMonth) < 1e-12)
        let codex = try #require(model.budgetRows.first { $0.id == "codex" })
        #expect(abs((codex.spentUSD ?? -1) - 300.0 * 3 / 1e6) < 1e-12)
        #expect(codex.budgetUSD == 50)
    }

    @Test("reload: ledger e heatmap do período (7d = 7 células, grade esparsa)")
    @MainActor
    func reloadFillsLedgerAndHeatmap() async throws {
        let model = AnalyticsModel(database: db)
        await model.reload(now: now)

        // Ledger: só dias com evento (hoje e d-1), desc; d-1 é 100% NULL → "—".
        #expect(model.ledgerRows.map(\.day) == ["2026-08-30", "2026-08-29"])
        #expect(model.ledgerRows.first?.tokens == 660)  // 360 claude + 300 codex
        let expectedTodayCost = 100.0 * 3 / 1e6 + 300.0 * 3 / 1e6
        #expect(model.ledgerRows.first?.costUSD == expectedTodayCost)
        #expect(model.ledgerRows.last?.costUSD == nil)

        // Heatmap: o período INTEIRO, mesmo com evento em só 2 dos 7 dias.
        #expect(model.heatmapCells.map(\.day) == [
            "2026-08-24", "2026-08-25", "2026-08-26", "2026-08-27",
            "2026-08-28", "2026-08-29", "2026-08-30",
        ])
        #expect(model.heatmapCells.last?.intensity == 1)  // hoje tem o maior custo
        #expect(model.heatmapCells.filter { $0.intensity == 0 }.count == 6)
        #expect(!model.heatmapCells.contains { $0.costUSD == 0 })  // nada de 0 inventado
    }
}
