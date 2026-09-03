import Foundation
import TokenBarCore

/// Conta solicitada não é a conta local que este provider atende (F2 tem uma
/// conta por instalação: `.codex/local`).
public struct CodexProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Decoder tolerante da resposta `wham/usage` (spec §1.3): alias snake/camel,
/// números como int/double/string, tudo opcional — chaves extras
/// (`additional_rate_limits`, `spend_control`, `individual_limit`) são
/// ignoradas sem quebrar primary/secondary. `reset_at` = epoch em SEGUNDOS.
struct CodexUsageResponse: Decodable, Sendable, Equatable {
    let accountID: String?
    let planType: String?   // identidade exibida no menu/painel (sem slot no snapshot F2)
    let primaryWindow: Window?
    let secondaryWindow: Window?
    let credits: Credits?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        accountID = FlexibleJSON.string(c, "account_id", "accountId")
        planType = FlexibleJSON.string(c, "plan_type", "planType")
        // primary/secondary vivem DENTRO de `rate_limit` (alias camel aceito).
        let rateLimit: KeyedDecodingContainer<AnyKey>?
        if let snake = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("rate_limit")) {
            rateLimit = snake
        } else {
            rateLimit = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("rateLimit"))
        }
        if let rateLimit {
            primaryWindow = Self.window(rateLimit, "primary_window", "primaryWindow")
            secondaryWindow = Self.window(rateLimit, "secondary_window", "secondaryWindow")
        } else {
            primaryWindow = nil
            secondaryWindow = nil
        }
        credits = Self.credits(c)
    }

    struct Window: Sendable, Equatable {
        let usedPercent: Double?
        let resetAt: Double?
        let limitWindowSeconds: Double?
    }

    struct Credits: Sendable, Equatable {
        let balance: Double?
        let unlimited: Bool?
    }

    /// Janela aninhada ausente ou `null` → nil (decodeIfPresent cobre o null).
    private static func window(_ c: KeyedDecodingContainer<AnyKey>, _ keys: String...) -> Window? {
        for key in keys {
            guard let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key)) else { continue }
            return Window(
                usedPercent: FlexibleJSON.double(nested, "used_percent", "usedPercent"),
                resetAt: FlexibleJSON.double(nested, "reset_at", "resetAt"),
                limitWindowSeconds: FlexibleJSON.double(nested, "limit_window_seconds", "limitWindowSeconds")
            )
        }
        return nil
    }

    private static func credits(_ c: KeyedDecodingContainer<AnyKey>) -> Credits? {
        guard let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("credits")) else { return nil }
        return Credits(
            balance: FlexibleJSON.double(nested, "balance"),
            unlimited: FlexibleJSON.bool(nested, "unlimited")
        )
    }
}

/// Provider do Codex (OpenAI/ChatGPT), F2 — usage API + ingest local (spec §1).
///
/// - `fetchUsage`: token de `~/.codex/auth.json` (read-only, em memória) →
///   `GET {base}/backend-api/wham/usage` com Bearer. 401/403 → `authState:
///   .invalid` + snapshot degradado `.localOnly`; erro de rede → rethrow (o
///   AdaptiveScheduler trata backoff; spec §5 regra 3 — nunca retry interno).
/// - `ingestLocal`: rollouts JSONL, padrão incremental da F1 (contrato de
///   cursor do protocolo: semeadura só de `nextCursor` próprio ou do store
///   fresco; rollover de dia re-escaneia).
/// - Sem credencial: `discoverAccounts() == []` e `fetchUsage` → snapshot
///   `.localOnly` com `authState: .missing`.
public final class CodexProvider: Sendable, UsageProvider {
    /// Rótulo da janela diária no modo local — mesmo padrão pt-BR do
    /// `ClaudeProvider.localDailyWindowLabel` (decisão única de UI).
    public static let localDailyWindowLabel = "Hoje"

    /// URL canônica da spec §1.1 (override por env `TOKENBAR_CODEX_API`).
    public static let defaultBaseURL = URL(string: "https://chatgpt.com")!
    public static let usagePath = "backend-api/wham/usage"

    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    public var account: AccountID { AccountID(provider: .codex, key: "local") }
    public var accountRef: AccountRef { AccountRef(id: account, label: "local") }

    private let sessionsDirectory: URL
    private let authReader: CodexAuthReader
    private let client: UsageHTTPClient
    private let offsetStore: any FileOffsetStoring
    private let ledger: TokenLedger
    private let sessionIngester: CodexSessionIngester
    private let calendar: Calendar

    public init(
        sessionsDirectory: URL,
        authReader: CodexAuthReader,
        client: UsageHTTPClient,
        offsetStore: any FileOffsetStoring,
        calendar: Calendar
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.authReader = authReader
        self.client = client
        self.offsetStore = offsetStore
        self.ledger = TokenLedger(calendar: calendar)
        self.calendar = calendar
        self.sessionIngester = CodexSessionIngester(
            account: AccountID(provider: .codex, key: "local"),
            modelTracker: CodexModelTracker()
        )
    }

