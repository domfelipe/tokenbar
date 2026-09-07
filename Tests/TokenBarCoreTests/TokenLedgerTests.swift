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
        ledger.rolloverIfNeeded(now: today)  // 1º ciclo do processo: só registra o dia
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let tomorrow = today.addingTimeInterval(86_400)
        ledger.rolloverIfNeeded(now: tomorrow)
        let needsRescan = ledger.needsFullRescan
        #expect(needsRescan)
        let total = ledger.todayTotal(now: tomorrow)
        #expect(total == 0)
    }

    @Test
    func testFirstCycleRecordsDayWithoutSpuriousRescan() {
        // Red Team F2 caso 7: currentDay não nasce do relógio real — o 1º
        // ciclo registra o dia do `now` SEM flag de rescan (senão um launch
        // com now divergente re-escanearia tudo e dobraria com o snapshot).
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        ledger.rolloverIfNeeded(now: today)
        #expect(!ledger.needsFullRescan)
        #expect(ledger.todayTotal(now: today) == 10)
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

    // MARK: - Snapshot do dia (Red Team F2 caso 7 — restart mid-day)

    private func sums(_ input: Int64, _ output: Int64 = 0) -> TokenSums {
        TokenSums(input: input, output: output)
    }

    @Test
    func testRestoreDayRecoversSnapshotAfterRestart() throws {
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: today, path: "/a"), event(20, ts: today, path: "/b")], now: today)
        ledger.rolloverIfNeeded(now: today)  // registra o dia (fluxo do provider)
        let snapshot = try #require(ledger.daySnapshot(now: today))

        // "Restart": ledger novo (processo novo), mesmo snapshot.
        let restarted = TokenLedger(calendar: calendar)
        restarted.rolloverIfNeeded(now: today)
        restarted.restoreDay(snapshot, provider: .claude, now: today)
        #expect(restarted.todayByProvider(now: today)[.claude] == 30)
        // E o ciclo seguinte soma EM CIMA (não duplica): novo evento em /a.
        restarted.apply([event(5, ts: today, path: "/a")], now: today)
        #expect(restarted.todayByProvider(now: today)[.claude] == 35)
    }

    @Test
    func testRestoreDayOnlyOncePerProcess() throws {
        let ledger = TokenLedger(calendar: calendar)
        ledger.rolloverIfNeeded(now: today)
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let snapshot = try #require(ledger.daySnapshot(now: today))

        ledger.apply([event(50, ts: today, path: "/b")], now: today)
        // Segunda restauração com snapshot VELHO não pode regredir o estado vivo.
        ledger.restoreDay(snapshot, provider: .claude, now: today)
        #expect(ledger.todayByProvider(now: today)[.claude] == 60)
    }

    @Test
    func testRestoreDayIgnoresOtherDay() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.rolloverIfNeeded(now: today)
        let stale = LedgerSnapshot(day: yesterday, files: ["/old": sums(999)])
        ledger.restoreDay(stale, provider: .claude, now: today)
        #expect(ledger.todayByProvider(now: today).isEmpty)
        // E não sinaliza rescan: é só um snapshot sem correspondência, não rollover.
        #expect(!ledger.needsFullRescan)
    }

    @Test
    func testRestoreDayDoesNotClobberLiveEntries() {
        let ledger = TokenLedger(calendar: calendar)
        ledger.rolloverIfNeeded(now: today)
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let snapshot = LedgerSnapshot(day: calendar.startOfDay(for: today), files: ["/a": sums(777), "/b": sums(20)])
        ledger.restoreDay(snapshot, provider: .claude, now: today)
        // /a vivo vence; /b (só no snapshot) entra.
        #expect(ledger.todayByProvider(now: today)[.claude] == 30)
    }

    @Test
    func testDaySnapshotNilOnEmptyDayAndAfterRollover() {
        let ledger = TokenLedger(calendar: calendar)
        #expect(ledger.daySnapshot(now: today) == nil)
        ledger.rolloverIfNeeded(now: today)
        ledger.apply([event(10, ts: today, path: "/a")], now: today)
        #expect(ledger.daySnapshot(now: today) != nil)
        // Rollover: dia virou — snapshot do novo dia é vazio (não pega o de ontem).
        let tomorrow = today.addingTimeInterval(86_400)
        ledger.rolloverIfNeeded(now: tomorrow)
        #expect(ledger.daySnapshot(now: tomorrow) == nil)
    }

    @Test
    func testTruncationAfterRestoreSelfCorrects() throws {
        // Restauração POR ARQUIVO preserva a auto-correção F1: reset de /a
        // zera a contribuição restaurada dele e só dele.
        let ledger = TokenLedger(calendar: calendar)
        ledger.apply([event(10, ts: today, path: "/a"), event(20, ts: today, path: "/b")], now: today)
        ledger.rolloverIfNeeded(now: today)
        let snapshot = try #require(ledger.daySnapshot(now: today))

        let restarted = TokenLedger(calendar: calendar)
        restarted.rolloverIfNeeded(now: today)
        restarted.restoreDay(snapshot, provider: .claude, now: today)
        let reset = FileIngestResult(
            path: "/a", newEvents: [], cursor: FileCursor(offset: 0), resetToZero: true
        )
        restarted.apply([reset], now: today)
        #expect(restarted.todayByProvider(now: today)[.claude] == 20)
    }
}
