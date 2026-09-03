import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - Fixtures sintéticas (spec F2 §3.3 — 100% fake, mistura dos DOIS
// formatos de linha no mesmo arquivo: linhas-raiz + delta `$set`)

enum GeminiFixtures {
    static let geminiAccount = AccountID(provider: .gemini, key: "local")
    static let localRef = AccountRef(id: AccountID(provider: .gemini, key: "local"), label: "local")
    static let now = Date(timeIntervalSince1970: 1_788_000_000)  // mesmo fixo dos testes F1/F2

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Linha 1 do arquivo: meta da sessão (`kind: "main"`, sem uso p/ ingest).
    static func metaLine(ts: Date = now) -> String {
        """
        {"kind":"main","sessionId":"fake-session-id","projectHash":"fake-proj",\
        "startTime":"\(iso(ts))","lastUpdated":"\(iso(ts))"}
        """
    }

    /// Formato B — delta `$set` espelhando mensagens SEM tokens (id em hex,
    /// formato diferente do das linhas-raiz; spec §3.3).
    static func setDeltaLine(ts: Date = now) -> String {
        """
        {"$set":{"lastUpdated":"\(iso(ts))","messages":[{"id":"fakehex0001",\
        "timestamp":"\(iso(ts))","type":"user","content":[{"text":"mensagem fake"}]}]}}
        """
    }

    /// Linha-raiz `user` — content ARRAY, sem tokens.
    static func userRootLine(ts: Date = now) -> String {
        """
        {"type":"user","id":"fake-user-uuid","timestamp":"\(iso(ts))",\
        "content":[{"text":"pergunta fake"}]}
        """
    }

    /// Linha-raiz `info` — content STRING, sem tokens.
    static func infoRootLine(ts: Date = now) -> String {
        """
        {"type":"info","id":"fake-info-uuid","timestamp":"\(iso(ts))",\
        "content":"nota fake do cli"}
        """
    }

    /// Formato A — linha-raiz `gemini`: a ÚNICA com tokens (spec §3.3;
    /// `thoughts`/`toolCalls`/`content` presentes mas irrelevantes p/ contagem).
    static func geminiRootLine(
        id: String,
        ts: Date = now,
        input: Int64 = 100,
        output: Int64 = 54,
        cached: Int64 = 0,
        thoughts: Int64 = 39,
        tool: Int64 = 0,
        total: Int64? = nil,
        model: String = "gemini-2.5-flash"
    ) -> String {
        let checksum = total ?? (input + output + thoughts + tool)
        return """
        {"type":"gemini","id":"\(id)","timestamp":"\(iso(ts))",\
        "content":"resposta fake do modelo","model":"\(model)",\
        "thoughts":[{"text":"raciocínio fake"}],"toolCalls":[{"name":"fake-tool"}],\
        "tokens":{"input":\(input),"output":\(output),"cached":\(cached),\
        "thoughts":\(thoughts),"tool":\(tool),"total":\(checksum)}}
        """
    }
}

// MARK: - GeminiLineParser (mapeamento F2-GEMINI-FIELDS + tolerância)

struct GeminiLineParserTests {
    let parser = GeminiLineParser(account: GeminiFixtures.geminiAccount)

    @Test func parsesGeminiRootLineWithRealTokens() throws {
        let line = GeminiFixtures.geminiRootLine(id: "fake-uuid-1", ts: GeminiFixtures.now)
        let event = try #require(parser.parse(line: line, fileModificationDate: GeminiFixtures.now))

        #expect(event.provider == .gemini)
        #expect(event.account == GeminiFixtures.geminiAccount)
        #expect(event.ts == GeminiFixtures.now)
        #expect(event.model == "gemini-2.5-flash")
        #expect(event.dedupeID == "fake-uuid-1")
        // F2-GEMINI-FIELDS: output engloba thoughts+tool; cached → cacheRead;
        // cacheWrite = 0; total é só checksum.
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 54 + 39 + 0)
        #expect(event.cacheReadTokens == 0)
        #expect(event.cacheWriteTokens == 0)
    }

    @Test func cachedMapsToCacheReadAndToolSumsIntoOutput() throws {
        let line = GeminiFixtures.geminiRootLine(
            id: "fake-uuid-2", input: 10, output: 20, cached: 5, thoughts: 7, tool: 3
        )
        let event = try #require(parser.parse(line: line, fileModificationDate: GeminiFixtures.now))
        #expect(event.inputTokens == 10)
        #expect(event.outputTokens == 20 + 7 + 3)
        #expect(event.cacheReadTokens == 5)
        #expect(event.cacheWriteTokens == 0)
    }

    /// spec §3.4: `total` divergente → aceita os componentes e segue
    /// (checksum é verificação, nunca fonte).
    @Test func mismatchedTotalChecksumStillParsesComponents() throws {
        let line = GeminiFixtures.geminiRootLine(id: "fake-uuid-3", total: 999_999)
        let event = try #require(parser.parse(line: line, fileModificationDate: GeminiFixtures.now))
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 54 + 39 + 0)
    }

    /// O arquivo mistura os dois formatos — só a raiz `gemini` vira evento.
    @Test func skipsUserAndInfoRootLinesMetaAndSetDeltas() {
        let mtime = GeminiFixtures.now
        #expect(parser.parse(line: GeminiFixtures.metaLine(), fileModificationDate: mtime) == nil)
        #expect(parser.parse(line: GeminiFixtures.setDeltaLine(), fileModificationDate: mtime) == nil)
        #expect(parser.parse(line: GeminiFixtures.userRootLine(), fileModificationDate: mtime) == nil)
        #expect(parser.parse(line: GeminiFixtures.infoRootLine(), fileModificationDate: mtime) == nil)
        #expect(parser.parse(line: "linha lixo não-json", fileModificationDate: mtime) == nil)
        // raiz com type desconhecido
        #expect(parser.parse(line: #"{"type":"tool","id":"fake-x","timestamp":"\#(GeminiFixtures.iso(mtime))","tokens":{"input":1,"output":1}}"#, fileModificationDate: mtime) == nil)
    }

    @Test func geminiLineWithoutTokensYieldsNoEvent() {
        let line = #"{"type":"gemini","id":"fake-x","timestamp":"\#(GeminiFixtures.iso(GeminiFixtures.now))","content":"sem tokens","model":"gemini-2.5-flash"}"#
        #expect(parser.parse(line: line, fileModificationDate: GeminiFixtures.now) == nil)
    }

    @Test func zeroTotalYieldsNoEvent() {
        let line = GeminiFixtures.geminiRootLine(id: "fake-zero", input: 0, output: 0, cached: 0, thoughts: 0, tool: 0, total: 0)
        #expect(parser.parse(line: line, fileModificationDate: GeminiFixtures.now) == nil)
    }

    @Test func invalidTimestampYieldsNoEvent() {
        let line = GeminiFixtures.geminiRootLine(id: "fake-badts")
            .replacingOccurrences(of: GeminiFixtures.iso(GeminiFixtures.now), with: "not-a-date")
        #expect(parser.parse(line: line, fileModificationDate: GeminiFixtures.now) == nil)
    }

    /// Padrão Claude/Codex: timestamp ausente → mtime do arquivo.
    @Test func missingTimestampFallsBackToMtime() throws {
        let line = #"{"type":"gemini","id":"fake-nots","content":"x","model":"gemini-2.5-flash","tokens":{"input":1,"output":2,"cached":0,"thoughts":0,"tool":0,"total":3}}"#
        let event = try #require(parser.parse(line: line, fileModificationDate: GeminiFixtures.now))
        #expect(event.ts == GeminiFixtures.now)
    }
}

