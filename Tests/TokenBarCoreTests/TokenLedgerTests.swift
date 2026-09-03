import Foundation
import Testing
@testable import TokenBarCore

@Suite
final class TokenLedgerTests: Sendable {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }
    private let today = Date(timeIntervalSince1970: 1_788_000_000)          // 2026-09-02 ~09:20 BRT
    private let yesterday = Date(timeIntervalSince1970: 1_788_000_000 - 86_400)

    private func event(_ output: Int64, ts: Date, path: String, provider: ProviderID = .claude) -> FileIngestResult {
        FileIngestResult(
            path: path,
            newEvents: [UsageEvent(
                ts: ts, provider: provider,
                account: AccountID(provider: provider, key: "local"), model: nil,
                inputTokens: 0, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
            )],
            cursor: FileCursor(offset: 100), resetToZero: false
        )
    }

    @Test
    func testAccumulatesAcrossFilesAndCycles() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: today, path: "/a"), event(20, ts: today, path: "/b")], now: today)
        ledger.apply([event(5, ts: today, path: "/a")], now: today)
        let byProvider = ledger.todayByProvider(now: today)
        #expect(byProvider[.claude] == 35)
    }

    @Test
    func testYesterdayEventsDoNotCountForToday() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: yesterday, path: "/a")], now: today)
        let total = ledger.todayTotal(now: today)
        #expect(total == 0)
    }

    @Test
    func testTruncationSelfCorrects() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let correction = FileIngestResult(
            path: "/a",
            newEvents: [UsageEvent(
                ts: today, provider: .claude,
                account: AccountID(provider: .claude, key: "local"), model: nil,
                inputTokens: 0, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
            )],
            cursor: FileCursor(offset: 3), resetToZero: true
        )
        ledger.apply([correction], now: today)
        let total = ledger.todayTotal(now: today)
        #expect(total == 3, "truncamento substitui, não soma")
    }

    @Test
    func testRolloverClearsTotalsAndFlagsRescan() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let tomorrow = today.addingTimeInterval(86_400)
        ledger.rolloverIfNeeded(now: tomorrow)
        let needsRescan = ledger.needsFullRescan
        #expect(needsRescan)
        let total = ledger.todayTotal(now: tomorrow)
        #expect(total == 0)
    }

    @Test
    func testMultiProviderBreakdown() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply(
            [event(10, ts: today, path: "/a"), event(7, ts: today, path: "/c", provider: .codex)],
            now: today
        )
        let byProvider = ledger.todayByProvider(now: today)
        #expect(byProvider[.claude] == 10)
        #expect(byProvider[.codex] == 7)
    }
}
