import Foundation
import GRDB
import Testing
@testable import TokenBarCore

/// Red Team F3 (Task 5) — regressões de persistência/export contra hostilidade:
/// DB corrompido/truncado (caso 1), re-semeadura stale da migração quando o
/// rename falha persistentemente (caso 4), export de 10k eventos com campo
/// hostil válidos por RFC 4180 (caso 5) e strings SQL-hostis em model/path
/// via prepared statements (caso 6). Migrations re-run (caso 3) e disco cheio
/// (caso 2) estão cobertos em PersistenceTests/ProviderPersistenceTests e no
/// E2E v3 (seção 9).
@Suite
final class RedTeamF3Tests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-rt3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    var databaseURL: URL {
        dir.appendingPathComponent(AppDatabase.databaseName)
    }

    func event(ts: Date, model: String?, input: Int64 = 10, output: Int64 = 20,
               provider: ProviderID = .claude) -> UsageEvent {
        UsageEvent(
            ts: ts, provider: provider, account: AccountID(provider: provider, key: "local"),
            model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)
    }

    // MARK: - Caso 1: DB corrompido/truncado

    @Test("DB com bytes lixo (não-SQLite): open lança erro — degrada F2, nunca crash")
    func corruptDatabaseThrowsOnOpen() throws {
        // Lixo que NÃO tem o header SQLite ("SQLite format 3\0").
        var garbage = [UInt8](repeating: 0, count: 4_096)
        for i in 0..<garbage.count { garbage[i] = UInt8((i * 7 + 13) % 251) }
        try Data(garbage).write(to: databaseURL)
        #expect(throws: (Error).self) {
            _ = try AppDatabase.open(at: databaseURL)
        }
    }

    @Test("DB truncado no meio de uma página: open lança ou abre sem corromper mais (nunca crash)")
    func truncatedDatabaseDoesNotCrashOnOpen() throws {
        // DB saudável truncado ao meio (simula crash de disco durante escrita).
        let db = try AppDatabase.open(at: databaseURL)
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        for i in 0..<500 {
            try db.persistBatch(
                provider: .claude, path: "/p/f\(i).jsonl",
                events: [event(ts: now, model: "claude-sonnet-4-6")],
                endOffset: UInt64(i * 1_000), resetToZero: false)
        }
        let goodSize = try Data(contentsOf: databaseURL).count
        try Data(contentsOf: databaseURL).prefix(goodSize / 2).write(to: databaseURL)

        // Reabrir NÃO crasha: ou o banco abre e responde (WAL intacto), ou o
        // erro ("database disk image is malformed") vem como Swift Error
        // capturável — exatamente o que o `try?`/do-catch do coordinator e das
        // queries consomem para degradar em modo F2. Número nunca é inventado.
        let reopened = try? AppDatabase.open(at: databaseURL)
        let count = reopened.flatMap { try? $0.usageEventCount() }
        #expect(count == nil || count == 200)
    }

    // MARK: - Caso 4: re-semeadura stale (rename falho persistente)

    @Test("re-migração stale (rename falho): cursor re-semeado atrás do hwm não duplica o banco e auto-recupera na próxima escrita do store")
    func staleReMigrationDoesNotDuplicateAndRecovers() throws {
        let db = try makeDatabase()
        let path = "/home/u/.claude/projects/p/rt4.jsonl"

        // Migração legítima (offset 100) e ingest avança hwm + cursor p/ 5_000.
        let legacy = dir.appendingPathComponent("claude-cursors.json")
        func plantLegacy(_ offset: UInt64) throws {
            try JSONEncoder().encode([path: FileCursor(offset: offset)]).write(to: legacy)
        }
        try plantLegacy(100)
        #expect(CursorMigrator.migrate(provider: .claude, jsonURL: legacy, database: db))
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        try db.persistBatch(
            provider: .claude, path: path,
            events: [event(ts: now, model: "claude-sonnet-4-6")],
            endOffset: 5_000, resetToZero: false)
        #expect(try db.usageEventCount() == 1)

        // Cenário "rename falho persistente" (dir readonly, chflags uchg…):
        // o arquivo legado STALE sobrevive e a migração re-roda a cada launch —
        // settings é REESCRITO com o offset velho (re-semeadura, documentado
        // na T1), mas a marca d'água NÃO rebaixa (INSERT OR IGNORE).
        try plantLegacy(100)
        #expect(CursorMigrator.migrate(provider: .claude, jsonURL: legacy, database: db))
        #expect(try db.highWater(provider: .claude, path: path) == 5_000)

        // O store vivo re-semeado fica STALE (100) → o provider relê bytes
        // 100..5_000 e os re-entrega: a persistência DESCARTA (hwm) — o
        // histórico não dobra mesmo com o cursor voltando no tempo.
        let staleStore = DBOffsetStore(database: db, provider: .claude)
        #expect(staleStore.cursors()[path]?.offset == 100)  // re-semeadura confirmada
        try db.persistBatch(
            provider: .claude, path: path,
            events: [event(ts: now, model: "claude-sonnet-4-6", input: 999, output: 999)],
            endOffset: 5_000, resetToZero: false)
        #expect(try db.usageEventCount() == 1)
        #expect(try db.dailyAggRows()[0].inputTokens == 10)  // sem o 999 duplicado

        // Auto-recuperação: a 1ª escrita do store vivo sobrescreve o mapa
        // inteiro (rollover/ciclo normal) e o stale sai do settings.
        try staleStore.set(FileCursor(offset: 6_000), for: path)
        #expect(DBOffsetStore(database: db, provider: .claude).cursors()[path]?.offset == 6_000)

        // E bytes NOVOS (> hwm) persistem exatamente 1×.
        try db.persistBatch(
            provider: .claude, path: path,
            events: [event(ts: now, model: "claude-sonnet-4-6", input: 3, output: 4)],
            endOffset: 6_000, resetToZero: false)
        try db.persistBatch(
            provider: .claude, path: path,
            events: [event(ts: now, model: "claude-sonnet-4-6", input: 3, output: 4)],
            endOffset: 6_000, resetToZero: false)
        #expect(try db.usageEventCount() == 2)
        #expect(try db.dailyAggRows()[0].inputTokens == 13)
    }

    // MARK: - Caso 5: export hostil (RFC 4180)

    /// Parser CSV RFC 4180 mínimo (aspas, "" escape, vírgula, LF/CRLF) —
    /// o "parseie de volta" do caso 5 não pode usar split(",") (quebraria).
    func parseRFC4180(_ text: String) -> [[String]] {
        var rows: [[String]] = [[]]
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": rows[rows.count - 1].append(field); field = ""
                case "\r": break  // \r\n e \r solto viram fim de linha no \n
                case "\n":
                    rows[rows.count - 1].append(field); field = ""
                    rows.append([])
                default: field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || rows.last! != [] { rows[rows.count - 1].append(field) }
        if rows.last == [] { rows.removeLast() }
        return rows
    }

    @Test("export hostil: 10k eventos com model , \" quebra-de-linha → CSV RFC 4180 parseia de volta exato")
    func exportHostileModelsRoundTripsRFC4180() throws {
        let db = try AppDatabase.open(at: databaseURL)
        let hostile = "a,b\"c\nd;'--\tDROP"
        let now = Date()
        let events = (0..<10_000).map { i -> UsageEvent in
            event(ts: now.addingTimeInterval(TimeInterval(-i)), model: i % 2 == 0 ? hostile : "claude-sonnet-4-6", input: Int64(i), output: 1)
        }
        try db.persistBatch(provider: .claude, path: "/p/hostil.jsonl", events: events, endOffset: 9_999_999, resetToZero: false)
        #expect(try db.usageEventCount() == 10_000)

        let exporter = HistoryExporter(database: db, supportDirectory: dir)
        let urls = try exporter.exportAll()
        #expect(urls.count == 2)

        let csv = String(decoding: try Data(contentsOf: urls[0]), as: UTF8.self)
        let rows = parseRFC4180(csv)
        #expect(rows.count == 10_001)  // header + 10k
        #expect(rows[0] == ["ts", "provider", "account", "model", "tokens", "cost_usd"])

        // Linha = modelo hostil: o campo volta EXATO (vírgula, aspas, quebra
        // de linha preservados pela citação RFC 4180). A ordem do export é
        // ts ASC → o primeiro hostil é o mais antigo (os pares são hostis:
        // i = 9998 → tokens = 9998 input + 1 output).
        let hostileRow = try #require(rows.first { $0[3] == hostile })
        #expect(hostileRow[1] == "claude" && hostileRow[2] == "local")
        #expect(hostileRow[4] == "9999")
        #expect(hostileRow[5] == "")    // modelo sem preço → custo VAZIO (não "0")
        #expect(rows.filter { $0[3] == hostile }.count == 5_000)

        // JSON: mesmo dado estruturado, nulos explícitos, roundtrip por Codable.
        let json = try JSONDecoder().decode(HistoryExporter.Document.self, from: try Data(contentsOf: urls[1]))
        #expect(json.rows.count == 10_000)
        #expect(json.rows.filter { $0.model == hostile }.count == 5_000)
        #expect(json.rows.filter { $0.model == hostile }.allSatisfy { $0.costUSD == nil })
        #expect(json.rows.filter { $0.model == "claude-sonnet-4-6" }.allSatisfy { $0.costUSD != nil })
    }

    // MARK: - Caso 6: SQL injection via strings

    @Test("SQL injection em model/path: prepared statements seguram — banco íntegro e dado recuperável")
    func hostileSQLStringsStayBound() throws {
        let db = try makeDatabase()
        let evilModel = "x'); DROP TABLE usage_events;--"
        let evilPath = "/p/'; DROP TABLE settings;--.jsonl"
        let now = Date()  // dentro da janela 7d das queries de leitura abaixo

        try db.persistBatch(
            provider: .claude, path: evilPath,
            events: [event(ts: now, model: evilModel), event(ts: now, model: "claude-sonnet-4-6")],
            endOffset: 4_242, resetToZero: false)

        // As tabelas "derrubadas" pelas strings continuam lá e consistentes.
        #expect(try db.usageEventCount() == 2)
        let aliveTables = try db.writer.read { db in
            try ["usage_events", "settings", "daily_agg"].filter { try db.tableExists($0) }
        }
        #expect(Set(aliveTables) == ["usage_events", "settings", "daily_agg"])
        // Dado com string hostil é recuperável EXATO (roundtrip, não mutação).
        let rows = try db.dailyAggRows()
        #expect(rows.contains { $0.model == evilModel && $0.inputTokens == 10 })
        #expect(try db.highWater(provider: .claude, path: evilPath) == 4_242)

        // Queries de leitura da UI com o dado hostil no banco seguem ok.
        #expect(try db.dailySeries(days: 7).count >= 1)
        #expect(try db.weekTotal(provider: .claude).tokens == 60)
        // Segundo lote no MESMO path hostil: dedupe e escrita seguem corretos.
        try db.persistBatch(
            provider: .claude, path: evilPath,
            events: [event(ts: now, model: evilModel)],
            endOffset: 4_242, resetToZero: false)
        #expect(try db.usageEventCount() == 2)  // hwm descarta re-entrega
    }

    func makeDatabase() throws -> AppDatabase {
        try AppDatabase.open(at: databaseURL)
    }
}