// MARK: - GeminiProvider (ingest local + dedupe por id + rollover)

@Suite
final class GeminiProviderTests {
    let dir: URL

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geminiprov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Sessão sintética em `tmp/<projeto>/chats/session-*.jsonl` (layout real
    /// do CLI; o projeto é o dir `fake-proj`). Devolve o byte length.
    @discardableResult
    func writeSession(_ lines: [String], project: String = "fake-proj", name: String = "session-fake-1.jsonl") throws -> Int {
        let chats = dir.appendingPathComponent("tmp/\(project)/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: chats.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return content.utf8.count
    }

    /// Anexa linhas ao arquivo existente (simula apêndice do CLI). O handle
    /// abre no byte 0 — sem `seekToEnd` sobrescreveria o começo do arquivo.
    func append(_ lines: [String], project: String = "fake-proj", name: String = "session-fake-1.jsonl") throws {
        let url = dir.appendingPathComponent("tmp/\(project)/chats").appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    func makeProvider(offsetStore: FileOffsetStoring = InMemoryOffsetStore(), calendar: Calendar? = nil) -> GeminiProvider {
        GeminiProvider(geminiDirectory: dir, offsetStore: offsetStore, calendar: calendar ?? self.calendar)
    }

    func makeUTCCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Sessão completa: meta + raiz user + $set + 2 raízes gemini. Esperado:
    /// 2 eventos (100+93) + (10+30) — user/$set/meta sem tokens não contam.
    @discardableResult
    func writeMixedSession(ts: Date = GeminiFixtures.now) throws -> Int {
        try writeSession([
            GeminiFixtures.metaLine(ts: ts),
            GeminiFixtures.userRootLine(ts: ts),
            GeminiFixtures.setDeltaLine(ts: ts),
            GeminiFixtures.geminiRootLine(id: "fake-uuid-1", ts: ts),
            GeminiFixtures.geminiRootLine(id: "fake-uuid-2", ts: ts, input: 10, output: 20, cached: 5, thoughts: 7, tool: 3),
        ])
    }

    // MARK: identidade no protocolo

    @Test func conformsToUsageProviderBasics() async {
        let provider: any UsageProvider = makeProvider()
        #expect(provider.id == .gemini)
        #expect(provider.capabilities == [.localIngest], "F2 é modo local puro — sem API de quota (spec §3.6)")
        #expect(GeminiProvider.localDailyWindowLabel == "Hoje", "mesmo padrão pt-BR do ClaudeProvider")
    }

    @Test func resolveGeminiDirectoryOverrideAndDefault() {
        #expect(
            GeminiProvider.resolveGeminiDirectory(environment: ["TOKENBAR_GEMINI_DIR": "/tmp/fake-gemini"], home: URL(filePath: "/Users/fake")).path
                == "/tmp/fake-gemini"
        )
        #expect(
            GeminiProvider.resolveGeminiDirectory(environment: [:], home: URL(filePath: "/Users/fake")).path
                == "/Users/fake/.gemini"
        )
        #expect(
            GeminiProvider.resolveGeminiDirectory(environment: ["TOKENBAR_GEMINI_DIR": ""], home: URL(filePath: "/Users/fake")).path
                == "/Users/fake/.gemini"
        )
    }

