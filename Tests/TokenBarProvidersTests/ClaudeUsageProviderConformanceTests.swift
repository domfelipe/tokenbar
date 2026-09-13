import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

/// Adesão do ClaudeProvider ao protocolo `UsageProvider` (F2): o comportamento
/// F1 de `ingestOnce` tem que continuar idêntico — aqui se verifica que o
/// caminho do protocolo (`ingestLocal`) produz o mesmo resultado.
@Suite
final class ClaudeUsageProviderConformanceTests {
    let dir: URL
    let now = Date(timeIntervalSince1970: 1_788_000_000)  // mesmo fixo dos testes F1

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeusageprov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    var localRef: AccountRef {
        AccountRef(id: AccountID(provider: .claude, key: "local"), label: "local")
    }

    func makeProvider(
        offsetStore: FileOffsetStoring = InMemoryOffsetStore(),
        calendar: Calendar? = nil
    ) -> ClaudeProvider {
        ClaudeProvider(projectsDirectory: dir, offsetStore: offsetStore, calendar: calendar ?? self.calendar)
    }

    /// Duas linhas no formato real do Claude Code; devolve o byte length do arquivo.
    @discardableResult
    func writeFixture() throws -> Int {
        let session = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let line1 = #"{"type":"assistant","timestamp":"\#(ClaudeProviderTests.isoAt(hoursAgo: 1))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200}}}"#
        let line2 = #"{"type":"assistant","timestamp":"\#(ClaudeProviderTests.isoAt(hoursAgo: 0))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":3000}}}"#
        let content = line1 + "\n" + line2 + "\n"
        try content.write(to: session.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        return content.utf8.count
    }

    /// Duas linhas (10+20 tokens cada) com ts explícito; devolve o byte length.
    @discardableResult
    func writeFixture(eventsAt dates: [Date]) throws -> Int {
        let session = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = dates.map { d in
            #"{"type":"assistant","timestamp":"\#(f.string(from: d))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20}}}"#
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: session.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        return content.utf8.count
    }

    /// Calendário UTC + âncora do dia-1 compartilhada pelos testes de rollover.
    func makeUTCCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - Identidade no protocolo

    @Test func conformsToUsageProviderBasics() async {
        let provider: any UsageProvider = makeProvider()
        #expect(provider.id == .claude)
        #expect(provider.capabilities == [.localIngest, .multiAccount])  // F4: contas com dir própria
        let accounts = await provider.discoverAccounts()
        #expect(accounts == [localRef])
    }

    // MARK: - ingestLocal via protocolo

    @Test func ingestLocalFromProtocolCursorCountsOnce() async throws {
        let byteLength = try writeFixture()
        let provider = makeProvider()
        let first = try await provider.ingestLocal(localRef, from: IngestCursor(), now: now)

        #expect(first.eventsApplied == 2)
        // Somado em etapas de propósito: uma soma única de literais estoura o
        // type-check do toolchain do runner do CI ("unable to type-check this
        // expression in reasonable time", run de 13/09).
        let promptTokens: Int64 = 100 + 200 + 10
        let expectedTotal = promptTokens + 20 + 3000  // 3330
        #expect(first.providerTotals[.claude] == expectedTotal)

        let path = try #require(first.nextCursor.fileOffsets.keys.first)
        #expect(path.hasSuffix("s1.jsonl"))
        #expect(first.nextCursor.fileOffsets[path]?.offset == UInt64(byteLength))

        // Segundo ciclo a partir do cursor devolvido: nada novo, total mantido.
        let second = try await provider.ingestLocal(localRef, from: first.nextCursor, now: now)
        #expect(second.eventsApplied == 0)
        #expect(second.providerTotals[.claude] == expectedTotal)
    }

    @Test func ingestLocalMatchesIngestOnce() async throws {
        try writeFixture()

        // Caminho F1: ingestOnce com store próprio.
        let storeA = InMemoryOffsetStore()
        let providerA = makeProvider(offsetStore: storeA)
        let outcome = try await providerA.ingestOnce(now: now)

        // Caminho F2: ingestLocal (protocolo) com store próprio, mesmo fixture.
        let providerB = makeProvider()
        let batch = try await providerB.ingestLocal(localRef, from: IngestCursor(), now: now)

        #expect(batch.eventsApplied == outcome.eventsApplied)
        #expect(batch.providerTotals == outcome.providerTotals)
        #expect(batch.nextCursor.fileOffsets == storeA.cursors())
    }

    @Test func ingestLocalThroughExistentialUsesWallClock() async throws {
        try writeFixture()
        let provider: any UsageProvider = makeProvider()
        let batch = try await provider.ingestLocal(localRef, from: IngestCursor())
        // eventsApplied conta eventos entregues independentemente do dia do
        // relógio real; totais do dia podem ser vazios se o fixture cair fora
        // de "hoje" do wall clock — só o cursor precisa ter avançado.
        #expect(batch.eventsApplied == 2)
        #expect(!batch.nextCursor.fileOffsets.isEmpty)
    }

    @Test func ingestLocalRejectsUnknownAccount() async throws {
        let provider = makeProvider()
        let stranger = AccountRef(id: AccountID(provider: .claude, key: "outra"), label: "?")
        await #expect(throws: ClaudeProviderError.self) {
            try await provider.ingestLocal(stranger, from: IngestCursor(), now: now)
        }
    }

    // MARK: - Rollover (virada de dia)

    /// Regressão 43c6e0d: no ciclo de rollover, o scan semeava dos cursores
    /// PRÉ-zerada do store (a zerada acontecia depois da semeadura) e não
    /// re-entregava nenhum evento. F1: cursores avaliados DEPOIS da zerada →
    /// re-ingest completa no dia seguinte.
    @Test func rolloverRescansFullFileOnDayChange() async throws {
        let c = makeUTCCalendar()
        let startDay1 = c.startOfDay(for: Date(timeIntervalSince1970: 1_788_000_000))
        let eventDate = c.date(byAdding: .hour, value: 10, to: startDay1)!
        let now1 = c.date(byAdding: .hour, value: 11, to: startDay1)!
        let now2 = c.date(byAdding: .day, value: 1, to: now1)!

        try writeFixture(eventsAt: [eventDate, c.date(byAdding: .minute, value: 30, to: eventDate)!])

        let provider = makeProvider(calendar: c)
        let day1 = try await provider.ingestOnce(now: now1)
        #expect(day1.eventsApplied == 2)
        #expect(day1.providerTotals[.claude] == 60)  // 2 × (10+20)

        let day2 = try await provider.ingestOnce(now: now2)
        #expect(day2.eventsApplied == 2)  // re-scan completo re-entrega os 2 eventos
        #expect(day2.providerTotals.isEmpty)  // eventos são do dia-1: total do dia-2 zerado
    }

    /// Coerência do nextCursor no rollover (via protocolo): o batch devolvido
    /// reflete os cursores realmente usados pelo scan — cheios, iguais ao store
    /// persistido — e não o store zerado do meio do ciclo.
    @Test func rolloverViaProtocolKeepsNextCursorCoherent() async throws {
        let c = makeUTCCalendar()
        let startDay1 = c.startOfDay(for: Date(timeIntervalSince1970: 1_788_000_000))
        let eventDate = c.date(byAdding: .hour, value: 10, to: startDay1)!
        let now1 = c.date(byAdding: .hour, value: 11, to: startDay1)!
        let now2 = c.date(byAdding: .day, value: 1, to: now1)!

        let byteLength = try writeFixture(eventsAt: [eventDate, eventDate])
        let store = InMemoryOffsetStore()
        let provider = makeProvider(offsetStore: store, calendar: c)

        let batch1 = try await provider.ingestLocal(localRef, from: IngestCursor(), now: now1)
        #expect(batch1.eventsApplied == 2)

        let batch2 = try await provider.ingestLocal(localRef, from: batch1.nextCursor, now: now2)
        #expect(batch2.eventsApplied == 2)  // rollover re-entrega (contrato F1)
        let path = try #require(batch2.nextCursor.fileOffsets.keys.first)
        #expect(path.hasSuffix("s1.jsonl"))
        #expect(batch2.nextCursor.fileOffsets[path]?.offset == UInt64(byteLength))
        #expect(batch2.nextCursor.fileOffsets == store.cursors())
    }

    // MARK: - fetchUsage (modo local)

    @Test func fetchUsageReturnsLocalOnlySnapshot() async throws {
        let provider = makeProvider()
        let snapshot = try await provider.fetchUsage(localRef)

        #expect(snapshot.provider == .claude)
        #expect(snapshot.account == localRef.id)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.credits == nil)
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.windows.first)
        #expect(window.kind == .daily)
        #expect(window.usedFraction == nil)  // modo local: quota desconhecida
        #expect(window.resetsAt != nil && window.resetsAt! > snapshot.fetchedAt)
        #expect(snapshot.fetchedAt <= Date())
    }

    @Test func fetchUsageRejectsUnknownAccount() async {
        let provider = makeProvider()
        let stranger = AccountRef(id: AccountID(provider: .claude, key: "outra"), label: "?")
        await #expect(throws: ClaudeProviderError.self) {
            try await provider.fetchUsage(stranger)
        }
    }
}
