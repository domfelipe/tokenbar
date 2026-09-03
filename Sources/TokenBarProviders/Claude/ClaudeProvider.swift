import Foundation
import TokenBarCore

public struct IngestOutcome: Sendable, Equatable {
    public let eventsApplied: Int
    public let providerTotals: [ProviderID: Int64]
}

/// Conta solicitada não é a conta local que este provider atende (F1 só tem
/// `claude/local`; descoberta de credenciais OAuth é fase posterior).
public struct ClaudeProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Provider do Claude Code em modo local (F1): lê transcripts JSONL de
/// `projectsDirectory`, mantém ledger do dia e cursores por arquivo.
/// Sem rede, sem credenciais.
///
/// Adere a `UsageProvider` (F2): `ingestLocal` é o motor e `ingestOnce` o
/// wrapper determinístico usado pelo app e pelos testes F1. A semântica de
/// cursor/ledger é exatamente a da F1: cursores por arquivo persistidos no
/// `offsetStore` injetado, eventos aplicados no ledger por segmento e
/// descartados (memória não escala com o arquivo — Red Team F1, caso 2).
public final class ClaudeProvider: Sendable, UsageProvider {
    /// Rótulo da janela diária no modo local. Decisão única de UI: providers
    /// F2+ em modo local (Codex, Gemini) replicam esta constante em vez de
    /// cunhar label próprio — a UI trata "janela local" de forma uniforme.
    public static let localDailyWindowLabel = "Hoje"

    public var account: AccountID { AccountID(provider: .claude, key: "local") }

    public var accountRef: AccountRef { AccountRef(id: account, label: "local") }

    private let projectsDirectory: URL
    private let offsetStore: any FileOffsetStoring
    private let ledger: TokenLedger
    private let ingester: TranscriptIngester
    private let calendar: Calendar

    public init(projectsDirectory: URL, offsetStore: any FileOffsetStoring, calendar: Calendar) {
        self.projectsDirectory = projectsDirectory
        self.offsetStore = offsetStore
        self.ledger = TokenLedger(calendar: calendar)
        self.calendar = calendar
        let account = AccountID(provider: .claude, key: "local")
        self.ingester = TranscriptIngester { line, modified in
            ClaudeLineParser(account: account, project: nil)
                .parse(line: line, fileModificationDate: modified)
        }
    }

    /// Ciclo do app (F1): wrapper determinístico do `ingestLocal` — semeia o
    /// cursor com o estado atual do `offsetStore` e devolve só o outcome.
    /// O detalhamento do ciclo (rollover, streaming, ledger) está no motor.
    public func ingestOnce(now: Date) async throws -> IngestOutcome {
        let batch = try await ingestLocal(accountRef, from: IngestCursor(fileOffsets: offsetStore.cursors()), now: now)
        return IngestOutcome(eventsApplied: batch.eventsApplied, providerTotals: batch.providerTotals)
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .claude }

    /// F1 é só ingest local; `.apiUsage`/`.credits` chegam com o modo OAuth.
    public var capabilities: ProviderCapabilities { [.localIngest] }

    public func discoverAccounts() async -> [AccountRef] {
        [accountRef]
    }

    /// Snapshot no modo local (spec §5 regra 2): janela diária com fração
    /// desconhecida (`usedFraction: nil`), sem créditos, `source: .localOnly`.
    /// `authState: .ok` — o modo local não depende de credencial, e o caminho
    /// de aquisição está saudável por definição (não há verificação de OAuth
    /// nesta fase; com o modo API o provider passa a reportar `.missing`).
    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        let today = calendar.startOfDay(for: fetchedAt)
        let resetsAt = calendar.date(byAdding: .day, value: 1, to: today)
        return UsageSnapshot(
            provider: .claude,
            account: self.account,
            windows: [UsageWindow(kind: .daily, usedFraction: nil, resetsAt: resetsAt, label: Self.localDailyWindowLabel)],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: .ok
        )
    }

    /// Método do protocolo: usa o relógio real. O cursor semeado é o passado
    /// pelo chamador (contrato do protocolo); para o ciclo do app, `ingestOnce`
    /// semeia com o estado do `offsetStore`.
    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try await ingestLocal(account, from: cursor, now: Date())
    }

    /// Motor do ingest com `now` explícito (determinismo dos testes e do
    /// scheduler). Um ciclo completo: rollover → varre (streaming) → parseia →
    /// aplica no ledger por lote → persiste cursores. Eventos são aplicados por
    /// segmento de streaming e descartados — o pico de memória não escala com o
    /// tamanho do arquivo (Red Team F1, caso 2).
    ///
    /// Contrato de cursor (obrigatório p/ quem semeia, ver `UsageProvider`):
    /// passe o `nextCursor` devolvido por ESTE provider no ciclo anterior, ou
    /// o estado fresco do `offsetStore` — nunca cursor construído fora daí.
    ///
    /// Ordem da F1 preservada na virada de dia (regressão 43c6e0d): o mapa de
    /// cursores usado pelo scan é avaliado DEPOIS da zerada do store — semear
    /// dos cursores pré-zerada fazia o rollover re-ingest 0 eventos. O
    /// `nextCursor` do batch é o estado semeado + as atualizações do ciclo,
    /// coerente com o que o scan de fato consumiu.
    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor, now: Date) async throws -> IngestBatch {
        try guardKnownAccount(account)

        ledger.rolloverIfNeeded(now: now)

        // Virada de dia: re-ingest completa (cursores zerados). F1: o mapa
        // semeado no scan é lido do store DEPOIS da zerada (== vazio).
        var scanCursors = cursor.fileOffsets
        if ledger.needsFullRescan {
            for path in offsetStore.cursors().keys {
                try? offsetStore.set(nil, for: path)
            }
            ledger.clearRescanFlag()
            scanCursors = offsetStore.cursors()
        }

        var applied = 0
        var projectCache: [String: String] = [:]  // projeto por arquivo: mesmo valor p/ todas as linhas
        let updates = try ingester.ingestChangedFilesStreaming(
            under: projectsDirectory,
            cursors: scanCursors,
            makeEvent: { event, path in
                var e = event
                e.account = account.id
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
        // nextCursor por construção: semeado + atualizações do ciclo (não re-lê
        // o store, que pode conter estado de escritas externas a este ciclo).
        var nextOffsets = scanCursors
        for update in updates {
            try? offsetStore.set(update.cursor, for: update.path)
            nextOffsets[update.path] = update.cursor
        }
        return IngestBatch(
            events: [],  // streaming: eventos aplicados no ledger e descartados
            eventsApplied: applied,
            providerTotals: ledger.todayByProvider(now: now),
            nextCursor: IngestCursor(fileOffsets: nextOffsets)
        )
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw ClaudeProviderError(account: account.id)
        }
    }
}
