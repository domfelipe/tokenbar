import Foundation
import GRDB
import Testing
@testable import TokenBarCore

/// F3 Task 3 — leitores de histórico (dailySeries/totals/modelBreakdown/
/// weekTotal/eventsForExport) vs. eventos conhecidos. Foco especial do
/// review T2: custo NULL (modelo sem preço) NUNCA vira 0 — nem 0 vira NULL.
@Suite
final class HistoryQueryTests {
    let dir: URL
    /// Calendar UTC FIXO: day strings/limites de janela determinísticos em
    /// qualquer máquina (o painel usa Calendar.current; os readers são
    /// agnósticos — o calendar é injetado no banco).
    let utc: Calendar
    /// now fixo: 2026-08-30T10:40:00Z.
    let now = Date(timeIntervalSince1970: 1_788_086_400)
    let db: AppDatabase

    /// Preços sintéticos estáveis (nada de depender do pricing.json embutido
    /// que o F3 Task 2 pode atualizar): m-priced = in 3 / out 15 / cr 0.3
    /// USD/MTok; cache write sem preço público (nil).
    static let pricing = PricingTable(
        version: 1, updated: "2026-01-01",
        models: [
            "m-priced": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: nil),
        ])

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-history-\(UUID().uuidString)", isDirectory: true)
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
        _ ts: Date, model: String?, input: Int64, output: Int64,
        cacheRead: Int64 = 0, provider: ProviderID = .claude
    ) -> UsageEvent {
        UsageEvent(
            ts: ts, provider: provider, account: AccountID(provider: provider, key: "local"),
            model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: 0, project: nil)
    }

    /// Custo do m-priced (input 3 / output 15 / cache read 0,3 USD por MTok) —
    /// os preços do fixture de pricing desta suíte.
    ///
    /// Quebrado em sub-expressões DE PROPÓSITO: a conta inteira numa linha
    /// estourava o type-check do toolchain do runner do CI ("unable to
    /// type-check this expression in reasonable time", run de 13/09) mesmo
    /// compilando local no toolchain mais novo.
    private func pricedCost(input: Double, output: Double, cacheRead: Double = 0) -> Double {
        let inputCost = input * 3
        let outputCost = output * 15
        let cacheReadCost = cacheRead * 0.3
        return (inputCost + outputCost + cacheReadCost) / 1_000_000
    }

    /// Fixtures (dias relativos a now=2026-08-30, meia-noite UTC):
    /// - hoje +3h  claude m-priced  100/200        → 300 tok, custo 0.0033
    /// - hoje +4h  claude m-priced  10/20 cr 1000  → 1030 tok, custo 0.00066
    /// - hoje +5h  claude nil       50/50          → 100 tok, custo NULL
    /// - hoje +1h  codex  m-priced  1_000_000/0    → 1M tok, custo 3.0
    /// - d-1  +2h  claude nil       70/30          → 100 tok, custo NULL (dia inteiro sem custo)
    /// - d-6  +2h  claude m-priced  0/0            → 0 tok, custo EXATAMENTE 0 (≠ NULL)
    /// - d-7  +1h  claude m-priced  40/40          → 80 tok (fora da janela 7d)
    /// - d-30 +1h  claude m-priced  5/5            → fora da janela 30d
    private func seed() throws {
        let today = utc.startOfDay(for: now)  // 2026-08-30T00:00Z
        func day(_ offset: Int) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
        let events = [
            event(day(0).addingTimeInterval(3 * 3_600), model: "m-priced", input: 100, output: 200),
            event(day(0).addingTimeInterval(4 * 3_600), model: "m-priced", input: 10, output: 20, cacheRead: 1_000),
            event(day(0).addingTimeInterval(5 * 3_600), model: nil, input: 50, output: 50),
            event(day(0).addingTimeInterval(1 * 3_600), model: "m-priced", input: 1_000_000, output: 0, provider: .codex),
            event(day(-1).addingTimeInterval(2 * 3_600), model: nil, input: 70, output: 30),
            event(day(-6).addingTimeInterval(2 * 3_600), model: "m-priced", input: 0, output: 0),
            event(day(-7).addingTimeInterval(1 * 3_600), model: "m-priced", input: 40, output: 40),
            event(day(-30).addingTimeInterval(1 * 3_600), model: "m-priced", input: 5, output: 5),
        ]
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl", events: events,
            endOffset: 10_000, resetToZero: false)
        #expect(try db.usageEventCount() == 8)
    }

    @Test("dailySeries: soma conhecida por (dia, provider) na janela 7d")
    func dailySeriesMatchesKnownEvents() throws {
        let series = try db.dailySeries(days: 7, now: now)

        // Ordenação estável (day, provider); 4 grupos com dados na janela.
        #expect(series.map { "\($0.day)|\($0.provider)" } == [
            "2026-08-24|claude", "2026-08-29|claude", "2026-08-30|claude", "2026-08-30|codex",
        ])
        let claudeToday = try #require(series.first { $0.provider == "claude" && $0.day == "2026-08-30" })
        #expect(claudeToday.tokens == 1_430)  // 300 + 1030 + 100
        // Dia misto (2 precificados + 1 NULL): soma os conhecidos, NÃO é nil.
        let expectedToday = pricedCost(input: 100, output: 200)
            + pricedCost(input: 10, output: 20, cacheRead: 1_000)
        let todayCost = try #require(claudeToday.costUSD)
        #expect(abs(todayCost - expectedToday) < 1e-15)

        let codex = try #require(series.first { $0.provider == "codex" })
        #expect(codex.tokens == 1_000_000)
        let codexCost = try #require(codex.costUSD)
        #expect(codexCost == 3.0)  // 1M tok × 3 USD/MTok, exato
    }

    @Test("custo NULL ≠ 0: dia inteiro sem preço → nil; dia com custo zero real → 0")
    func nullCostStaysDistinctFromZero() throws {
        let series = try db.dailySeries(days: 7, now: now)

        // d-1: ÚNICO evento do dia é sem preço → custo do dia é NULL, nunca 0.
        let dayMinus1 = try #require(series.first { $0.day == "2026-08-29" })
        #expect(dayMinus1.tokens == 100)
        #expect(dayMinus1.costUSD == nil)

        // d-6: evento precificado com 0 tokens → custo EXATAMENTE 0 (não nil).
        let dayMinus6 = try #require(series.first { $0.day == "2026-08-24" })
        #expect(dayMinus6.tokens == 0)
        let zeroCost = try #require(dayMinus6.costUSD)
        #expect(zeroCost == 0.0)
    }

    @Test("dailySeries: janela de dias (d-7 fora do 7d, dentro do 30d; d-30 fora)")
    func dailySeriesWindowBoundaries() throws {
        let days7 = try db.dailySeries(days: 7, now: now)
        #expect(!days7.contains { $0.day == "2026-08-23" })  // d-7 fora
        #expect(!days7.contains { $0.day == "2026-07-31" })

        let days30 = try db.dailySeries(days: 30, now: now)
        let dMinus7 = try #require(days30.first { $0.day == "2026-08-23" })
        #expect(dMinus7.tokens == 80)
        // d-30 (2026-07-31) fica FORA até da janela 30d (30 dias corridos
        // incluindo hoje: from = hoje-29).
        #expect(!days30.contains { $0.day == "2026-07-31" })
    }

    @Test("dailySeries: filtros por provider e por model")
    func dailySeriesFilters() throws {
        let claudeOnly = try db.dailySeries(provider: .claude, days: 7, now: now)
        #expect(!claudeOnly.isEmpty)
        #expect(claudeOnly.allSatisfy { $0.provider == "claude" })

        let pricedOnly = try db.dailySeries(model: "m-priced", days: 7, now: now)
        #expect(pricedOnly.map { "\($0.day)|\($0.provider)" } == [
            "2026-08-24|claude", "2026-08-30|claude", "2026-08-30|codex",
        ])
        let claudeToday = try #require(pricedOnly.first { $0.provider == "claude" && $0.day == "2026-08-30" })
        #expect(claudeToday.tokens == 1_330)  // sem o evento "unknown" (100)

        let claudePricedToday = try db.dailySeries(provider: .claude, model: "m-priced", days: 7, now: now)
        #expect(claudePricedToday.count == 2)
    }

    @Test("totals: totais por provider na janela com a mesma semântica de custo")
    func totalsPerProvider() throws {
        let totals = try db.totals(days: 7, now: now)
        #expect(totals.map(\.provider) == ["claude", "codex"])

        // Custo claude = dia misto (2 precificados) + d-6 com custo EXATO 0;
        // NULLs ignorados. (10×3 + 20×15 + 1000×0.3)/1e6 = 0.00063 — a soma
        // pode variar µulp pela ordem do SUM no SQL; tolerância folgada.
        let claude = try #require(totals.first { $0.provider == "claude" })
        #expect(claude.tokens == 1_530)  // 1430 + 100 (d-1) + 0 (d-6)
        let claudeCost = try #require(claude.costUSD)
        let expectedClaude = pricedCost(input: 100, output: 200)
            + pricedCost(input: 10, output: 20, cacheRead: 1_000)
        #expect(abs(claudeCost - expectedClaude) < 1e-12)

        let codex = try #require(totals.first { $0.provider == "codex" })
        #expect(codex.tokens == 1_000_000)
        #expect(codex.costUSD == 3.0)
    }

    @Test("weekTotal: total 7d do painel; provider sem histórico → 0 tok, custo nil")
    func weekTotalForPanel() throws {
        let claude = try db.weekTotal(provider: .claude, days: 7, now: now)
        #expect(claude.tokens == 1_530)
        #expect(claude.costUSD != nil)

        let zai = try db.weekTotal(provider: .zai, days: 7, now: now)
        #expect(zai.tokens == 0)
        #expect(zai.costUSD == nil)
    }

    @Test("modelBreakdown: ordenado por tokens desc; NULL de custo preservado por modelo")
    func modelBreakdownOrdersAndPreservesNull() throws {
        let breakdown = try db.modelBreakdown(days: 7, now: now)
        #expect(breakdown.map(\.model) == ["m-priced", "unknown"])

        let priced = try #require(breakdown.first { $0.model == "m-priced" })
        #expect(priced.tokens == 1_001_330)  // 300 + 1030 + 0 + 1M
        let pricedTotal = try #require(priced.costUSD)
        let expectedPriced = pricedCost(input: 100, output: 200)
            + pricedCost(input: 10, output: 20, cacheRead: 1_000) + 3.0
        #expect(abs(pricedTotal - expectedPriced) < 1e-12)

        let unknown = try #require(breakdown.first { $0.model == "unknown" })
        #expect(unknown.tokens == 200)
        #expect(unknown.costUSD == nil)  // nenhum evento do grupo teve preço
    }

    @Test("eventsForExport: janela, ordenação estável (ts,id) e NULL de custo/model no registro")
    func eventsForExportWindowAndOrder() throws {
        let events = try db.eventsForExport(days: 30, now: now)
        #expect(events.count == 7)  // tudo, exceto o d-30
        // Ordenado por (ts, id): d-7, d-6, d-1, hoje+1h(codex), +3h, +4h, +5h.
        let tsList = events.map { $0.ts.timeIntervalSince1970 }
        #expect(zip(tsList, tsList.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        let unknown = try #require(events.first { $0.model == nil })
        #expect(unknown.costUSD == nil)  // NULL cru preservado p/ o export

        let codexOnly = try db.eventsForExport(days: 30, now: now, provider: .codex)
        #expect(codexOnly.count == 1)
        #expect(codexOnly.first?.provider == "codex")
    }

    @Test("windowDays: 'hoje' e weekday seguem o calendar do BANCO, não o fuso do host")
    func windowDaysUsesInjectedCalendar() throws {
        // now = 2026-08-30T10:40Z. Em UTC+14 já é 31/08 00:40 → "hoje" é 31/08
        // e a janela de 3 dias é 29, 30 e 31/08 (sáb, dom, seg). Um teste que só
        // olhasse o calendar UTC passaria verde mesmo se a implementação usasse
        // Calendar.current num host UTC — este não passa.
        var plus14 = Calendar(identifier: .gregorian)
        plus14.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        let tzDir = dir.appendingPathComponent("tz-plus14", isDirectory: true)
        try FileManager.default.createDirectory(at: tzDir, withIntermediateDirectories: true)
        let tzDB = try AppDatabase.open(
            at: tzDir.appendingPathComponent(AppDatabase.databaseName), calendar: plus14)

        let far = tzDB.windowDays(days: 3, now: now)
        #expect(far.map(\.day) == ["2026-08-29", "2026-08-30", "2026-08-31"])
        #expect(far.map(\.weekday) == [6, 7, 1])

        // O MESMO instante no calendar UTC do banco principal: janela e colunas
        // diferentes — weekday é do banco, não do relógio da máquina.
        let utcDays = db.windowDays(days: 3, now: now)
        #expect(utcDays.map(\.day) == ["2026-08-28", "2026-08-29", "2026-08-30"])
        #expect(utcDays.map(\.weekday) == [5, 6, 7])
    }

    // MARK: - Grade da janela (Usage & Spend: heatmap diário)

    @Test("windowDays: 7d termina hoje e começa onde o WHERE day >= ? corta")
    func windowDaysGrid() throws {
        let week = db.windowDays(days: 7, now: now)
        #expect(week.map(\.day) == [
            "2026-08-24", "2026-08-25", "2026-08-26", "2026-08-27",
            "2026-08-28", "2026-08-29", "2026-08-30",
        ])
        #expect(week.first?.date == AppDatabase.date(fromDayString: "2026-08-24", calendar: utc))
        #expect(week.last?.date == utc.startOfDay(for: now))
        // 2026-08-30 é DOMINGO: a janela de 7 dias cai inteira em Mon..Sun.
        #expect(week.map(\.weekday) == [1, 2, 3, 4, 5, 6, 7])
        // Passo por Calendar (DST-safe), não soma de 86_400: dias consecutivos.
        #expect(zip(week, week.dropFirst()).allSatisfy {
            utc.dateComponents([.day], from: $0.date, to: $1.date).day == 1
        })
        // A grade começa EXATAMENTE no primeiro dia da série — por construção.
        #expect(week.first?.day == (try db.dailySeries(days: 7, now: now).first?.day))

        // days <= 1 → só hoje (mesma regra do windowStartDate).
        #expect(db.windowDays(days: 1, now: now).map(\.day) == ["2026-08-30"])
        #expect(db.windowDays(days: 0, now: now).map(\.day) == ["2026-08-30"])
        // 30d tem 30 células, mesmo com poucos dias com evento (grade esparsa).
        #expect(db.windowDays(days: 30, now: now).count == 30)
        #expect(db.windowDays(days: 30, now: now).first?.day == "2026-08-01")
    }

    // MARK: - Gasto do mês (F7 Spend control)

    @Test("monthSpend: mês-CALENDÁRIO (não 30 dias), limite superior em hoje e NULL ≠ 0")
    func monthSpendCoversCalendarMonth() throws {
        let rows = try db.monthSpend(now: now)
        #expect(rows.map(\.provider) == ["claude", "codex"])

        let claude = try #require(rows.first { $0.provider == "claude" })
        // Hoje 300 + 1030 + 100; d-1 100; d-6 0; d-7 80 — o d-30 é de JULHO.
        #expect(claude.tokens == 1_610)
        let expectedClaude = pricedCost(input: 100, output: 200)     // hoje +3h
            + pricedCost(input: 10, output: 20, cacheRead: 1_000)    // hoje +4h
            + pricedCost(input: 40, output: 40)                      // d-7
        #expect(abs((claude.costUSD ?? -1) - expectedClaude) < 1e-12)

        let codex = try #require(rows.first { $0.provider == "codex" })
        #expect(codex.tokens == 1_000_000)
        #expect(codex.costUSD == 3.0)

        let total = AppDatabase.monthSpendTotal(rows)
        #expect(total.tokens == 1_001_610)
        #expect(abs((total.costUSD ?? -1) - (expectedClaude + 3.0)) < 1e-12)

        // Julho tem SÓ o d-30 (5 in + 5 out = 10 tokens, com preço) — prova da
        // fronteira do mês: o evento de julho NÃO entra no mês de agosto.
        let july = try db.monthSpend(now: now.addingTimeInterval(-30 * 86_400))
        #expect(july.map(\.provider) == ["claude"])
        #expect(july.first?.tokens == 10)
        // 5 in + 5 out do m-priced (3 / 15 USD por MTok) = 9e-5 exatos.
        #expect(abs((july.first?.costUSD ?? -1) - pricedCost(input: 5, output: 5)) < 1e-12)
    }

    @Test("monthSpendTotal: sem NENHUM custo computável o total é nil, nunca 0")
    func monthSpendTotalKeepsNullSemantics() {
        let empty = AppDatabase.monthSpendTotal([])
        #expect(empty.tokens == 0)
        #expect(empty.costUSD == nil)

        let allNull = AppDatabase.monthSpendTotal([
            .init(provider: "claude", tokens: 100, costUSD: nil),
            .init(provider: "codex", tokens: 200, costUSD: nil),
        ])
        #expect(allNull.tokens == 300)
        #expect(allNull.costUSD == nil)

        let mixed = AppDatabase.monthSpendTotal([
            .init(provider: "claude", tokens: 100, costUSD: nil),
            .init(provider: "codex", tokens: 200, costUSD: 1.5),
            .init(provider: "zai", tokens: 50, costUSD: 0),
        ])
        #expect(mixed.tokens == 350)
        #expect(mixed.costUSD == 1.5)  // zero real soma como zero, não como NULL
    }
}
