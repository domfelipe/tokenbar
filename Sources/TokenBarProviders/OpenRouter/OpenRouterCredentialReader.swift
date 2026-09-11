import Foundation
import TokenBarCore

/// Leitor read-only da API key do OpenRouter — portado da referência MIT
/// CodexBar (`Sources/CodexBarCore/Providers/OpenRouter/OpenRouterSettingsReader.swift`):
/// a referência resolve o token da env `OPENROUTER_API_KEY`; contas
/// registradas apontam um ARQUIVO com a key crua (entrada manual da UI
/// multi-conta F4). A key pode ser revogada a qualquer momento — lê a cada
/// chamada, nunca escreve, nunca loga.
public struct OpenRouterCredentialReader: Sendable {
    public let keyFileURL: URL?
    public let environment: [String: String]

    public init(keyFileURL: URL? = nil, environment: [String: String] = [:]) {
        self.keyFileURL = keyFileURL
        self.environment = environment
    }

    public static let environmentKey = "OPENROUTER_API_KEY"

    /// Ordem (referência): arquivo de conta registrada (quando presente) →
    /// env `OPENROUTER_API_KEY`. Guard Red Team F4: só ARQUIVO REGULAR.
    public func read() -> String? {
        if let keyFileURL {
            return Self.readKeyFile(at: keyFileURL)
        }
        return Self.cleaned(environment[Self.environmentKey])
    }

