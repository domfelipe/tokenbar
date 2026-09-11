import Foundation
import TokenBarCore

/// Conta solicitada não é a conta que esta instância atende (canônica é
/// `.cursor/local`; registradas recebem instância própria no wiring — F4).
public struct CursorProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Decoder tolerante da resposta `/api/usage-summary` — portado da referência
/// MIT CodexBar (`Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`,
/// structs `CursorUsageSummary`/`CursorIndividualUsage`/`CursorPlanUsage`).
/// Tudo opcional, snake/camel por alias; valores monetários em CENTAVOS
/// (ex.: 7384 = $73.84); percentuais JÁ vêm em unidade de % (0.36 = 0.36%).
struct CursorUsageSummaryResponse: Decodable, Sendable, Equatable {
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        billingCycleEnd = FlexibleJSON.string(c, "billingCycleEnd", "billing_cycle_end")
        membershipType = FlexibleJSON.string(c, "membershipType", "membership_type")
        individualUsage = FlexibleJSON.optional(IndividualUsage.self, c, "individualUsage", "individual_usage")
        teamUsage = FlexibleJSON.optional(TeamUsage.self, c, "teamUsage", "team_usage")
    }

    struct IndividualUsage: Decodable, Sendable, Equatable {
        let plan: PlanUsage?
        let onDemand: UsageBlock?
        let overall: UsageBlock?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            plan = FlexibleJSON.optional(PlanUsage.self, c, "plan")
            onDemand = FlexibleJSON.optional(UsageBlock.self, c, "onDemand", "on_demand")
            overall = FlexibleJSON.optional(UsageBlock.self, c, "overall")
        }
    }

    struct TeamUsage: Decodable, Sendable, Equatable {
        let pooled: UsageBlock?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            pooled = FlexibleJSON.optional(UsageBlock.self, c, "pooled")
        }
    }

    /// Bloco de uso em centavos (plan/onDemand/overall/pooled compartilham a
    /// forma — referência: "values follow the same cents-based units").
    struct UsageBlock: Decodable, Sendable, Equatable {
        let used: Double?
        let limit: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            used = FlexibleJSON.double(c, "used")
            limit = FlexibleJSON.double(c, "limit")
        }
    }

    struct PlanUsage: Decodable, Sendable, Equatable {
        let used: Double?
        let limit: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            used = FlexibleJSON.double(c, "used")
            limit = FlexibleJSON.double(c, "limit")
            autoPercentUsed = FlexibleJSON.double(c, "autoPercentUsed", "auto_percent_used")
            apiPercentUsed = FlexibleJSON.double(c, "apiPercentUsed", "api_percent_used")
            totalPercentUsed = FlexibleJSON.double(c, "totalPercentUsed", "total_percent_used")
        }
    }
}

