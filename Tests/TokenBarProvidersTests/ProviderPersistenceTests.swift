import Darwin
import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

/// F3 Task 1 — providers persistindo eventos na ingest (aditivo ao ledger):
/// persistência na mesma passada, re-ingest de rollover NÃO duplica o
/// histórico, dedupe Gemini sobrevive no DB, falha de persistência não
/// derruba o ingest, e o perf smoke de 100k eventos (orçamento <10s).
@Suite
final class ProviderPersistenceTests {
    let dir: URL
    let now = Date(timeIntervalSince1970: 1_788_000_000)  // fixo: determinístico
    let persistDir: URL

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provpersist-\(UUID().uuidString)", isDirectory: true)
        persistDir = dir.appendingPathComponent("persist", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: persistDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeDatabase() throws -> AppDatabase {
        try AppDatabase.open(at: persistDir.appendingPathComponent(AppDatabase.databaseName), calendar: calendar)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func claudeLine(ts: Date, model: String, input: Int64, output: Int64) -> String {
        #"{"type":"assistant","timestamp":"\#(Self.iso(ts))","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    // MARK: - Claude

    @Test("claude: ingest persiste eventos e daily_agg; segunda ingest não duplica")
    func claudePersistsEventsOnce() async throws {
        let db = try makeDatabase()
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try (
            claudeLine(ts: now, model: "claude-sonnet-4-6", input: 100, output: 200) + "\n" +
            claudeLine(ts: now, model: "claude-opus-4-6", input: 10, output: 20) + "\n"
        ).write(to: projects.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let provider = ClaudeProvider(
            projectsDirectory: projects,
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            persisting: db)
        let first = try await provider.ingestOnce(now: now)
        #expect(first.eventsApplied == 2)
        #expect(try db.usageEventCount(provider: .claude) == 2)
        #expect(try db.dailyAggRows(provider: .claude).count == 2)

        let second = try await provider.ingestOnce(now: now)
        #expect(second.eventsApplied == 0)
        #expect(try db.usageEventCount(provider: .claude) == 2, "ingest inalterado não pode re-persistir")
    }

    @Test("claude: rollover re-escaneia o arquivo e o histórico do DB NÃO dobra")
    func claudeRolloverRescanDoesNotDuplicateDatabase() async throws {
        let db = try makeDatabase()
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("s1.jsonl")

        // Dia 1: 3 eventos históricos.
        try (
            claudeLine(ts: now, model: "m", input: 1, output: 1) + "\n" +
            claudeLine(ts: now, model: "m", input: 2, output: 2) + "\n" +
            claudeLine(ts: now, model: "m", input: 3, output: 3) + "\n"
        ).write(to: file, atomically: true, encoding: .utf8)

        let provider = ClaudeProvider(
            projectsDirectory: projects,
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            persisting: db)
        _ = try await provider.ingestOnce(now: now)
        #expect(try db.usageEventCount(provider: .claude) == 3)

        // Dia 2: rollover → cursores zerados → re-scan RELÊ O ARQUIVO INTEIRO.
        // O ledger reconta só o dia; o DB não pode ganhar nenhuma linha.
        let nextDay = now.addingTimeInterval(86_400)
        let rolled = try await provider.ingestOnce(now: nextDay)
        #expect(rolled.eventsApplied >= 3, "re-scan re-entrega o arquivo (comportamento F1/F2 do ledger)")
        #expect(try db.usageEventCount(provider: .claude) == 3, "marca d'água dedupa o re-scan de rollover")
        let totals = try db.dailyAggRows(provider: .claude)
        #expect(totals.reduce(Int64(0)) { $0 + $1.inputTokens } == 6)

        // Append no dia 2: bytes novos (endOffset > hwm) entram exatamente 1×.
        let line = claudeLine(ts: nextDay, model: "m", input: 50, output: 50) + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        _ = try await provider.ingestOnce(now: nextDay)
        #expect(try db.usageEventCount(provider: .claude) == 4, "só o append entra no DB")
        #expect(totals.reduce(Int64(0)) { $0 + $1.inputTokens } == 6)
        let day2 = try db.dailyAggRows(provider: .claude).filter { $0.day == db.dayString(from: nextDay) }
        #expect(day2.reduce(Int64(0)) { $0 + $1.inputTokens } == 50)
    }

    // MARK: - Codex / Gemini

    @Test("codex: ingest persiste eventos")
    func codexPersistsEvents() async throws {
        let db = try makeDatabase()
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let turnContext = #"{"timestamp":"\#(Self.iso(now))","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#
        let tokenCount = #"{"timestamp":"\#(Self.iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":11,"output_tokens":22,"cached_input_tokens":3}}}}"#
        try (turnContext + "\n" + tokenCount + "\n")
            .write(to: sessions.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)

        let provider = CodexProvider(
            sessionsDirectory: sessions,
            authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("missing-auth.json")),
            client: UsageHTTPClient(baseURL: URL(string: "http://127.0.0.1:1")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            persisting: db)
        _ = try await provider.ingestLocal(
            AccountRef(id: AccountID(provider: .codex, key: "local"), label: "local"),
            from: IngestCursor(), now: now)
        #expect(try db.usageEventCount(provider: .codex) == 1)
        let row = try #require(try db.dailyAggRows(provider: .codex).first)
        #expect(row.inputTokens == 11 && row.outputTokens == 22 && row.cacheReadTokens == 3)
    }

    @Test("gemini: dedupe por id ANTES da persistência — duplicata não vira linha no DB")
    func geminiDedupeKeepsDatabaseClean() async throws {
        let db = try makeDatabase()
        let chats = dir.appendingPathComponent("gemini/tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        // A MESMA linha-raiz 2× no arquivo (reanexo do CLI, spec F2 §3.3).
        let line = #"{"type":"gemini","id":"msg-1","model":"gemini-3-pro","tokens":{"input":10,"output":5,"thoughts":2,"tool":1,"cached":0}}"#
        try (line + "\n" + line + "\n")
            .write(to: chats.appendingPathComponent("session-1.jsonl"), atomically: true, encoding: .utf8)

        let provider = GeminiProvider(
            geminiDirectory: dir.appendingPathComponent("gemini"),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            persisting: db)
        let batch = try await provider.ingestLocal(
            AccountRef(id: AccountID(provider: .gemini, key: "local"), label: "local"),
            from: IngestCursor(), now: now)
        #expect(batch.eventsApplied == 1)
        #expect(try db.usageEventCount(provider: .gemini) == 1)
        let row = try #require(try db.dailyAggRows(provider: .gemini).first)
        #expect(row.outputTokens == 8)  // output+thoughts+tool (F2-GEMINI-FIELDS)
    }

    // MARK: - Degradação

    /// Persistência que SEMPRE falha (disco cheio/DB corrompido).
    struct FailingPersisting: UsageEventPersisting {
        func persistBatch(provider: ProviderID, path: String, events: [UsageEvent], endOffset: UInt64, resetToZero: Bool) throws {
            struct DiskFull: Error {}
            throw DiskFull()
        }
    }

    @Test("falha de persistência NÃO derruba o ingest (degrada para comportamento F2)")
    func persistenceFailureDoesNotBreakIngest() async throws {
        let projects = dir.appendingPathComponent("projects2", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try (claudeLine(ts: now, model: "m", input: 7, output: 8) + "\n")
            .write(to: projects.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let provider = ClaudeProvider(
            projectsDirectory: projects,
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar,
            persisting: FailingPersisting())
        let outcome = try await provider.ingestOnce(now: now)
        // O display do dia (ledger) segue correto — persistência é aditiva.
        #expect(outcome.eventsApplied == 1)
        #expect(outcome.providerTotals[.claude] == 15)
    }

    // MARK: - Perf smoke (orçamento: ingest+persistence de 100k <10s)

    @Test("perf smoke: 100k eventos sintéticos ingest+persistence <10s, memória bounded")
    func perfSmoke100kEventsInUnder10Seconds() async throws {
        let db = try makeDatabase()
        let projects = dir.appendingPathComponent("projects-perf", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        // Corpus sintético em formato Claude real (parser JSON completo no caminho).
        let lineCount = 100_000
        let file = projects.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunkLines = 1_000
        var buffer = ""
        for i in 0..<lineCount {
            buffer += claudeLine(
                ts: now.addingTimeInterval(TimeInterval(i % 3_600)),
                model: i % 2 == 0 ? "claude-sonnet-4-6" : "claude-opus-4-6",
                input: Int64(i % 1_000) + 1, output: Int64(i % 500) + 1)
            buffer += "\n"
            if (i + 1) % chunkLines == 0 {
                try handle.write(contentsOf: Data(buffer.utf8))
                buffer = ""
            }
        }

        // Stack REAL: DBOffsetStore (cursores no settings) + AppDatabase.
        let provider = ClaudeProvider(
            projectsDirectory: projects,
            offsetStore: DBOffsetStore(database: db, provider: .claude),
            calendar: calendar,
            persisting: db)

        let start = ContinuousClock.now
        _ = try await provider.ingestOnce(now: now)
        let elapsed = ContinuousClock.now - start
        let budget: Duration = .seconds(10)
        #expect(elapsed < budget, "100k eventos em \(elapsed) — orçamento é 10s")

        #expect(try db.usageEventCount(provider: .claude) == lineCount)
        // Soma por modelo (grupada: linhas podem repartir por dia perto da meia-noite).
        var byModel: [String: Int64] = [:]
        for row in try db.dailyAggRows(provider: .claude) {
            byModel[row.model, default: 0] += row.inputTokens + row.outputTokens
        }
        var sonnetSum: Int64 = 0, opusSum: Int64 = 0
        for i in 0..<lineCount {
            let s = Int64(i % 1_000) + 1 + Int64(i % 500) + 1
            if i % 2 == 0 { sonnetSum += s } else { opusSum += s }
        }
        #expect(byModel == ["claude-sonnet-4-6": sonnetSum, "claude-opus-4-6": opusSum])
        // Cursor persistido (bounded: sem retenção de eventos em memória).
        #expect(try db.highWater(provider: .claude, path: resolvedPath(file.path)) != nil)
    }
}

/// Resolve o path como o `FileManager.enumerator` faz (realpath: /var →
/// /private/var) — as chaves de marca d'água/cursores usam o path da scan.
func resolvedPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}