    /// Key crua no arquivo (aspas/whitespace ao redor são tolerados — mesmo
    /// `cleaned` da referência).
    static func readKeyFile(at url: URL) -> String? {
        guard FileKind.isRegularFile(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return cleaned(raw)
    }

    /// `cleaned` da referência: trim + remove aspas envolventes + vazio → nil.
    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2
        {
            value = String(value.dropFirst().dropLast())
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

/// Conta solicitada não é a conta que esta instância atende.
public struct OpenRouterProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Resposta `/credits` ou `/key` bem-formada mas sem o bloco `data` — erro
/// tipado (rethrow → backoff; nunca vira dado no snapshot).
public struct OpenRouterAPIError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Provider do OpenRouter, F5 Task 4 — API-only, `.multiAccount` REAL
/// (cada API key é uma conta; entrada manual via registro multi-conta).
///
/// Fonte MIT: `Sources/CodexBarCore/Providers/OpenRouter/{OpenRouterProviderDescriptor,OpenRouterSettingsReader}.swift`
/// + plugin `Sources/CodexBarCore/Resources/Plugins/openrouter.js` (endpoints).
///
/// - `GET {base}/credits` → `{ data: { total_credits, total_usage } }` →
///   saldo = max(0, total_credits − total_usage) → `credits`. Falha aqui é
///   falha do provider (401 → `.invalid`; rede/HTTP/contrato → rethrow).
/// - `GET {base}/key` → `{ data: { limit, limit_remaining, usage, usage_*,
///   limit_reset } }` → janela de quota da key. Opcional NA REFERÊNCIA
///   (degradação soft): erro não derruba o snapshot — a janela é omitida.
/// - Sem key: `discoverAccounts() == []` e snapshot vazio `.missing`.
public final class OpenRouterProvider: Sendable, UsageProvider {
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    public var account: AccountID { AccountID(provider: .openrouter, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    public let accountKey: String
    private let label: String
    private let accounts: AccountRegistry?

    private let credentialReader: OpenRouterCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: OpenRouterCredentialReader,
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

    /// Ordem de base URL p/ wiring: env `TOKENBAR_OPENROUTER_API` (convenção
    /// do repo, testes/e2e) → env `OPENROUTER_API_URL` da referência → global
    /// `https://openrouter.ai/api/v1`.
    public static func resolveBaseURL(environment: [String: String]) -> URL {
        for key in ["TOKENBAR_OPENROUTER_API", "OPENROUTER_API_URL"] {
            if let raw = environment[key], !raw.isEmpty,
               let url = URL(string: raw),
               let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
            {
                return url
            }
        }
        return defaultBaseURL
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .openrouter }

    /// API-only; multi-conta real: uma API key por conta registrada.
    public var capabilities: ProviderCapabilities { [.apiUsage, .credits, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read() != nil ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .openrouter)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .openrouter, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let apiKey = credentialReader.read() else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }

        // Credits é o request primário da referência: falha = falha do
        // provider (401 → .invalid; demais → rethrow p/ backoff).
        let creditsData: Data
        do {
            creditsData = try await client.getJSON(
                url: client.baseURL.appending(path: "credits"),
                bearer: apiKey,
                headers: ["User-Agent": Self.userAgent])
        } catch let error as UsageHTTPError where error == .unauthorized {
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }
        let credits = try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: creditsData)
        guard let creditsPayload = credits.data, creditsPayload.totalCredits != nil || creditsPayload.totalUsage != nil else {
            throw OpenRouterAPIError("credits payload missing total_credits/total_usage")
        }

        // Key quota é opcional (degradação soft da referência): erro → sem
        // janela, snapshot segue com credits.
        var keyWindow: UsageWindow?
        if let keyData = try? await client.getJSON(
            url: client.baseURL.appending(path: "key"),
            bearer: apiKey,
            headers: ["User-Agent": Self.userAgent]),
           let key = try? JSONDecoder().decode(OpenRouterKeyResponse.self, from: keyData),
           let window = Self.mapWindow(key.data)
        {
            keyWindow = window
        }

        let balance = max(0, (creditsPayload.totalCredits ?? 0) - (creditsPayload.totalUsage ?? 0))
        return UsageSnapshot(
            provider: .openrouter,
            account: self.account,
            windows: keyWindow.map { [$0] } ?? [],
            credits: CreditsInfo(remaining: balance, unlimited: false),
            fetchedAt: fetchedAt,
            source: .api,
            authState: .ok)
    }

    // MARK: - Decoders

    struct OpenRouterCreditsResponse: Decodable, Sendable {
        let data: Payload?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            data = FlexibleJSON.optional(Payload.self, c, "data")
        }

        struct Payload: Decodable, Sendable {
            let totalCredits: Double?
            let totalUsage: Double?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                totalCredits = FlexibleJSON.double(c, "total_credits", "totalCredits")
                totalUsage = FlexibleJSON.double(c, "total_usage", "totalUsage")
            }
        }
    }

    struct OpenRouterKeyResponse: Decodable, Sendable {
        let data: Payload?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            data = FlexibleJSON.optional(Payload.self, c, "data")
        }

        struct Payload: Decodable, Sendable {
            let limit: Double?
            let limitRemaining: Double?
            let usage: Double?
            let usageDaily: Double?
            let usageWeekly: Double?
            let usageMonthly: Double?
            let limitReset: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                limit = FlexibleJSON.double(c, "limit")
                limitRemaining = FlexibleJSON.double(c, "limit_remaining", "limitRemaining")
                usage = FlexibleJSON.double(c, "usage")
                usageDaily = FlexibleJSON.double(c, "usage_daily", "usageDaily")
                usageWeekly = FlexibleJSON.double(c, "usage_weekly", "usageWeekly")
                usageMonthly = FlexibleJSON.double(c, "usage_monthly", "usageMonthly")
                limitReset = FlexibleJSON.string(c, "limit_reset", "limitReset")
            }
        }
    }

    // MARK: - Janela da key (lógica do plugin `openrouter.js`)

    /// Usado da referência (função `keyUsedForQuota`): prefere
    /// `limit_remaining` (uso = limit − clamp(remaining, 0, limit)); senão o
    /// `usage_*` da janela declarada em `limit_reset`; senão o `usage`
    /// cumulativo. Fração = uso/limit quando limit > 0.
    static func mapWindow(_ payload: OpenRouterKeyResponse.Payload?) -> UsageWindow? {
        guard let payload, let limit = payload.limit, limit > 0 else { return nil }
        let used: Double
        if let remaining = payload.limitRemaining {
            used = limit - min(limit, max(0, remaining))
        } else if let windowUsage = windowUsage(payload) {
            used = windowUsage
        } else if let usage = payload.usage {
            used = usage
        } else {
            return nil
        }
        guard used.isFinite, used >= 0 else { return nil }

        let (kind, label): (WindowKind, String)
        switch payload.limitReset?.lowercased() {
        case "daily": (kind, label) = (.daily, "Diária")
        case "weekly": (kind, label) = (.weekly, "Semanal")
        case "monthly": (kind, label) = (.weekly, "Mensal")
        default: (kind, label) = (.weekly, "API key")
        }
        return UsageWindow(
            kind: kind,
            usedFraction: min(max(used / limit, 0), 1),
            resetsAt: nil,  // a API não devolve timestamp de reset
            label: label)
    }

    private static func windowUsage(_ payload: OpenRouterKeyResponse.Payload) -> Double? {
        switch payload.limitReset?.lowercased() {
        case "daily": return payload.usageDaily
        case "weekly": return payload.usageWeekly
        case "monthly": return payload.usageMonthly
        default: return nil
        }
    }

    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .openrouter,
            account: self.account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState)
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw OpenRouterProviderError(account: account.id)
        }
    }
}
