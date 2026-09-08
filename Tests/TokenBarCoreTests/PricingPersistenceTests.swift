import Foundation
import GRDB
import Testing
import TokenBarCore

/// F3 Task 2 — custo estimado na persistência: `cost_usd` calculado NA INGEST
/// pela PricingTable (usage_events + daily_agg, mesma transação), modelo
/// ausente → NULL (nunca 0/chute), soma diária p/ o painel, e o não-retroativo
/// documentado (eventos T1 sem custo NÃO são re-precificados — hwm impede).
@Suite
final class PricingPersistenceTests {
    let dir: URL
    let now = Date(timeIntervalSince1970: 1_788_000_000)

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeURL() -> URL {
        dir.appendingPathComponent("db-\(UUID().uuidString).sqlite")
    }

    /// Evento no dia de `now`, valor de cache configurável.
    func event(
        provider: ProviderID = .claude, model: String?, input: Int64 = 0, output: Int64 = 0,
        cacheRead: Int64 = 0, cacheWrite: Int64 = 0, ts: Date? = nil
    ) -> UsageEvent {
        UsageEvent(
            ts: ts ?? now, provider: provider,
            account: AccountID(provider: provider, key: "local"),
            model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            project: "proj", dedupeID: nil)
    }

    /// Lê cost_usd bruto das linhas de usage_events (NULL vira nil).
    func eventCosts(url: URL) throws -> [(model: String?, cost: Double?)] {
        let db = try DatabaseQueue(path: url.path)
        return try db.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT model, cost_usd FROM usage_events ORDER BY id")
            return rows.map { (model: $0["model"], cost: $0["cost_usd"] as Double?) }
        }
    }

    // MARK: - usage_events

    @Test("ingest com tabela: cost_usd na linha do evento (input+output+cache)")
    func eventRowCarriesComputedCost() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar)  // pricing bundled
        // claude-sonnet-4-6 (3/15/0.3/3.75): 1M+1M+1M+1M → 22.05.
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(
                model: "claude-sonnet-4-6", input: 1_000_000, output: 1_000_000,
                cacheRead: 1_000_000, cacheWrite: 1_000_000)],
            endOffset: 100, resetToZero: false)

        let costs = try eventCosts(url: url)
        #expect(costs.count == 1)
        #expect(costs[0].model == "claude-sonnet-4-6")
        #expect(abs((costs[0].cost!) - 22.05) < 1e-9)
    }

    @Test("modelo ausente ou nil → cost_usd NULL (nunca 0)")
    func unknownModelStoresNull() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar)
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [
                event(model: "made-up-model-9000", input: 1_000, output: 1_000),
                event(model: nil, input: 500, output: 500),
            ],
            endOffset: 100, resetToZero: false)

        let costs = try eventCosts(url: url)
        #expect(costs.count == 2)
        #expect(costs[0].model == "made-up-model-9000" && costs[0].cost == nil)
        #expect(costs[1].model == nil && costs[1].cost == nil)
    }

    @Test("open com pricing: nil (degradação) → todo evento sai sem custo")
    func missingPricingTableStoresNull() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar, pricing: nil)
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(model: "claude-sonnet-4-6", input: 1_000, output: 2_000)],
            endOffset: 100, resetToZero: false)
        #expect(try eventCosts(url: url).first?.cost == nil)
    }

    // MARK: - daily_agg

    @Test("daily_agg acumula custo por grupo na mesma transação")
    func dailyAggAccumulatesCost() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar)
        // Lote 1: 1M+1M (sonnet 4-6) → 18.00.
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(model: "claude-sonnet-4-6", input: 1_000_000, output: 1_000_000)],
            endOffset: 100, resetToZero: false)
        // Lote 2, mesmo dia/conta/modelo: 1M cache read → +0.30.
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(model: "claude-sonnet-4-6", cacheRead: 1_000_000)],
            endOffset: 200, resetToZero: false)

        let rows = try db.dailyAggRows(provider: .claude)
        #expect(rows.count == 1)
        #expect(abs(rows[0].costUSD - 18.30) < 1e-9)
        #expect(rows[0].inputTokens == 1_000_000)
        #expect(rows[0].cacheReadTokens == 1_000_000)
    }

    @Test("grupos com e sem preço ficam separados: um com custo, outro NULL")
    func pricedAndUnpricedGroupsStaySeparate() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar)
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [
                event(model: "claude-sonnet-4-6", input: 1_000_000),   // 3.00
                event(model: "made-up-model-9000", input: 9_999_999),  // sem preço
            ],
            endOffset: 100, resetToZero: false)

        let rows = try db.dailyAggRows(provider: .claude)
        #expect(rows.count == 2)
        let priced = rows.first { $0.model == "claude-sonnet-4-6" }
        let unpriced = rows.first { $0.model == "made-up-model-9000" }
        #expect(abs(priced!.costUSD - 3.0) < 1e-9)
        // O reader (`dailyAggRows`) normaliza NULL → 0 — a linha de eventos é
        // quem preserva o NULL; aqui checamos que o grupo não recebeu custo.
        #expect(unpriced?.costUSD == 0)
        // E no usage_events o NULL ficou explícito:
        let costs = try eventCosts(url: url)
        #expect(costs.first(where: { $0.model == "made-up-model-9000" })?.cost == nil)
    }

    // MARK: - Soma do dia (fonte do painel)

    @Test("todayCostUSD soma só o dia corrente e só eventos com custo")
    func todayCostSumsTodayOnly() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar)
        let yesterday = now.addingTimeInterval(-86_400)
        try db.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [
                // Hoje: 1M in (3.00) + 1M out (15.00).
                event(model: "claude-sonnet-4-6", input: 1_000_000),
                event(model: "claude-sonnet-4-6", output: 1_000_000),
                // Ontem: NÃO entra na soma do dia.
                event(model: "claude-sonnet-4-6", input: 1_000_000, ts: yesterday),
                // Hoje, sem preço: contribui nada (mas não zera a soma).
                event(model: "made-up-model-9000", input: 1_000_000),
            ],
            endOffset: 100, resetToZero: false)

        let today = try #require(try db.todayCostUSD(provider: .claude, now: now))
        #expect(abs(today - 18.0) < 1e-9)
        // Provider sem evento nenhum → nil.
        #expect(try db.todayCostUSD(provider: .codex, now: now) == nil)
    }

    @Test("todayCostUSD: dia só com eventos sem preço → nil (não 0)")
    func unpricedOnlyDayYieldsNil() throws {
        let url = makeURL()
        let db = try AppDatabase.open(at: url, calendar: calendar)
        try db.persistBatch(
            provider: .gemini, path: "/g/s1.jsonl",
            events: [event(provider: .gemini, model: "made-up-model-9000", input: 1_000)],
            endOffset: 50, resetToZero: false)
        #expect(try db.todayCostUSD(provider: .gemini, now: now) == nil)
    }

    // MARK: - Não-retroativo (T1)

    @Test("eventos persistidos sem custo NÃO são re-precificados (hwm impede re-leitura)")
    func persistedWithoutCostStaysNull() throws {
        let url = makeURL()
        // Fase T1: banco SEM tabela de preços — eventos ficam com custo NULL.
        let t1 = try AppDatabase.open(at: url, calendar: calendar, pricing: nil)
        try t1.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(model: "claude-sonnet-4-6", input: 1_000, output: 2_000)],
            endOffset: 100, resetToZero: false)
        #expect(try eventCosts(url: url).first?.cost == nil)

        // Reabertura COM a tabela bundled (upgrade F3): a marca d'água de
        // endOffset=100 bloqueia o re-ingest — o evento antigo segue NULL.
        let upgraded = try AppDatabase.open(at: url, calendar: calendar)
        try upgraded.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(model: "claude-sonnet-4-6", input: 1_000, output: 2_000)],
            endOffset: 100, resetToZero: false)  // lote já coberto → ignorado

        let costs = try eventCosts(url: url)
        #expect(costs.count == 1, "hwm dedup: lote repetido não vira linha nova")
        #expect(costs[0].cost == nil, "custo antigo não é retroativo")
        #expect(try upgraded.todayCostUSD(provider: .claude, now: now) == nil)

        // Append NOVO (endOffset > hwm) já entra precificado:
        try upgraded.persistBatch(
            provider: .claude, path: "/p/s1.jsonl",
            events: [event(model: "claude-sonnet-4-6", input: 1_000_000)],
            endOffset: 250, resetToZero: false)
        let nowCost = try #require(try upgraded.todayCostUSD(provider: .claude, now: now))
        #expect(abs(nowCost - 3.0) < 1e-9)
    }
}
