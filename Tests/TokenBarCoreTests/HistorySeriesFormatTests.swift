import Foundation
import GRDB
import Testing
@testable import TokenBarCore

/// F3 Task 4 — contrato de stdout do `tokenbar history`: CSV (header + linhas,
/// LF, custo NULL = vazio) e JSON (array `{day, provider, tokens, costUsd|
/// null}`) sobre a MESMA série diária da UI (`dailySeries`). O CLI é o par
/// query+format testado aqui (o alvo `tokenbar` não é importável pelos
/// testes); `--days`/`--provider` são exatamente os argumentos de
/// `dailySeries(days:provider:)`.
@Suite
final class HistorySeriesFormatTests {
    let dir: URL
    /// Calendar UTC fixo: janela/day strings determinísticos (mesmo padrão de
    /// HistoryQueryTests — o calendar é injetado no banco).
    let utc: Calendar
    /// now fixo: 2026-08-30T10:40:00Z.
    let now = Date(timeIntervalSince1970: 1_788_086_400)
    let db: AppDatabase

    static let pricing = PricingTable(
        version: 1, updated: "2026-01-01",
        models: [
            "m-priced": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: nil),
        ])

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-series-\(UUID().uuidString)", isDirectory: true)
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
        provider: ProviderID = .claude
    ) -> UsageEvent {
        UsageEvent(
            ts: ts, provider: provider, account: AccountID(provider: provider, key: "local"),
            model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)
    }

    /// Mesmos fixtures de HistoryQueryTests (agora vistos pelo CLI):
    /// d-6 0 tok custo exato 0 · d-1 100 tok custo NULL · hoje claude 430 tok
    /// custo parcial (2 grupos precificados) · hoje codex 1M tok custo 3.0 ·
    /// d-7 80 tok (fora do 7d) · d-30 fora de tudo.
    private func seed() throws {
        let today = utc.startOfDay(for: now)
        func day(_ offset: Int) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [
                event(day(0).addingTimeInterval(3 * 3_600), model: "m-priced", input: 100, output: 200),
                event(day(0).addingTimeInterval(4 * 3_600), model: "m-priced", input: 10, output: 20),
                event(day(0).addingTimeInterval(5 * 3_600), model: nil, input: 50, output: 50),
                event(day(-1).addingTimeInterval(2 * 3_600), model: nil, input: 70, output: 30),
                event(day(-6).addingTimeInterval(2 * 3_600), model: "m-priced", input: 0, output: 0),
                event(day(-7).addingTimeInterval(1 * 3_600), model: "m-priced", input: 40, output: 40),
                event(day(-30).addingTimeInterval(1 * 3_600), model: "m-priced", input: 5, output: 5),
            ], endOffset: 10_000, resetToZero: false)
        try db.persistBatch(
            provider: .codex, path: "/x/b.jsonl",
            events: [event(day(0).addingTimeInterval(1 * 3_600), model: "m-priced", input: 1_000_000, output: 0, provider: .codex)],
            endOffset: 20_000, resetToZero: false)
    }

    // MARK: - CSV (formato do HistoryExport: header + linhas, LF, NULL = vazio)

    @Test("CSV golden 7d: ordenado (day, provider), custo NULL vazio, zero real = 0")
    func csvGolden() throws {
        let csv = HistorySeriesFormat.csv(from: try db.dailySeries(days: 7, now: now))
        // custo de hoje (claude): %.6f de 0.0033 + 0.00033 → "0.003630" → aparado.
        #expect(csv == """
            day,provider,tokens,cost_usd
            2026-08-24,claude,0,0
            2026-08-29,claude,100,
            2026-08-30,claude,430,0.00363
            2026-08-30,codex,1000000,3
            """ + "\n")
    }

    // MARK: - JSON (array {day, provider, tokens, costUsd|null})

    @Test("JSON golden: pretty, chaves ordenadas, nulo de custo EXPLÍCITO")
    func jsonGoldenFromRows() throws {
        // Linhas manuais (custos exatos em ponto flutuante) — golden de FORMATO
        // byte a byte, sem risco de µulp de SUM do SQLite.
        let data = try HistorySeriesFormat.json(from: [
            AppDatabase.DailySeriesRow(day: "2026-08-24", provider: "claude", tokens: 0, costUSD: 0),
            AppDatabase.DailySeriesRow(day: "2026-08-29", provider: "claude", tokens: 100, costUSD: nil),
            AppDatabase.DailySeriesRow(day: "2026-08-30", provider: "codex", tokens: 1_000_000, costUSD: 12.5),
        ])
        #expect(String(decoding: data, as: UTF8.self) == """
            [
              {
                "costUsd" : 0,
                "day" : "2026-08-24",
                "provider" : "claude",
                "tokens" : 0
              },
              {
                "costUsd" : null,
                "day" : "2026-08-29",
                "provider" : "claude",
                "tokens" : 100
              },
              {
                "costUsd" : 12.5,
                "day" : "2026-08-30",
                "provider" : "codex",
                "tokens" : 1000000
              }
            ]
            """)
    }

    @Test("JSON vazio: [] compacto (não o pretty-printed quebrado do encoder)")
    func jsonEmptyIsCompactArray() throws {
        let data = try HistorySeriesFormat.json(from: [])
        #expect(String(decoding: data, as: UTF8.self) == "[]")
    }

    @Test("JSON round-trip: decode sintetizado preserva costUsd nil ≠ 0 e ordena igual ao CSV")
    func jsonRoundTripPreservesNullCost() throws {
        let rows = try db.dailySeries(days: 7, now: now)
        let data = try HistorySeriesFormat.json(from: rows)
        let decoded = try JSONDecoder().decode([HistorySeriesFormat.JSONRow].self, from: data)
        #expect(decoded.count == 4)
        #expect(decoded.map(\.day) == ["2026-08-24", "2026-08-29", "2026-08-30", "2026-08-30"])
        let noPrice = try #require(decoded.first { $0.day == "2026-08-29" })
        #expect(noPrice.costUsd == nil)   // NULL preservado (não 0)
        #expect(noPrice.tokens == 100)
        let zero = try #require(decoded.first { $0.day == "2026-08-24" })
        #expect(zero.costUsd == 0)        // custo zero REAL (não null)
        #expect(zero.tokens == 0)
        let codex = try #require(decoded.first { $0.provider == "codex" })
        #expect(codex.costUsd == 3)
        #expect(codex.tokens == 1_000_000)
    }

    // MARK: - Flags do CLI via a query que o subcomando chama

    @Test("--provider: CSV só do provider pedido (codex)")
    func providerFilter() throws {
        let csv = HistorySeriesFormat.csv(from: try db.dailySeries(provider: .codex, days: 7, now: now))
        #expect(csv == """
            day,provider,tokens,cost_usd
            2026-08-30,codex,1000000,3
            """ + "\n")
    }

    @Test("--days 1: só hoje (janela de 1 dia)")
    func daysWindowOne() throws {
        let csv = HistorySeriesFormat.csv(from: try db.dailySeries(days: 1, now: now))
        #expect(csv == """
            day,provider,tokens,cost_usd
            2026-08-30,claude,430,0.00363
            2026-08-30,codex,1000000,3
            """ + "\n")
    }

    @Test("--days 8: inclui d-7 (2026-08-23, 80 tok) que o default 7d exclui")
    func daysWindowEight() throws {
        let days8 = try db.dailySeries(days: 8, now: now)
        #expect(days8.map { "\($0.day)|\($0.provider)|\($0.tokens)" }.contains("2026-08-23|claude|80"))
        let days7 = try db.dailySeries(days: 7, now: now)
        #expect(!days7.contains { $0.day == "2026-08-23" })
    }

    // MARK: - DB vazio / sem dados

    @Test("DB vazio: CSV só header (LF final) e JSON [] — exit 0 é contrato")
    func emptyDatabase() throws {
        let emptyDir = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyDB = try AppDatabase.open(
            at: emptyDir.appendingPathComponent(AppDatabase.databaseName), calendar: utc)
        let rows = try emptyDB.dailySeries(days: 7, now: now)
        #expect(rows.isEmpty)
        #expect(HistorySeriesFormat.csv(from: rows) == "day,provider,tokens,cost_usd\n")
        #expect(String(decoding: try HistorySeriesFormat.json(from: rows), as: UTF8.self) == "[]")
    }

    @Test("provider sem histórico na janela: CSV header-only pelo filtro")
    func providerWithoutData() throws {
        let csv = HistorySeriesFormat.csv(from: try db.dailySeries(provider: .zai, days: 7, now: now))
        #expect(csv == "day,provider,tokens,cost_usd\n")
    }
}
