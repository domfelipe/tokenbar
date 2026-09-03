import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

final class InMemoryOffsetStore: FileOffsetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: FileCursor] = [:]

    func cursors() -> [String: FileCursor] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ cursor: FileCursor?, for path: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let cursor { storage[path] = cursor } else { storage.removeValue(forKey: path) }
    }
}

@Suite
final class ClaudeProviderTests {
    let dir: URL
    let now = Date(timeIntervalSince1970: 1_788_000_000)  // fixo: determinístico

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeprov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func resolvePrefersEnvironmentOverride() {
        let locator = ClaudeTranscriptLocator.resolve(
            environment: ["TOKENBAR_CLAUDE_DIR": "/tmp/corpus"],
            home: URL(filePath: "/Users/fake")
        )
        #expect(locator.projectsDirectory.path == "/tmp/corpus")
    }

    @Test func resolveFallsBackToHomeClaude() {
        let locator = ClaudeTranscriptLocator.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
        #expect(locator.projectsDirectory.path == "/Users/fake/.claude/projects")
    }

    func writeFixture() throws {
        let session = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let line1 = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 1))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200}}}"#
        let line2 = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 0))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":3000}}}"#
        try (line1 + "\n" + line2 + "\n")
            .write(to: session.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    }

    static func isoAt(hoursAgo: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: 1_788_000_000 - Double(hoursAgo) * 3_600))
    }

    @Test func ingestOnceCountsTokensFromRealFormatFixture() async throws {
        try writeFixture()
        let provider = ClaudeProvider(projectsDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        let outcome = try await provider.ingestOnce(now: now)
        #expect(outcome.eventsApplied == 2)
        // Int64 explícito: #expect do Swift Testing fixa soma de literais como Int,
        // e Optional<Int64> == Int avalia false dentro da captura do macro.
        let expectedTotal: Int64 = 100 + 200 + 10 + 20 + 3000
        #expect(outcome.providerTotals[.claude] == expectedTotal)
    }

    @Test func ingestTwiceDoesNotDuplicate() async throws {
        let line = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 0))","message":{"usage":{"input_tokens":50,"output_tokens":50}}}"#
        try (line + "\n").write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let provider = ClaudeProvider(projectsDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        let first = try await provider.ingestOnce(now: now)
        let second = try await provider.ingestOnce(now: now)

        #expect(first.providerTotals[.claude] == 100)
        #expect(second.eventsApplied == 0)
        #expect(second.providerTotals[.claude] == 100)  // segunda passada mantém total
    }

    @Test func missingDirectoryYieldsZero() async throws {
        let provider = ClaudeProvider(
            projectsDirectory: URL(filePath: "/nonexistent-\(UUID().uuidString)"),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar
        )
        let outcome = try await provider.ingestOnce(now: now)
        #expect(outcome.eventsApplied == 0)
        #expect(outcome.providerTotals[.claude] ?? 0 == 0)
    }

    // MARK: - Snapshot do ledger (Red Team F2 caso 7 — restart mid-day)

    /// Store persistente de cursores compartilhado entre "processos" — é o
    /// `JSONFileOffsetStore` real que sobrevive ao restart no app.
    final class SharedCursorStore: FileOffsetStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: FileCursor] = [:]
        func cursors() -> [String: FileCursor] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func set(_ cursor: FileCursor?, for path: String) throws {
            lock.lock(); defer { lock.unlock() }
            if let cursor { storage[path] = cursor } else { storage.removeValue(forKey: path) }
        }
    }

    @Test func restartMidDayRestoresTodayTotals() async throws {
        try writeFixture()  // 3330 (100+200+10+20+3000)
        let cursors = SharedCursorStore()
        let ledgerURL = dir.appendingPathComponent("claude-ledger.json")
        let first = ClaudeProvider(
            projectsDirectory: dir, offsetStore: cursors, calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        let outcome = try await first.ingestOnce(now: now)
        #expect(outcome.providerTotals[.claude] == 3330)
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))

        // "Restart": provider NOVO (ledger volátil), mesmos cursores e snapshot.
        // Sem evento novo — é exatamente o buraco do meio-dia: antes do fix o
        // total voltava 0 até o rollover de meia-noite.
        let restarted = ClaudeProvider(
            projectsDirectory: dir, offsetStore: cursors, calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        let after = try await restarted.ingestOnce(now: now)
        #expect(after.providerTotals[.claude] == 3330)

        // E o ciclo com evento NOVO soma em cima sem duplicar.
        let line = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 0))","message":{"usage":{"input_tokens":7,"output_tokens":8}}}"#
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("proj/s1.jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        let grown = try await restarted.ingestOnce(now: now)
        let expectedGrown: Int64 = 3330 + 15  // Int64 tipado: quirk do macro c/ expressão
        #expect(grown.providerTotals[.claude] == expectedGrown)
    }

    @Test func truncationAfterRestoreSelfCorrectsPerFile() async throws {
        // Dois arquivos em projetos distintos: 100 e 200.
        let projA = dir.appendingPathComponent("projA", isDirectory: true)
        let projB = dir.appendingPathComponent("projB", isDirectory: true)
        try FileManager.default.createDirectory(at: projA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
        let lineA = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 1))","message":{"usage":{"input_tokens":100,"output_tokens":0}}}"#
        let lineB = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 1))","message":{"usage":{"input_tokens":200,"output_tokens":0}}}"#
        try (lineA + "\n").write(to: projA.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try (lineB + "\n").write(to: projB.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

        let cursors = SharedCursorStore()
        let ledgerURL = dir.appendingPathComponent("claude-ledger.json")
        let first = ClaudeProvider(
            projectsDirectory: dir, offsetStore: cursors, calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        #expect(try await first.ingestOnce(now: now).providerTotals[.claude] == 300)

        let restarted = ClaudeProvider(
            projectsDirectory: dir, offsetStore: cursors, calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        #expect(try await restarted.ingestOnce(now: now).providerTotals[.claude] == 300)

        // Truncamento do a.jsonl pós-restart: cai SÓ a contribuição restaurada
        // dele (por arquivo); b.jsonl restaurado permanece — auto-correção F1.
        try Data().write(to: projA.appendingPathComponent("a.jsonl"))
        let corrected = try await restarted.ingestOnce(now: now)
        #expect(corrected.providerTotals[.claude] == 200)
    }

    /// Red Team F2 caso 5: cursores PERDIDOS (arquivo corrompido → estado
    /// vazio) invalidam o snapshot — restaurar sobre um re-ingest completo
    /// dobraria o dia. Stamp divergente → não restaura; o re-ingest reconstrói.
    @Test func lostCursorsInvalidateSnapshotNoDoubleCount() async throws {
        try writeFixture()  // 3330
        let cursors = SharedCursorStore()
        let ledgerURL = dir.appendingPathComponent("claude-ledger.json")
        let first = ClaudeProvider(
            projectsDirectory: dir, offsetStore: cursors, calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        #expect(try await first.ingestOnce(now: now).providerTotals[.claude] == 3330)

        // "Corrupção": os cursores se perdem (estado vazio do store).
        for path in cursors.cursors().keys {
            try cursors.set(nil, for: path)
        }
        let restarted = ClaudeProvider(
            projectsDirectory: dir, offsetStore: cursors, calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        // Re-ingest completa reconstrói 3330 — e NÃO 6660.
        #expect(try await restarted.ingestOnce(now: now).providerTotals[.claude] == 3330)
    }

    @Test func corruptLedgerSnapshotIsIgnoredNotFatal() async throws {
        try writeFixture()
        let ledgerURL = dir.appendingPathComponent("claude-ledger.json")
        try Data("{corrompido-lixo".utf8).write(to: ledgerURL)
        let provider = ClaudeProvider(
            projectsDirectory: dir, offsetStore: SharedCursorStore(), calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        let outcome = try await provider.ingestOnce(now: now)
        #expect(outcome.providerTotals[.claude] == 3330)  // scan normal, sem crash
    }
}
