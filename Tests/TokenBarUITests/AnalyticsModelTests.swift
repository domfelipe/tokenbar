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
}
