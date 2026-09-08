import Foundation
import Testing
import TokenBarCore
@testable import TokenBarCore

/// F3 Task 3 — export CSV/JSON: formato É contrato (golden strings byte a
/// byte), escape RFC 4180, nulos explícitos no JSON, NULL de custo vira campo
/// vazio no CSV (nunca "0"), e o arquivo nasce em `<support>/exports/` com
/// nome `history-<timestamp UTC>`.
@Suite
final class HistoryExportTests {
    let dir: URL
    let utc: Calendar
    /// now fixo: 2026-08-30T10:40:00Z (janela 30d: from = 2026-08-01).
    let now = Date(timeIntervalSince1970: 1_788_086_400)
    let db: AppDatabase
    let exporter: HistoryExporter

    static let pricing = PricingTable(
        version: 1, updated: "2026-01-01",
        models: [
            "m-priced": .init(input: 3, output: 15, cacheRead: nil, cacheWrite: nil),
        ])

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        utc = utcCal
        db = try AppDatabase.open(
            at: dir.appendingPathComponent(AppDatabase.databaseName),
            calendar: utc, pricing: Self.pricing)
        exporter = HistoryExporter(database: db, supportDirectory: dir)

        func event(_ epoch: Double, model: String?, input: Int64, output: Int64) -> UsageEvent {
            UsageEvent(
                ts: Date(timeIntervalSince1970: epoch), provider: .claude,
                account: AccountID(provider: .claude, key: "local"),
                model: model, inputTokens: input, outputTokens: output,
                cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)
        }
        // ts 2026-08-29T10:40:00Z, custo (33×3 + 44×15)/1e6 = 0.000759
        // ts 2026-08-29T10:41:00Z, modelo com , e " (escape) e sem preço
        // ts 2026-08-30T10:40:00Z, custo exato 3.0
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [
                event(1_788_000_000, model: "m-priced", input: 33, output: 44),
                event(1_788_000_060, model: "we\"ird,model", input: 500, output: 55),
                event(1_788_000_000, model: nil, input: 12, output: 0),
                event(1_788_086_400, model: "m-priced", input: 1_000_000, output: 0),
            ],
            endOffset: 5_000, resetToZero: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("CSV golden: header, escape RFC 4180, custo NULL vazio, formatCost aparado")
    func csvGolden() throws {
        let events = try db.eventsForExport(days: HistoryExporter.exportDays, now: now)
        let csv = HistoryExporter.csv(from: HistoryExporter.documentRows(from: events))

        #expect(csv == """
            ts,provider,account,model,tokens,cost_usd
            2026-08-29T10:40:00Z,claude,local,m-priced,77,0.000759
            2026-08-29T10:40:00Z,claude,local,,12,
            2026-08-29T10:41:00Z,claude,local,"we""ird,model",555,
            2026-08-30T10:40:00Z,claude,local,m-priced,1000000,3
            """ + "\n")
    }

    @Test("JSON golden: chaves ordenadas, nulos explícitos, metadados versão/período")
    func jsonGolden() throws {
        let data = try HistoryExporter.json(
            from: try db.eventsForExport(days: HistoryExporter.exportDays, now: now),
            now: now, days: HistoryExporter.exportDays, database: db)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json == """
            {
              "generated_at" : "2026-08-30T10:40:00Z",
              "period" : {
                "days" : 30,
                "from" : "2026-08-01",
                "to" : "2026-08-30T10:40:00Z"
              },
              "rows" : [
                {
                  "account" : "local",
                  "cost_usd" : 0.000759,
                  "model" : "m-priced",
                  "provider" : "claude",
                  "tokens" : 77,
                  "ts" : "2026-08-29T10:40:00Z"
                },
                {
                  "account" : "local",
                  "cost_usd" : null,
                  "model" : null,
                  "provider" : "claude",
                  "tokens" : 12,
                  "ts" : "2026-08-29T10:40:00Z"
                },
                {
                  "account" : "local",
                  "cost_usd" : null,
                  "model" : "we\\"ird,model",
                  "provider" : "claude",
                  "tokens" : 555,
                  "ts" : "2026-08-29T10:41:00Z"
                },
                {
                  "account" : "local",
                  "cost_usd" : 3,
                  "model" : "m-priced",
                  "provider" : "claude",
                  "tokens" : 1000000,
                  "ts" : "2026-08-30T10:40:00Z"
                }
              ],
              "version" : 1
            }
            """)
    }

    @Test("formatCost: 6 casas com zeros aparados, determinístico")
    func costFormatting() {
        #expect(HistoryExporter.formatCost(0) == "0")
        #expect(HistoryExporter.formatCost(3.0) == "3")
        #expect(HistoryExporter.formatCost(0.000759) == "0.000759")
        #expect(HistoryExporter.formatCost(12.4561) == "12.4561")
    }

    @Test("csvField: cita só quando precisa e dobra aspas")
    func csvFieldEscaping() {
        #expect(HistoryExporter.csvField("plain") == "plain")
        #expect(HistoryExporter.csvField("a,b") == "\"a,b\"")
        #expect(HistoryExporter.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryExporter.csvField("line\nbreak") == "\"line\nbreak\"")
    }

    @Test("exportAll: escreve CSV e JSON em <support>/exports/ com mesmo conteúdo e timestamp UTC")
    func exportAllWritesBothFiles() throws {
        let urls = try exporter.exportAll(now: now)
        #expect(urls.count == 2)
        // Timestamp do now fixo: 2026-08-29? NÃO — 1_788_086_400 é 2026-08-30
        // 10:40 UTC. Nome estável e ordenável.
        let expectedNames = ["history-20260830-104000.csv", "history-20260830-104000.json"]
        for (url, name) in zip(urls, expectedNames) {
            #expect(url.lastPathComponent == name)
            #expect(url.deletingLastPathComponent().lastPathComponent == "exports")
            #expect(url.deletingLastPathComponent().deletingLastPathComponent().path == dir.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        // Conteúdo dos ARQUIVOS == formatação pura (mesma fonte de dados).
        let events = try db.eventsForExport(days: HistoryExporter.exportDays, now: now)
        let csvOnDisk = try String(contentsOf: urls[0], encoding: .utf8)
        #expect(csvOnDisk == HistoryExporter.csv(from: HistoryExporter.documentRows(from: events)))
        let jsonOnDisk = try String(contentsOf: urls[1], encoding: .utf8)
        #expect(jsonOnDisk == String(
            decoding: try HistoryExporter.json(from: events, now: now, days: HistoryExporter.exportDays, database: db),
            as: UTF8.self))
    }

    @Test("exportAll com banco vazio: arquivos válidos (header + rows vazio)")
    func exportEmptyDatabase() throws {
        let emptyDir = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyDB = try AppDatabase.open(
            at: emptyDir.appendingPathComponent(AppDatabase.databaseName), calendar: utc)
        let exporter = HistoryExporter(database: emptyDB, supportDirectory: emptyDir)
        let urls = try exporter.exportAll(now: now)
        let csv = try String(contentsOf: urls[0], encoding: .utf8)
        #expect(csv == "ts,provider,account,model,tokens,cost_usd\n")
        // JSON válido e decodificável com metadados e rows vazio.
        let json = try String(contentsOf: urls[1], encoding: .utf8)
        let doc = try JSONDecoder().decode(HistoryExporter.Document.self, from: Data(json.utf8))
        #expect(doc.rows.isEmpty)
        #expect(doc.period.days == HistoryExporter.exportDays)
        #expect(doc.version == HistoryExporter.formatVersion)
    }
}
