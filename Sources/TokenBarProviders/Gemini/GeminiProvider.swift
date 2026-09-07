import Foundation
import os
import TokenBarCore

/// Conta solicitada não é a conta local que este provider atende (F2 tem uma
/// conta por instalação: `.gemini/local`).
public struct GeminiProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Set de ids já contados por arquivo, chave do dedupe do Gemini (spec F2
/// §3.3/§3.7): o CLI REANEXA a mesma linha-raiz (mesmo `id`) ao retomar —
/// duplicata real e observada. O offset sozinho conta dobrado duas vezes:
/// (1) a reanexação entra como bytes novos no ciclo seguinte; (2) o re-scan
/// de rollover relê o arquivo do zero sobre um ledger recém-zerado.
///
/// Ciclo de vida limitado (bounded): o provider faz `reset()` no rollover de
/// dia e re-semeia do cursor pós-zerada — então o set só acumula ids do dia
/// corrente. A persistência cruzando ciclos/restart vem do cursor:
/// `FileCursor.seenIDs` via `nextCursor`/`JSONFileOffsetStore` (contrato do
/// protocolo: semeadura só de `nextCursor` próprio ou store fresco).
public final class GeminiDedupe: Sendable {
    private let seen: OSAllocatedUnfairLock<[String: Set<String>]>

    public init() {
        self.seen = OSAllocatedUnfairLock(initialState: [:])
    }

    /// Rollover (ou início de ciclo pós-re-scan): esquece tudo — o re-scan
    /// re-aprende os ids do dia ao reler.
    public func reset() {
        seen.withLock { $0 = [:] }
    }

    /// Semeia dos cursores do ciclo (nextCursor do ciclo anterior ou store).
    public func seed(from cursors: [String: FileCursor]) {
        seen.withLock { s in
            for (path, cursor) in cursors {
                guard let ids = cursor.seenIDs, !ids.isEmpty else { continue }
                s[path, default: []].formUnion(ids)
            }
        }
    }

    /// Insere e diz se é novo (`false` = duplicata: drop).
    public func insert(_ path: String, _ id: String) -> Bool {
        seen.withLock { s in
            if s[path]?.contains(id) == true { return false }
            s[path, default: []].insert(id)
            return true
        }
    }

    /// Ids correntes do arquivo — vai para o `FileCursor.seenIDs` do
    /// `nextCursor`/store ao fim do ciclo.
    public func seenIDs(for path: String) -> Set<String>? {
        seen.withLock { $0[path] }
    }
}

/// Provider do Gemini CLI, F2 — modo LOCAL puro (spec §3): sem API de quota
/// (`v1internal` fica fora do escopo e exigiria reescrever `oauth_creds.json`,
/// violando a regra read-only), então `oauth_creds.json` NÃO é lido.
///
/// - `discoverAccounts`: 1 conta (`gemini/local`) se `~/.gemini` existe
///   (override `TOKENBAR_GEMINI_DIR`), senão [].
/// - `fetchUsage`: snapshot `.localOnly` com janela diária de fração
///   desconhecida e `authState: .ok` (mesmo rationale do `ClaudeProvider` —
///   o modo local não depende de credencial).
/// - `ingestLocal`: sessões `tmp/<projeto>/chats/session-*.jsonl`, tokens
///   reais pelas linhas-raiz `type: "gemini"` (F2-GEMINI-FIELDS) com dedupe
///   por `id` (ver `GeminiDedupe`).
public final class GeminiProvider: Sendable, UsageProvider {
    /// Rótulo da janela diária no modo local — mesmo padrão pt-BR do
    /// `ClaudeProvider.localDailyWindowLabel` (decisão única de UI).
    public static let localDailyWindowLabel = "Hoje"

    public var account: AccountID { accountID }
    public var accountRef: AccountRef { AccountRef(id: account, label: "local") }

    /// Raiz do ingest: `~/.gemini/tmp` (o scan recursivo acha
    /// `<projeto>/chats/session-*.jsonl`).
    private let tmpDirectory: URL
    private let homeDotGemini: URL
    private let accountID: AccountID
    private let offsetStore: any FileOffsetStoring
    private let ledgerSnapshotStore: (any LedgerSnapshotStoring)?
    private let ledger: TokenLedger
    private let dedupe: GeminiDedupe
    private let sessionIngester: GeminiSessionIngester
    private let calendar: Calendar

    public init(
        geminiDirectory: URL,
        offsetStore: any FileOffsetStoring,
        calendar: Calendar,
        ledgerSnapshotStore: (any LedgerSnapshotStoring)? = nil
    ) {
        let account = AccountID(provider: .gemini, key: "local")
        self.accountID = account
        self.homeDotGemini = geminiDirectory
        self.tmpDirectory = geminiDirectory.appendingPathComponent("tmp", isDirectory: true)
        self.offsetStore = offsetStore
        self.ledgerSnapshotStore = ledgerSnapshotStore
        self.ledger = TokenLedger(calendar: calendar)
        self.dedupe = GeminiDedupe()
        self.calendar = calendar
        self.sessionIngester = GeminiSessionIngester(account: account)
    }

    /// Resolução de caminhos p/ wiring (testes injetam direto no init).
    public static func resolveGeminiDirectory(environment: [String: String], home: URL) -> URL {
        if let override = environment["TOKENBAR_GEMINI_DIR"], !override.isEmpty {
            return URL(filePath: override)
        }
        return home.appendingPathComponent(".gemini", isDirectory: true)
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .gemini }

    /// F2 é só ingest local — a API de quota é `v1internal` sem contrato
    /// (spec §3.6); `.apiUsage` só se um dia entrar com API estável.
    public var capabilities: ProviderCapabilities { [.localIngest] }

    /// 1 conta se `~/.gemini` existe; sem o dir (CLI não instalado) → [].
    public func discoverAccounts() async -> [AccountRef] {
        FileManager.default.fileExists(atPath: homeDotGemini.path) ? [accountRef] : []
    }

    /// Snapshot local (spec §5 regra 2 / §3.4): janela diária com fração
    /// desconhecida (`usedFraction: nil`), sem créditos, `.localOnly`,
    /// `authState: .ok` — tokens vêm do ingest, não daqui.
    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        let today = calendar.startOfDay(for: fetchedAt)
        let resetsAt = calendar.date(byAdding: .day, value: 1, to: today)
        return UsageSnapshot(
            provider: .gemini,
            account: self.account,
            windows: [UsageWindow(kind: .daily, usedFraction: nil, resetsAt: resetsAt, label: Self.localDailyWindowLabel)],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: .ok
        )
    }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try await ingestLocal(account, from: cursor, now: Date())
    }

    /// Motor com `now` explícito — espelho do `ClaudeProvider`/`CodexProvider`
    /// (mesma ordem da F1 na virada de dia, regressão 43c6e0d: o mapa de
    /// cursores do scan é avaliado DEPOIS da zerada do store). Eventos são
    /// aplicados no ledger por lote e descartados.
    ///
    /// Diferença Gemini: o drop por dedupe acontece no `onEvents` (é onde há
    /// path E lote) — ANTES do ledger, então duplicata não soma nem conta em
    /// `eventsApplied`. Os ids sobrevivem ao ciclo via `FileCursor.seenIDs`.
    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor, now: Date) async throws -> IngestBatch {
        try guardKnownAccount(account)

        ledger.rolloverIfNeeded(now: now)

        // Red Team F2 caso 7: restaura o dia do snapshot pós-restart (uma vez
        // por processo; dia divergente → no-op, o rollover re-escaneia). Os
        // ids do dedupe não são restaurados daqui — voltam dos `seenIDs` do
        // cursor (fonte canônica), então duplicata continua coberta.
        let cursors = offsetStore.cursors()
        // Stamp dos cursores: store perdido/corrompido → NÃO restaura (o
        // re-ingest completo reconstrói o dia sem dobrar) — RT F2 caso 5.
        // Filtro snapshot ⊆ cursores ∧ snapshot ⊆ raiz de scan (auditoria T8
        // do 42d42e9: o cursor do path velho sobrevive no store acumulado e o
        // stamp bate — só o escopo da raiz impede o total morto de voltar).
        if let store = ledgerSnapshotStore,
           let snapshot = store.load()?.filtered(
               toExistingIn: cursors, underScanRoot: tmpDirectory.path),
           !snapshot.files.isEmpty,
           snapshot.cursorStamp == LedgerSnapshotStamp.make(cursors) {
            ledger.restoreDay(snapshot, provider: .gemini, now: now)
        }

        var scanCursors = cursor.fileOffsets
        if ledger.needsFullRescan {
            for path in offsetStore.cursors().keys {
                try? offsetStore.set(nil, for: path)
            }
            ledger.clearRescanFlag()
            scanCursors = offsetStore.cursors()
            // Bounded: esquece os ids de ontem; o re-scan re-aprende os do
            // dia relendo os arquivos (duplicata intra-arquivo continua
            // coberta pelo set re-construído durante a própria passada).
            dedupe.reset()
        }
        dedupe.seed(from: scanCursors)

        var applied = 0
        let updates = try sessionIngester.ingestChangedFilesStreaming(
            under: tmpDirectory,
            cursors: scanCursors
        ) { path, events, reset in
            // Dedupe por id (spec §3.3: duplicata real) — drop ANTES do ledger.
            var fresh: [UsageEvent] = []
            fresh.reserveCapacity(events.count)
            for event in events {
                guard let id = event.dedupeID, !id.isEmpty else {
                    fresh.append(event)  // sem id na fonte: nada a dedupar
                    continue
                }
                if dedupe.insert(path, id) {
                    fresh.append(event)
                }
            }
            applied += fresh.count
            ledger.apply(
                [FileIngestResult(
                    path: path,
                    newEvents: fresh,
                    cursor: FileCursor(offset: 0),  // placeholder; cursor real vai em `updates`
                    resetToZero: reset
                )],
                now: now
            )
        }

        // nextCursor por construção: semeado + atualizações do ciclo, cada
        // cursor carregando os ids acumulados do próprio arquivo.
        var nextOffsets = scanCursors
        for update in updates {
            var next = update.cursor
            next.seenIDs = dedupe.seenIDs(for: update.path)
            try? offsetStore.set(next, for: update.path)
            nextOffsets[update.path] = next
        }
        // Snapshot do dia DEPOIS dos cursores (ordem anti-dupla-contagem,
        // ver `TokenLedger.daySnapshot`) — Red Team F2 caso 7.
        ledgerSnapshotStore?.saveDay(ledger.daySnapshot(now: now), stamping: offsetStore.cursors())
        return IngestBatch(
            events: [],  // streaming: eventos aplicados no ledger e descartados
            eventsApplied: applied,
            providerTotals: ledger.todayByProvider(now: now),
            nextCursor: IngestCursor(fileOffsets: nextOffsets)
        )
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw GeminiProviderError(account: account.id)
        }
    }
}
