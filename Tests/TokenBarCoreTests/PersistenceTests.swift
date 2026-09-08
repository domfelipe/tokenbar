import Foundation
import GRDB
import Testing
@testable import TokenBarCore

/// F3 Task 1 — persistência: migrations §6 idempotentes, settings roundtrip,
/// evento→daily_agg consistente, dedupe por marca d'água (re-ingest NÃO
/// duplica o histórico) e migração de cursores legados F1/F2.
@Suite
final class PersistenceTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeDatabase() throws -> AppDatabase {
        try AppDatabase.open(at: dir.appendingPathComponent(AppDatabase.databaseName))
    }

    func event(ts: Date, model: String?, input: Int64 = 10, output: Int64 = 20,
               cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
               provider: ProviderID = .claude, account: String = "local",
               project: String? = "proj") -> UsageEvent {
        UsageEvent(
            ts: ts, provider: provider, account: AccountID(provider: provider, key: account),
            model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            project: project)
    }

    // MARK: - Migrations (spec §6, idempotentes)

    @Test("migration v1 cria o schema §6 completo e é idempotente")
    func migrationsCreateSchemaAndAreIdempotent() throws {
        let db = try makeDatabase()

        // Reabrir o MESMO arquivo NÃO re-roda a migration (nem lança).
        let reopened = try AppDatabase.open(at: dir.appendingPathComponent(AppDatabase.databaseName))

        try db.writer.read { db in
            for table in ["usage_events", "daily_agg", "accounts", "pricing", "alert_rules", "settings"] {
                #expect(try db.tableExists(table), "tabela \(table) ausente (spec §6)")
            }
            #expect(try db.indexes(on: "usage_events").map(\.name).contains("idx_events_ts"))
            #expect(try db.indexes(on: "usage_events").map(\.name).contains("idx_events_provider_ts"))

            // Colunas batem com o DDL da spec (spot-check das críticas).
            let columns = try Set(db.columns(in: "usage_events").map(\.name))
            for expected in ["id", "ts", "provider", "account", "model", "input_tokens",
                             "output_tokens", "cache_read_tokens", "cache_write_tokens",
                             "cost_usd", "source", "project"] {
                #expect(columns.contains(expected))
            }
            let aggColumns = try Set(db.columns(in: "daily_agg").map(\.name))
            #expect(aggColumns.contains("day") && aggColumns.contains("model") && aggColumns.contains("cost_usd"))
        }
        _ = reopened  // reabertura sem throw já cobre a idempotência do migrator
    }

    @Test("abertura em path inválido lança (coordinator degrada) — sem crash")
    func openAtInvalidPathThrows() {
        // Pai é um ARQUIVO: DatabasePool não consegue criar o sqlite.
        let file = dir.appendingPathComponent("blocker")
        try? Data("x".utf8).write(to: file)
        #expect(throws: (Error).self) {
            _ = try AppDatabase.open(at: file.appendingPathComponent("db.sqlite"))
        }
    }

    // MARK: - Settings roundtrip

    @Test("settings roundtrip: set/get/delete")
    func settingsRoundtrip() throws {
        let db = try makeDatabase()
        #expect(try db.setting(forKey: "k") == nil)
        try db.setSetting("v1", forKey: "k")
        #expect(try db.setting(forKey: "k") == "v1")
        try db.setSetting("v2", forKey: "k")  // upsert
        #expect(try db.setting(forKey: "k") == "v2")
        try db.setSetting(nil, forKey: "k")   // delete
        #expect(try db.setting(forKey: "k") == nil)
        try db.setSetting(nil, forKey: "inexistente")  // delete idempotente
    }

    // MARK: - evento→daily_agg consistente

    @Test("persistBatch: usage_events + daily_agg consistentes (soma por dia/provider/modelo)")
    func persistBatchWritesEventsAndDailyAgg() throws {
        let db = try makeDatabase()
        let cal = Calendar.current
        let day1 = cal.startOfDay(for: Date(timeIntervalSince1970: 1_788_000_000))
        let day2 = day1.addingTimeInterval(86_400)

        // Lote 1: 2 modelos, 2 dias.
        let batch1 = [
            event(ts: day1.addingTimeInterval(3_600), model: "claude-sonnet-4-6", input: 100, output: 200),
            event(ts: day1.addingTimeInterval(7_200), model: "claude-sonnet-4-6", input: 1, output: 2, cacheRead: 3000),
            event(ts: day1.addingTimeInterval(3_600), model: "claude-opus-4-6", input: 7, output: 8),
            event(ts: day2.addingTimeInterval(3_600), model: "claude-sonnet-4-6", input: 5, output: 6),
            event(ts: day2.addingTimeInterval(3_600), model: nil, input: 9, output: 9),  // sem model → "unknown"
        ]
        try db.persistBatch(provider: .claude, path: "/x/a.jsonl", events: batch1, endOffset: 1_000, resetToZero: false)

        // Lote 2 (mesmo dia/modelo de batch1): daily_agg ACUMULA na mesma chave.
        let batch2 = [
            event(ts: day1.addingTimeInterval(4_600), model: "claude-sonnet-4-6", input: 10, output: 20),
        ]
        try db.persistBatch(provider: .claude, path: "/x/b.jsonl", events: batch2, endOffset: 500, resetToZero: false)

        #expect(try db.usageEventCount() == 6)
        #expect(try db.usageEventCount(provider: .claude) == 6)
        #expect(try db.usageEventCount(provider: .codex) == 0)

        let rows = try db.dailyAggRows(provider: .claude)
        let sonnetDay1 = try #require(rows.first {
            $0.day == db.dayString(from: day1) && $0.model == "claude-sonnet-4-6"
        })
        #expect(sonnetDay1.inputTokens == 111)   // 100 + 1 + 10
        #expect(sonnetDay1.outputTokens == 222)  // 200 + 2 + 20
        #expect(sonnetDay1.cacheReadTokens == 3000)
        let opusDay1 = try #require(rows.first { $0.model == "claude-opus-4-6" })
        #expect(opusDay1.inputTokens == 7 && opusDay1.outputTokens == 8)
        let sonnetDay2 = try #require(rows.first { $0.day == db.dayString(from: day2) && $0.model == "claude-sonnet-4-6" })
        #expect(sonnetDay2.inputTokens == 5 && sonnetDay2.outputTokens == 6)
        let unknown = try #require(rows.first { $0.model == AppDatabase.unknownModel })
        #expect(unknown.inputTokens == 9)
        #expect(rows.count == 4)  // sonnet-d1, opus-d1, sonnet-d2, unknown-d2

        // Marca d'água por arquivo registrada na mesma transação.
        #expect(try db.highWater(provider: .claude, path: "/x/a.jsonl") == 1_000)
        #expect(try db.highWater(provider: .claude, path: "/x/b.jsonl") == 500)
    }

    @Test("dedupe por marca d'água: re-ingest (rollover/cursor perdido) NÃO duplica o histórico")
    func highWaterDedupesReingest() throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_788_000_000)

        // Ciclo 1: lote cobre bytes até 1_000.
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [event(ts: now, model: "m1", input: 1, output: 1)],
            endOffset: 1_000, resetToZero: false)

        // Rollover re-entrega o MESMO trecho (endOffset <= hwm) e trechos
        // intermediários também — nada é re-persistido.
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [event(ts: now, model: "m1", input: 1, output: 1)],
            endOffset: 1_000, resetToZero: false)
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [event(ts: now, model: "m1", input: 5, output: 5)],
            endOffset: 600, resetToZero: false)
        #expect(try db.usageEventCount() == 1)
        #expect(try db.dailyAggRows()[0].inputTokens == 1)

        // Bytes novos (endOffset > hwm): entram normalmente.
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [event(ts: now, model: "m1", input: 9, output: 9)],
            endOffset: 2_500, resetToZero: false)
        #expect(try db.usageEventCount() == 2)
        #expect(try db.dailyAggRows()[0].inputTokens == 10)
        #expect(try db.highWater(provider: .claude, path: "/x/a.jsonl") == 2_500)

        // Lote vazio que só avança offset (segmento sem eventos parseáveis).
        try db.persistBatch(provider: .claude, path: "/x/a.jsonl", events: [], endOffset: 3_000, resetToZero: false)
        #expect(try db.usageEventCount() == 2)
        #expect(try db.highWater(provider: .claude, path: "/x/a.jsonl") == 3_000)
    }

    @Test("resetToZero (arquivo encolheu): marca d'água descartada e conteúdo re-lido persiste")
    func resetToZeroClearsHighWater() throws {
        let db = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        try db.persistBatch(
            provider: .gemini, path: "/x/s.jsonl",
            events: [event(ts: now, model: "gemini-3-pro", input: 4, output: 4, provider: .gemini)],
            endOffset: 900, resetToZero: false)
        #expect(try db.highWater(provider: .gemini, path: "/x/s.jsonl") == 900)

        // Truncou: reset sinalizado com lote vazio — hwm volta a 0.
        try db.persistBatch(provider: .gemini, path: "/x/s.jsonl", events: [], endOffset: 0, resetToZero: true)
        #expect(try db.highWater(provider: .gemini, path: "/x/s.jsonl") == 0)

        // Conteúdo re-escrito entra como novo (bytes > 0 agora passam o guard).
        try db.persistBatch(
            provider: .gemini, path: "/x/s.jsonl",
            events: [event(ts: now, model: "gemini-3-pro", input: 6, output: 6, provider: .gemini)],
            endOffset: 120, resetToZero: false)
        #expect(try db.usageEventCount(provider: .gemini) == 2)
    }

    // MARK: - Migração de cursores legados F1/F2

    /// Fixture no formato EXATO do JSONFileOffsetStore (F1/F2).
    func writeLegacyCursors(_ name: String, map: [String: FileCursor]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let data = try JSONEncoder().encode(map)
        try data.write(to: url)
        return url
    }

    @Test("migração de cursor legado: settings + marcas d'água + rename .migrated + reuso dos offsets")
    func cursorMigrationMigratesLegacyJSON() throws {
        let db = try makeDatabase()
        let path = "/home/u/.claude/projects/p/s1.jsonl"
        let url = try writeLegacyCursors("claude-cursors.json", map: [
            path: FileCursor(offset: 123_456, seenIDs: ["id-1", "id-2"]),
        ])

        #expect(CursorMigrator.migrate(provider: .claude, jsonURL: url, database: db))

        // Settings carrega o mapa legado (reuso dos offsets).
        let stored = try #require(try db.setting(forKey: "cursors:claude"))
        let decoded = try JSONDecoder().decode([String: FileCursor].self, from: Data(stored.utf8))
        #expect(decoded[path] == FileCursor(offset: 123_456, seenIDs: ["id-1", "id-2"]))

        // Marca d'água semeada com o offset legado (bytes pré-F3 não voltam).
        #expect(try db.highWater(provider: .claude, path: path) == 123_456)

        // Arquivo renomeado para .migrated.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.path + ".migrated"))

        // Idempotente: reabrir e migrar de novo é no-op (sem throw, sem mudança).
        #expect(!CursorMigrator.migrate(provider: .claude, jsonURL: url, database: db))
        #expect(try db.setting(forKey: "cursors:claude") == stored)

        // O store VIVO semeia dos offsets migrados — continuidade F1/F2→F3.
        let store = DBOffsetStore(database: db, provider: .claude)
        #expect(store.cursors() == [path: FileCursor(offset: 123_456, seenIDs: ["id-1", "id-2"])])

        // Escrita no store vivo persiste no settings (persistência do cursor).
        try store.set(FileCursor(offset: 200_000), for: path)
        #expect(try db.setting(forKey: "cursors:claude")!.contains("200000"))
        #expect(DBOffsetStore(database: db, provider: .claude).cursors()[path]?.offset == 200_000)
    }

    @Test("migração de cursor legado Gemini/Codex é independente por provider")
    func cursorMigrationPerProvider() throws {
        let db = try makeDatabase()
        let geminiURL = try writeLegacyCursors("gemini-cursors.json", map: [
            "/home/u/.gemini/tmp/p/chats/session-1.jsonl": FileCursor(offset: 77),
        ])
        #expect(CursorMigrator.migrate(provider: .gemini, jsonURL: geminiURL, database: db))
        #expect(try db.setting(forKey: "cursors:gemini") != nil)
        #expect(try db.setting(forKey: "cursors:codex") == nil)  // sem arquivo → sem migração

        // Cursor inválido (JSON quebrado): loga, retorna false, arquivo FICA
        // (retry na próxima abertura) — degradação, nunca crash.
        let badURL = dir.appendingPathComponent("codex-cursors.json")
        try Data("{não-sou-json".utf8).write(to: badURL)
        #expect(!CursorMigrator.migrate(provider: .codex, jsonURL: badURL, database: db))
        #expect(try db.setting(forKey: "cursors:codex") == nil)
        #expect(FileManager.default.fileExists(atPath: badURL.path))
    }

    @Test("re-migração nunca REBAIXA marca d'água já avançada pela ingest")
    func cursorMigrationNeverLowersHighWater() throws {
        let db = try makeDatabase()
        let path = "/home/u/.claude/projects/p/s2.jsonl"
        let url = try writeLegacyCursors("claude-cursors.json", map: [path: FileCursor(offset: 100)])
        #expect(CursorMigrator.migrate(provider: .claude, jsonURL: url, database: db))

        // A ingest avançou a marca d'água para 5_000.
        try db.persistBatch(
            provider: .claude, path: path,
            events: [event(ts: Date(timeIntervalSince1970: 1_788_000_000), model: "m")],
            endOffset: 5_000, resetToZero: false)

        // O arquivo legado reaparece (restore de backup, por exemplo) com
        // offset antigo: INSERT OR IGNORE mantém 5_000.
        _ = try writeLegacyCursors("claude-cursors.json", map: [path: FileCursor(offset: 100)])
        #expect(CursorMigrator.migrate(provider: .claude, jsonURL: url, database: db))
        #expect(try db.highWater(provider: .claude, path: path) == 5_000)
    }
}
