import Foundation
import Testing
@testable import TokenBarCore

@Suite
final class TranscriptIngesterTests: Sendable {
    private let fixedDate = Date(timeIntervalSince1970: 1_788_000_000)
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Parser de teste: linha "T<tokens>" vira evento de output=<tokens>; qualquer outra coisa → nil.
    private func countingParser(_ line: String, _ mod: Date) -> UsageEvent? {
        guard line.hasPrefix("T"), let n = Int64(line.dropFirst()) else { return nil }
        return UsageEvent(
            ts: mod, provider: .claude,
            account: AccountID(provider: .claude, key: "local"), model: nil,
            inputTokens: 0, outputTokens: n, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
        )
    }

    private func identityTag(_ e: UsageEvent, _ path: String) -> UsageEvent { e }

    private func path(_ name: String) -> String { dir.resolvingSymlinksInPath().appendingPathComponent(name).path }

    @Test
    func testFirstIngestReadsWholeFile() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results.count == 1)
        #expect(results[0].newEvents.map(\.outputTokens) == [10, 20, 30])
        #expect(Int(results[0].cursor.offset) == 12, "3 linhas de 4 bytes, tudo consumido")
        #expect(!results[0].resetToZero)
    }

    @Test
    func testSecondIngestReadsOnlyAppend() throws {
        try "T10\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let sizeAfterFirst = try FileManager.default
            .attributesOfItem(atPath: path("a.jsonl"))[.size] as! Int64

        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("a.jsonl"))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("T70\n".utf8))
        try handle.close()

        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(second.count == 1)
        #expect(second[0].newEvents.map(\.outputTokens) == [70])
        #expect(Int(second[0].cursor.offset) == Int(sizeAfterFirst) + 4)
    }

    @Test
    func testIncompleteTrailingLineIsNotConsumed() throws {
        try "T10\nT2".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results[0].newEvents.map(\.outputTokens) == [10], "'T2' sem \\n não vira evento")
        #expect(Int(results[0].cursor.offset) == 4, "cursor para depois do 1º \\n")
    }

    @Test
    func testTruncatedFileResetsToZero() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(first[0].cursor.offset > 0)

        try "T99\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(second[0].resetToZero)
        #expect(second[0].newEvents.map(\.outputTokens) == [99])
    }

    @Test
    func testGarbageLinesAreSkippedButConsumed() throws {
        try "X\nT10\nBROKEN\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results[0].newEvents.map(\.outputTokens) == [10, 20])
    }

    @Test
    func testUnchangedFileIsNotReturned() throws {
        try "T10\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(second.isEmpty)
    }

    @Test
    func testSubdirectoriesAreScanned() throws {
        let sub = dir.appendingPathComponent("proj-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "T10\n".write(to: sub.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results.count == 1)
    }

    /// Orçamento spec §7: ingest de 10k eventos < 1 s.
    @Test
    func testTenThousandEventsUnderOneSecond() throws {
        var big = ""
        big.reserveCapacity(60_000)
        for i in 0..<10_000 { big += "T\(i % 1000)\n" }
        try big.write(to: dir.appendingPathComponent("big.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let start = Date()
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let elapsed = Date().timeIntervalSince(start)
        #expect(results[0].newEvents.count == 10_000)
        #expect(elapsed < 1.0, "ingest de 10k levou \(elapsed)s")
    }
}