    @Test func discoverAccountsRequiresDotGeminiDirectory() async throws {
        #expect(await makeProvider().discoverAccounts() == [GeminiFixtures.localRef])
        let missing = GeminiProvider(
            geminiDirectory: URL(filePath: "/nonexistent-\(UUID().uuidString)"),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar
        )
        #expect(await missing.discoverAccounts() == [])
    }

    // MARK: fetchUsage (modo local)

    @Test func fetchUsageReturnsLocalOnlySnapshot() async throws {
        let provider = makeProvider()
        let snapshot = try await provider.fetchUsage(GeminiFixtures.localRef)

        #expect(snapshot.provider == .gemini)
        #expect(snapshot.account == GeminiFixtures.localRef.id)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .ok, "modo local não depende de credencial (oauth nem é lido)")
        #expect(snapshot.credits == nil)
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.windows.first)
        #expect(window.kind == .daily)
        #expect(window.usedFraction == nil, "sem API de quota: fração desconhecida (spec §3.4)")
        #expect(window.label == "Hoje")
        #expect(window.resetsAt != nil && window.resetsAt! > snapshot.fetchedAt)
    }

    @Test func fetchUsageRejectsUnknownAccount() async {
        let provider = makeProvider()
        let stranger = AccountRef(id: AccountID(provider: .gemini, key: "outra"), label: "?")
        await #expect(throws: GeminiProviderError.self) {
            try await provider.fetchUsage(stranger)
        }
    }

    // MARK: ingest local (F2-GEMINI-FIELDS + dedupe)

    @Test func ingestCountsOnlyGeminiRootLinesWithRealTokens() async throws {
        let byteLength = try writeMixedSession()
        let store = InMemoryOffsetStore()
        let provider = makeProvider(offsetStore: store)

        let batch = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: GeminiFixtures.now)

        #expect(batch.eventsApplied == 2)
        let expected: Int64 = (100 + 54 + 39 + 0) + (10 + 20 + 7 + 3 + 5)
        #expect(batch.providerTotals[.gemini] == expected)

        let path = try #require(batch.nextCursor.fileOffsets.keys.first)
        #expect(path.hasSuffix("session-fake-1.jsonl"))
        #expect(batch.nextCursor.fileOffsets[path]?.offset == UInt64(byteLength))
        #expect(batch.nextCursor.fileOffsets[path]?.seenIDs == Set(["fake-uuid-1", "fake-uuid-2"]))
        #expect(batch.nextCursor.fileOffsets == store.cursors(), "store persiste os ids junto do offset")

        // project = dir <projeto> (avô do arquivo), não "chats" (spec §3.5)
        let ingester = GeminiSessionIngester(account: GeminiFixtures.geminiAccount)
        let stamped = ingester.stamp(UsageEvent(
            ts: GeminiFixtures.now, provider: .gemini, account: GeminiFixtures.geminiAccount, model: nil,
            inputTokens: 1, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
        ), path: path)
        #expect(stamped.project == "fake-proj")
    }

    /// Duplicata real observada (spec §3.3/§3.7): o CLI reanexa a mensagem —
    /// a MESMA linha-raiz (mesmo id) 2× no arquivo → 1 evento.
    @Test func deduplicatesSameIdWithinSameFile() async throws {
        try writeSession([
            GeminiFixtures.metaLine(),
            GeminiFixtures.geminiRootLine(id: "fake-uuid-1"),
            GeminiFixtures.geminiRootLine(id: "fake-uuid-1"),  // reanexo idêntico
        ])
        let provider = makeProvider()

        let batch = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: GeminiFixtures.now)

        #expect(batch.eventsApplied == 1, "mesmo id 2× no arquivo conta 1×")
        // Constante tipada: o #expect captura soma inline como Int e a
        // comparação com Int64? falha mesmo com valores iguais (quirk do macro).
        let expected: Int64 = 193
        #expect(batch.providerTotals[.gemini] == expected)
    }

    /// O caso central do cursor estendido: a duplicata entra como bytes NOVOS
    /// num ciclo seguinte (offset avança) — o dedupe por id persistido no
    /// cursor é o que impede a re-contagem.
    @Test func deduplicatesReattachedIdAcrossCycles() async throws {
        try writeSession([GeminiFixtures.metaLine(), GeminiFixtures.geminiRootLine(id: "fake-uuid-1")])
        let provider = makeProvider()

        let first = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: GeminiFixtures.now)
        #expect(first.eventsApplied == 1)
        let expected: Int64 = 100 + 54 + 39 + 0
        #expect(first.providerTotals[.gemini] == expected)

        // CLI retomou e reanexou a mensagem já ingerida.
        try append([GeminiFixtures.geminiRootLine(id: "fake-uuid-1")])
        let second = try await provider.ingestLocal(GeminiFixtures.localRef, from: first.nextCursor, now: GeminiFixtures.now)
        #expect(second.eventsApplied == 0, "duplicata em bytes novos NÃO conta de novo")
        #expect(second.providerTotals[.gemini] == expected, "total mantido")

        // Mensagem nova depois do reanexo: conta normal.
        try append([GeminiFixtures.geminiRootLine(id: "fake-uuid-3", input: 5, output: 1, cached: 0, thoughts: 0, tool: 0)])
        let third = try await provider.ingestLocal(GeminiFixtures.localRef, from: second.nextCursor, now: GeminiFixtures.now)
        #expect(third.eventsApplied == 1)
        #expect(third.providerTotals[.gemini] == expected + 6)
    }

    /// Apêndice incremental puro: só o novo entra, cursor avança exato.
    @Test func incrementalAppendCountsOnlyNewRootLine() async throws {
        let base = try writeSession([GeminiFixtures.metaLine(), GeminiFixtures.geminiRootLine(id: "fake-uuid-1")])
        let provider = makeProvider()

        let first = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: GeminiFixtures.now)
        #expect(first.eventsApplied == 1)

        let appended = GeminiFixtures.geminiRootLine(id: "fake-uuid-2", input: 7, output: 3, cached: 0, thoughts: 0, tool: 0)
        try append([appended])
        let second = try await provider.ingestLocal(GeminiFixtures.localRef, from: first.nextCursor, now: GeminiFixtures.now)
        #expect(second.eventsApplied == 1)
        let expectedTotal: Int64 = 193 + 10
        #expect(second.providerTotals[.gemini] == expectedTotal)
        let path = try #require(second.nextCursor.fileOffsets.keys.first)
        #expect(second.nextCursor.fileOffsets[path]?.offset == UInt64(base) + UInt64(appended.utf8.count + 1))
        #expect(second.nextCursor.fileOffsets[path]?.seenIDs == Set(["fake-uuid-1", "fake-uuid-2"]))
    }

    /// O caso da F1 pinado (regressão 43c6e0d): rollover re-ingere o arquivo
    /// inteiro (contrato), totais do novo dia zerados para eventos do dia-1 —
    /// e o re-scan re-aprende os ids: duplicata intra-arquivo NÃO dobraria o
    /// ledger recém-zerado se os eventos fossem do novo dia.
    @Test func rolloverRescansFullFileOnDayChangeWithoutDoubleCounting() async throws {
        let c = makeUTCCalendar()
        let startDay1 = c.startOfDay(for: GeminiFixtures.now)
        let eventDate = c.date(byAdding: .hour, value: 10, to: startDay1)!
        let now1 = c.date(byAdding: .hour, value: 11, to: startDay1)!
        let now2 = c.date(byAdding: .day, value: 1, to: now1)!
        let byteLength = try writeMixedSession(ts: eventDate)

        let store = InMemoryOffsetStore()
        let provider = makeProvider(offsetStore: store, calendar: c)

        let day1 = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: now1)
        #expect(day1.eventsApplied == 2)
        let expectedDay1: Int64 = 193 + 45
        #expect(day1.providerTotals[.gemini] == expectedDay1)

        let day2 = try await provider.ingestLocal(GeminiFixtures.localRef, from: day1.nextCursor, now: now2)
        #expect(day2.eventsApplied == 2, "rollover re-entrega (contrato F1)")
        #expect(day2.providerTotals.isEmpty, "eventos são do dia-1: total do dia-2 zerado")
        let path = try #require(day2.nextCursor.fileOffsets.keys.first)
        #expect(day2.nextCursor.fileOffsets[path]?.offset == UInt64(byteLength))
        #expect(day2.nextCursor.fileOffsets == store.cursors())
        #expect(store.cursors()[path]?.seenIDs == Set(["fake-uuid-1", "fake-uuid-2"]), "ids re-aprendidos no re-scan")
    }

    /// Reanexo de id do dia ANTERIOR atravessando o rollover: o set
    /// re-aprendido na mesma passada de re-scan derruba a 2ª cópia, então o
    /// ledger recém-zerado não dobraria se os eventos fossem do novo dia.
    @Test func rolloverDropsInFileDuplicateDuringRescan() async throws {
        let c = makeUTCCalendar()
        let startDay1 = c.startOfDay(for: GeminiFixtures.now)
        let eventDate = c.date(byAdding: .hour, value: 10, to: startDay1)!
        let now1 = c.date(byAdding: .hour, value: 11, to: startDay1)!
        let now2 = c.date(byAdding: .day, value: 1, to: now1)!

        try writeSession([GeminiFixtures.metaLine(), GeminiFixtures.geminiRootLine(id: "fake-uuid-1", ts: eventDate)])
        let provider = makeProvider(calendar: c)
        let day1 = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: now1)
        #expect(day1.eventsApplied == 1)

        // CLI retomou ainda no dia-1: reanexa a mesma mensagem (bytes novos).
        try append([GeminiFixtures.geminiRootLine(id: "fake-uuid-1", ts: eventDate)])
        let afterDup = try await provider.ingestLocal(GeminiFixtures.localRef, from: day1.nextCursor, now: now1)
        #expect(afterDup.eventsApplied == 0, "reanexo no mesmo dia não conta (dedupe do cursor)")

        // Rollover: o re-scan lê as DUAS cópias; o set re-aprendido durante a
        // própria passada dedupica a 2ª.
        let day2 = try await provider.ingestLocal(GeminiFixtures.localRef, from: afterDup.nextCursor, now: now2)
        #expect(day2.eventsApplied == 1, "re-scan re-aprende os ids e dedupica na mesma passada")
        #expect(day2.providerTotals.isEmpty, "eventos são do dia-1")
    }

    @Test func missingSessionsDirectoryYieldsZero() async throws {
        let provider = GeminiProvider(
            geminiDirectory: dir,  // existe, mas `tmp/` não
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar
        )
        let batch = try await provider.ingestLocal(GeminiFixtures.localRef, from: IngestCursor(), now: GeminiFixtures.now)
        #expect(batch.eventsApplied == 0)
        #expect(batch.providerTotals.isEmpty)
    }

    @Test func ingestLocalRejectsUnknownAccount() async throws {
        try writeMixedSession()
        let provider = makeProvider()
        let stranger = AccountRef(id: AccountID(provider: .gemini, key: "outra"), label: "?")
        await #expect(throws: GeminiProviderError.self) {
            try await provider.ingestLocal(stranger, from: IngestCursor(), now: GeminiFixtures.now)
        }
    }
}
