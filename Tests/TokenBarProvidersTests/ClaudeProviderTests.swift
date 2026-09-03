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
}
