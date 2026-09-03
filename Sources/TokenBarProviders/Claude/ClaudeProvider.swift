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

    /// Um ciclo completo: rollover → varre (streaming) → parseia → aplica no
    /// ledger por lote → persiste cursores. Eventos são aplicados por segmento
    /// de streaming e descartados — o pico de memória não escala com o tamanho
    /// do arquivo (Red Team F1, caso 2).
    public func ingestOnce(now: Date) async throws -> IngestOutcome {
        ledger.rolloverIfNeeded(now: now)

        // Virada de dia: re-ingest completa (cursores zerados).
        if ledger.needsFullRescan {
            for path in offsetStore.cursors().keys {
                try? offsetStore.set(nil, for: path)
            }
            ledger.clearRescanFlag()
        }

        var applied = 0
        var projectCache: [String: String] = [:]  // projeto por arquivo: mesmo valor p/ todas as linhas
        let updates = try ingester.ingestChangedFilesStreaming(
            under: projectsDirectory,
            cursors: offsetStore.cursors(),
            makeEvent: { event, path in
                var e = event
                e.account = account
                let project: String
                if let cached = projectCache[path] {
                    project = cached
                } else {
                    project = URL(filePath: path).deletingLastPathComponent().lastPathComponent
                    projectCache[path] = project
                }
                e.project = e.project ?? project
                return e
            },
            onEvents: { path, events, reset in
                applied += events.count
                // Aplica imediatamente e descarta o lote — sem retenção de eventos.
                ledger.apply(
                    [FileIngestResult(
                        path: path,
                        newEvents: events,
                        cursor: FileCursor(offset: 0),  // placeholder; o cursor real vai em `updates`
                        resetToZero: reset
                    )],
                    now: now
                )
            }
        )
        for update in updates {
            try? offsetStore.set(update.cursor, for: update.path)
        }
        return IngestOutcome(eventsApplied: applied, providerTotals: ledger.todayByProvider(now: now))
    }
}