/// Provider do Cursor, F5 Task 4 — API-only, credencial read-only.
///
/// Fonte MIT: `Sources/CodexBarCore/Providers/Cursor/{CursorStatusProbe,CursorAppAuth}.swift`.
///
/// - `fetchUsage`: sessão de `state.vscdb` (auto) ou arquivo registrado →
///   `GET {base}/api/usage-summary` com header `Cookie` (a API do Cursor usa
///   cookie de sessão web, não Bearer). 401/403 → `authState: .invalid` +
///   snapshot vazio `.localOnly`; erro de rede/HTTP/decode → rethrow (backoff
///   do AdaptiveScheduler; spec §5 regra 3 — nunca retry interno).
/// - Sem credencial utilizável: `discoverAccounts() == []` e snapshot vazio
///   `.missing` (provider some da barra — degradação local-first).
/// - Menu: `U:<planPercent>%` — percent do plano pela MESMA cadeia de
///   precedência da referência (`totalPercentUsed` → média auto/api → lane
///   única → razão plan → razão overall → razão pooled).
public final class CursorProvider: Sendable, UsageProvider {
    public static let defaultBaseURL = URL(string: "https://cursor.com")!
    public static let usagePath = "api/usage-summary"

    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    public var account: AccountID { AccountID(provider: .cursor, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    public let accountKey: String
    private let label: String
    private let accounts: AccountRegistry?

    private let credentialReader: CursorCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: CursorCredentialReader,
        client: UsageHTTPClient,
        accountKey: String = "local",
        label: String = "local",
        accounts: AccountRegistry? = nil
    ) {
        self.credentialReader = credentialReader
        self.client = client
        self.accountKey = accountKey
        self.label = label
        self.accounts = accounts
    }

    /// Override de base URL p/ testes/e2e: env `TOKENBAR_CURSOR_API` → global.
    public static func resolveBaseURL(environment: [String: String]) -> URL {
        if let raw = environment["TOKENBAR_CURSOR_API"], !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return defaultBaseURL
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .cursor }

    /// API-only: Cursor não tem transcript local mapeado (sem `.localIngest`);
    /// contas registradas (arquivo de sessão) ganham instância própria.
    public var capabilities: ProviderCapabilities { [.apiUsage, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    /// Descoberta MERGE: auto (sessão utilizável) + contas ATIVAS do registry.
    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read() != nil ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .cursor)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .cursor, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let credential = credentialReader.read() else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }

        do {
            let data = try await client.getJSON(
                path: Self.usagePath,
                bearer: nil,  // auth é cookie de sessão web, não Bearer
                headers: ["Cookie": credential.cookieHeader, "User-Agent": Self.userAgent])
            let response = try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
            return apiSnapshot(response, fetchedAt: fetchedAt)
        } catch let error as UsageHTTPError where error == .unauthorized {
            // Sessão rejeitada — relogin no Cursor resolve; nunca renovamos.
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }
        // Demais erros (rede, http != 401/403, decode de shape novo): rethrow.
    }

    // MARK: - Snapshots

    private func apiSnapshot(_ r: CursorUsageSummaryResponse, fetchedAt: Date) -> UsageSnapshot {
        let resetsAt = UsageDates.iso8601(r.billingCycleEnd)
        var windows: [UsageWindow] = []
        if let percent = Self.planPercent(from: r) {
            windows.append(UsageWindow(kind: .weekly, usedFraction: percent, resetsAt: resetsAt, label: "Plano"))
        }
        if let onDemand = r.individualUsage?.onDemand, let limit = onDemand.limit, limit > 0,
           let used = onDemand.used {
            windows.append(UsageWindow(
                kind: .weekly,
                usedFraction: min(max(used / limit, 0), 1),
                resetsAt: resetsAt,
                label: "On-demand"))
        }
        return UsageSnapshot(
            provider: .cursor,
            account: self.account,
            windows: windows,
            credits: nil,
            fetchedAt: fetchedAt,
            source: .api,
            authState: .ok)
    }

    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .cursor,
            account: self.account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState)
    }

    // MARK: - Percent do plano (cadeia da referência `parseUsageSummary`)

    /// Precedência MIT: `totalPercentUsed` → média auto+api → lane única
    /// (api, depois auto) → razão plan (centavos) → razão overall → razão
    /// pooled. Fração 0...1 saturada; `nil` = payload sem base para percent
    /// (nenhuma janela exibida — nada inventado).
    static func planPercent(from r: CursorUsageSummaryResponse) -> Double? {
        func clamped(_ raw: Double?) -> Double? {
            raw.map { min(max($0 / 100, 0), 1) }
        }
        let plan = r.individualUsage?.plan
        if let total = clamped(plan?.totalPercentUsed) { return total }
        if let auto = plan?.autoPercentUsed, let api = plan?.apiPercentUsed {
            return clamped((auto + api) / 2)
        }
        if let api = clamped(plan?.apiPercentUsed) { return api }
        if let auto = clamped(plan?.autoPercentUsed) { return auto }
        if let used = plan?.used, let limit = plan?.limit, limit > 0 {
            return min(max(used / limit, 0), 1)
        }
        if let overall = r.individualUsage?.overall, let limit = overall.limit, limit > 0,
           let used = overall.used {
            return min(max(used / limit, 0), 1)
        }
        if let pooled = r.teamUsage?.pooled, let limit = pooled.limit, limit > 0,
           let used = pooled.used {
            return min(max(used / limit, 0), 1)
        }
        return nil
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw CursorProviderError(account: account.id)
        }
    }
}