    /// Resolução de caminhos p/ wiring (testes injetam direto no init).
    public static func resolveSessionsDirectory(environment: [String: String], home: URL) -> URL {
        if let override = environment["TOKENBAR_CODEX_DIR"], !override.isEmpty {
            return URL(filePath: override)
        }
        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func resolveBaseURL(environment: [String: String]) -> URL {
        if let raw = environment["TOKENBAR_CODEX_API"], !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return defaultBaseURL
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .codex }

    public var capabilities: ProviderCapabilities { [.apiUsage, .localIngest] }

    /// 1 conta de `auth.json` presente; sem credencial decodificável → [].
    public func discoverAccounts() async -> [AccountRef] {
        authReader.read() == nil ? [] : [accountRef]
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let auth = authReader.read(), auth.hasOAuth, let token = auth.accessToken else {
            return localOnlySnapshot(authState: .missing, fetchedAt: fetchedAt)
        }

        var headers = ["User-Agent": Self.userAgent]
        if let accountID = auth.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID  // opcional; multi-conta/Team
        }

        do {
            let data = try await client.getJSON(path: Self.usagePath, bearer: token, headers: headers)
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return apiSnapshot(response, auth: auth, fetchedAt: fetchedAt)
        } catch let error as UsageHTTPError where error == .unauthorized {
            // Token expirado — `codex login` resolve; nunca renovamos por ele.
            return localOnlySnapshot(authState: .invalid, fetchedAt: fetchedAt)
        }
        // Demais erros (rede, http != 401/403, decode de shape novo): rethrow —
        // backoff do scheduler; último snapshot bom permanece (nunca dado errado).
    }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try await ingestLocal(account, from: cursor, now: Date())
    }

    /// Motor com `now` explícito — espelho do `ClaudeProvider` (mesma ordem da
    /// F1 na virada de dia, regressão 43c6e0d: o mapa de cursores do scan é
    /// avaliado DEPOIS da zerada do store). Eventos são aplicados no ledger por
    /// lote e descartados (memória não escala com o arquivo).
    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor, now: Date) async throws -> IngestBatch {
        try guardKnownAccount(account)

        ledger.rolloverIfNeeded(now: now)

        var scanCursors = cursor.fileOffsets
        if ledger.needsFullRescan {
            for path in offsetStore.cursors().keys {
                try? offsetStore.set(nil, for: path)
            }
            ledger.clearRescanFlag()
            scanCursors = offsetStore.cursors()
        }

        var applied = 0
        let updates = try sessionIngester.ingestChangedFilesStreaming(
            under: sessionsDirectory,
            cursors: scanCursors
        ) { path, events, reset in
            applied += events.count
            ledger.apply(
                [FileIngestResult(
                    path: path,
                    newEvents: events,
                    cursor: FileCursor(offset: 0),  // placeholder; cursor real vai em `updates`
                    resetToZero: reset
                )],
                now: now
            )
        }

        // nextCursor por construção: semeado + atualizações do ciclo.
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

    // MARK: - Snapshots

    private func apiSnapshot(_ r: CodexUsageResponse, auth: CodexAuth, fetchedAt: Date) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        // Fallback de label/kind por posição quando `limit_window_seconds`
        // não veio (spec §1.4: primary = 5h/session, secondary = semanal).
        if let w = Self.mapWindow(r.primaryWindow, fallback: (.session, "5h")) { windows.append(w) }
        if let w = Self.mapWindow(r.secondaryWindow, fallback: (.weekly, "Semanal")) { windows.append(w) }

        return UsageSnapshot(
            provider: .codex,
            account: AccountID(provider: .codex, key: r.accountID ?? auth.accountID ?? "local"),
            windows: windows,
            credits: r.credits.map { CreditsInfo(remaining: $0.balance, unlimited: $0.unlimited ?? false) },
            fetchedAt: fetchedAt,
            source: .api,
            authState: .ok
        )
    }

    /// Snapshot degradado (spec §5 regra 2 / §1.6): janela diária com fração
    /// desconhecida, sem créditos, `.localOnly`.
    private func localOnlySnapshot(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        let today = calendar.startOfDay(for: fetchedAt)
        let resetsAt = calendar.date(byAdding: .day, value: 1, to: today)
        return UsageSnapshot(
            provider: .codex,
            account: account,
            windows: [UsageWindow(kind: .daily, usedFraction: nil, resetsAt: resetsAt, label: Self.localDailyWindowLabel)],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState
        )
    }

    /// `used_percent`/100 satura em 0...1; `reset_at` epoch em SEGUNDOS;
    /// kind/label dinâmicos via `limit_window_seconds` (18000 = 5h,
    /// 604800 = 7d) — spec §1.4.
    static func mapWindow(_ w: CodexUsageResponse.Window?, fallback: (WindowKind, String)) -> UsageWindow? {
        guard let w else { return nil }
        let fraction = w.usedPercent.map { min(max($0 / 100, 0), 1) }
        let resetsAt = w.resetAt.map { Date(timeIntervalSince1970: $0) }
        let (kind, label) = w.limitWindowSeconds.map { kindAndLabel(seconds: $0) } ?? fallback
        return UsageWindow(kind: kind, usedFraction: fraction, resetsAt: resetsAt, label: label)
    }

    static func kindAndLabel(seconds: Double) -> (WindowKind, String) {
        if seconds <= 86_400 {
            let hours = max(1, Int((seconds / 3_600).rounded()))
            return (.session, hours == 5 ? "5h" : "\(hours)h")
        }
        let days = max(1, Int((seconds / 86_400).rounded()))
        return (.weekly, days == 7 ? "Semanal" : "\(days)d")
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw CodexProviderError(account: account.id)
        }
    }
}
