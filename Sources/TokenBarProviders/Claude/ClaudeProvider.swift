import Foundation
import TokenBarCore

public struct IngestOutcome: Sendable, Equatable {
    public let eventsApplied: Int
    public let providerTotals: [ProviderID: Int64]
}

/// Provider do Claude Code em modo local (F1): lê transcripts JSONL de
/// `projectsDirectory`, mantém ledger do dia e cursores por arquivo.
/// Sem rede, sem credenciais.
public final class ClaudeProvider: Sendable {
    public var account: AccountID { AccountID(provider: .claude, key: "local") }

    private let projectsDirectory: URL
    private let offsetStore: any FileOffsetStoring
    private let ledger: TokenLedger
    private let ingester: TranscriptIngester

    public init(projectsDirectory: URL, offsetStore: any FileOffsetStoring, calendar: Calendar) {
        self.projectsDirectory = projectsDirectory
        self.offsetStore = offsetStore
        self.ledger = TokenLedger(calendar: calendar)
        let account = AccountID(provider: .claude, key: "local")
        self.ingester = TranscriptIngester { line, modified in
            ClaudeLineParser(account: account, project: nil)
                .parse(line: line, fileModificationDate: modified)
        }
    }

    /// Um ciclo completo: rollover → varre → parseia → aplica no ledger → persiste cursores.
    public func ingestOnce(now: Date) async throws -> IngestOutcome {
        await ledger.rolloverIfNeeded(now: now)

        // Virada de dia: re-ingest completa (cursores zerados).
        if await ledger.needsFullRescan {
            for path in offsetStore.cursors().keys {
                try? offsetStore.set(nil, for: path)
            }
            await ledger.clearRescanFlag()
        }

        let results = try ingester.ingestChangedFiles(
            under: projectsDirectory,
            cursors: offsetStore.cursors(),
            makeEvent: { [account] event, path in
                var e = event
                e.account = account
                e.project = e.project ?? URL(filePath: path).deletingLastPathComponent().lastPathComponent
                return e
            }
        )
        let applied = results.reduce(0) { $0 + $1.newEvents.count }
        await ledger.apply(results, now: now)
        for result in results {
            try? offsetStore.set(result.cursor, for: result.path)
        }
        let totals = await ledger.todayByProvider(now: now)
        return IngestOutcome(eventsApplied: applied, providerTotals: totals)
    }
}
