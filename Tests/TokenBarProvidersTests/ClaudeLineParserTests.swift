import Foundation
import Testing
@testable import TokenBarCore
@testable import TokenBarProviders

struct ClaudeLineParserTests {
    let account = AccountID(provider: .claude, key: "local")
    let modDate = Date(timeIntervalSince1970: 1_788_000_000)

    func parser() -> ClaudeLineParser {
        ClaudeLineParser(account: account, project: "fixture-proj")
    }

    @Test func assistantLineWithUsageProducesEvent() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:00.500Z","cwd":"/tmp/proj","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}"#
        let event = try #require(parser().parse(line: line, fileModificationDate: modDate))
        #expect(event.provider == .claude)
        #expect(event.account == account)
        #expect(event.model == "claude-sonnet-4-6")
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 200)
        #expect(event.cacheReadTokens == 300)
        #expect(event.cacheWriteTokens == 40)
        #expect(event.project == "fixture-proj")
        // "2026-09-02T12:00:00.500Z" == 1_788_350_400.5 epoch (tolerância < 1s)
        #expect(abs(event.ts.timeIntervalSince1970 - 1_788_350_400) < 1)
    }

    @Test func userLineIsSkipped() {
        let line = #"{"type":"user","timestamp":"2026-09-02T12:00:01.000Z","message":{"content":"oi"}}"#
        #expect(parser().parse(line: line, fileModificationDate: modDate) == nil)
    }

    @Test func assistantWithoutUsageIsSkipped() {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:02.000Z","message":{"model":"claude-sonnet-4-6"}}"#
        #expect(parser().parse(line: line, fileModificationDate: modDate) == nil)
    }

    @Test func truncatedJSONIsSkippedNotFatal() {
        #expect(parser().parse(line: #"{"type":"assistant","timestamp":"2026-09-02T1"#, fileModificationDate: modDate) == nil)
    }

    @Test func binaryGarbageIsSkippedNotFatal() {
        #expect(parser().parse(line: "\u{00}\u{01}\u{02}garbage", fileModificationDate: modDate) == nil)
    }

    @Test func invalidTimestampIsSkipped() {
        let line = #"{"type":"assistant","timestamp":"nao-e-uma-data","message":{"usage":{"input_tokens":5,"output_tokens":5}}}"#
        #expect(parser().parse(line: line, fileModificationDate: modDate) == nil)
    }

    @Test func negativeTokensAreClampedToZero() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:03.000Z","message":{"usage":{"input_tokens":-10,"output_tokens":5}}}"#
        let event = try #require(parser().parse(line: line, fileModificationDate: modDate))
        #expect(event.inputTokens == 0)
        #expect(event.outputTokens == 5)
    }

    @Test func allZeroUsageIsSkipped() {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:04.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0}}}"#
        #expect(parser().parse(line: line, fileModificationDate: modDate) == nil)
    }

    @Test func hugeLineDoesNotCrash() {
        let huge = String(repeating: "a", count: 5_000_000)
        #expect(parser().parse(line: huge, fileModificationDate: modDate) == nil)
    }
}
