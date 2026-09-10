import Foundation
import TokenBarCore

/// Credencial do Grok CLI (SuperGrok) — portado da referência MIT CodexBar
/// (`Sources/CodexBarCore/Providers/Grok/GrokAuth.swift`): `~/.grok/auth.json`
/// é um mapa por scope URL; preferência OIDC prefixado `https://auth.x.ai::`
/// (SuperGrok) com fallback `https://accounts.x.ai/sign-in`. Entrada usada:
/// `key` (bearer), `expires_at`, `email`. Mantida em memória, nunca logada.
public struct GrokCredential: Sendable, Equatable {
    public let accessToken: String
    public let email: String?
    public let expiresAt: Date?
}

/// Leitor read-only do `auth.json` do Grok CLI. Conta registrada: mesmo shape
/// OU token cru (uma linha). Nunca escreve, nunca loga.
///
/// Overrides de testes/wiring:
/// - env `TOKENBAR_GROK_AUTH` → caminho do `auth.json` (convenção do repo).
/// - env `GROK_HOME` → diretório do CLI (mesmo override da referência).
/// - Conta registrada: o path do próprio registro.
public struct GrokCredentialReader: Sendable {
    public static let oidcScopePrefix = "https://auth.x.ai::"
    public static let legacySessionScope = "https://accounts.x.ai/sign-in"

    public let authFileURL: URL?

    public init(authFileURL: URL?) {
        self.authFileURL = authFileURL
    }

    public static func resolve(environment: [String: String], home: URL) -> GrokCredentialReader {
        let url: URL
        if let raw = environment["TOKENBAR_GROK_AUTH"], !raw.isEmpty {
            url = URL(filePath: raw)
        } else if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            url = URL(filePath: (grokHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        } else {
            url = home.appendingPathComponent(".grok/auth.json")
        }
        return GrokCredentialReader(authFileURL: url)
    }

    public static func resolve() -> GrokCredentialReader {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            home: URL(filePath: NSHomeDirectory()))
    }

    /// Guard Red Team F4: só REGULAR file. Formato aceito: `auth.json` do CLI
    /// (mapa por scope) OU token cru (conta registrada). Inválido/vazio → `nil`.
    public func read() -> GrokCredential? {
        guard let authFileURL,
              FileKind.isRegularFile(atPath: authFileURL.path),
              let data = try? Data(contentsOf: authFileURL)
        else { return nil }
        if let credential = Self.parse(data) { return credential }
        if let content = String(data: data, encoding: .utf8) {
            return Self.parseRawToken(content)
        }
        return nil
    }

    static func parse(_ data: Data) -> GrokCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Mapa por scope: OIDC vence o legado (ordem da referência); entrada
        // sem `key` utilizável não sombreia uma saudável.
        var oidc: [String: Any]?
        var legacy: [String: Any]?
        for (scope, value) in root {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty
            else { continue }
            if scope.hasPrefix(Self.oidcScopePrefix) {
                oidc = oidc ?? entry
            } else if scope == Self.legacySessionScope || scope.contains("/sign-in") {
                legacy = legacy ?? entry
            }
        }
        guard let entry = oidc ?? legacy, let key = entry["key"] as? String, !key.isEmpty else {
            return nil
        }
        return GrokCredential(
            accessToken: key,
            email: (entry["email"] as? String)?.isEmpty == false ? entry["email"] as? String : nil,
            expiresAt: Self.parseDate(entry["expires_at"]))
    }

    static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return UsageDates.iso8601(value)
    }

    /// Token cru (conta registrada sem JSON).
    static func parseRawToken(_ content: String) -> GrokCredential? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return GrokCredential(accessToken: trimmed, email: nil, expiresAt: nil)
    }
}

/// Conta solicitada não é a conta que esta instância atende.
public struct GrokProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Resposta do proxy de billing sem percent calculável — erro tipado
/// (rethrow → backoff; nunca vira dado no snapshot).
public struct GrokAPIError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Provider do Grok (xAI), F5 Task 5 — API-only.
///
/// Fonte MIT: `Sources/CodexBarCore/Providers/Grok/{GrokCreditsProxyFetcher,GrokAuth}.swift`.
///
/// - `fetchUsage`: token do `auth.json` → `GET
///   https://cli-chat-proxy.grok.com/v1/billing?format=credits` com Bearer +
///   header `x-xai-token-auth: xai-grok-cli` (o proxy do CLI é o caminho
///   suportado — o gRPC-web de grok.com exige keypair de browser). Token
///   vencido → `.invalid` SEM request (não há refresh read-only).
/// - Payload: `config.creditUsagePercent` (0–100) OU par
///   `onDemandUsed/onDemandCap` → janela `Plano` com `resetsAt` =
///   `currentPeriod.end` → `billingPeriodEnd` (ISO8601). Sem percent →
///   `GrokAPIError`.
/// - Menu: `K:<percent>%`.
public final class GrokProvider: Sendable, UsageProvider {
    public static let defaultBaseURL = URL(string: "https://cli-chat-proxy.grok.com")!
    public static let billingPath = "v1/billing"
    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    public var account: AccountID { AccountID(provider: .grok, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    public let accountKey: String
    private let label: String
    private let accounts: AccountRegistry?

    private let credentialReader: GrokCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: GrokCredentialReader,
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

    // MARK: - UsageProvider

    public var id: ProviderID { .grok }

    public var capabilities: ProviderCapabilities { [.apiUsage, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read() != nil ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .grok)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .grok, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let credential = credentialReader.read() else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSinceNow <= 60 {
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }

        var url = client.baseURL.appending(path: Self.billingPath)
        url.append(queryItems: [URLQueryItem(name: "format", value: "credits")])

        do {
            let data = try await client.getJSON(
                url: url,
                bearer: credential.accessToken,
                headers: ["User-Agent": Self.userAgent, "x-xai-token-auth": "xai-grok-cli"])
            let response = try JSONDecoder().decode(GrokCreditsResponse.self, from: data)
            guard let window = Self.mapWindow(response) else {
                throw GrokAPIError("billing payload without usable percent")
            }
            return UsageSnapshot(
                provider: .grok,
                account: self.account,
                windows: [window],
                credits: nil,
                fetchedAt: fetchedAt,
                source: .api,
                authState: .ok)
        } catch let error as UsageHTTPError where error == .unauthorized {
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }
        // Demais erros (rede, http != 401/403, decode, GrokAPIError): rethrow.
    }

    // MARK: - Decoders

    struct GrokCreditsResponse: Decodable, Sendable {
        let config: Config?
        let subscriptionTier: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            config = FlexibleJSON.optional(Config.self, c, "config")
            subscriptionTier = FlexibleJSON.string(c, "subscriptionTier", "subscription_tier")
        }
    }

    struct Config: Decodable, Sendable {
        let creditUsagePercent: Double?
        let currentPeriod: CurrentPeriod?
        let billingPeriodEnd: String?
        let onDemandCap: Amount?
        let onDemandUsed: Amount?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            creditUsagePercent = FlexibleJSON.double(c, "creditUsagePercent", "credit_usage_percent")
            currentPeriod = FlexibleJSON.optional(CurrentPeriod.self, c, "currentPeriod", "current_period")
            billingPeriodEnd = FlexibleJSON.string(c, "billingPeriodEnd", "billing_period_end")
            onDemandCap = FlexibleJSON.optional(Amount.self, c, "onDemandCap", "on_demand_cap")
            onDemandUsed = FlexibleJSON.optional(Amount.self, c, "onDemandUsed", "on_demand_used")
        }
    }

    struct CurrentPeriod: Decodable, Sendable {
        let end: String?

        init(from decoder: Decoder) throws {
            end = FlexibleJSON.string(try decoder.container(keyedBy: AnyKey.self), "end")
        }
    }

    /// O proxy reporta valores como `{ "val": <número> }` (formato da
    /// referência — aceita fração para shapes incomuns não derrubarem o decode).
    struct Amount: Decodable, Sendable {
        let val: Double?

        init(from decoder: Decoder) throws {
            val = FlexibleJSON.double(try decoder.container(keyedBy: AnyKey.self), "val")
        }
    }

    /// Percent da referência `parseSnapshot`: `creditUsagePercent` direto,
    /// senão razão on-demand (cap > 0). `resetsAt` = `currentPeriod.end` →
    /// `billingPeriodEnd`.
    static func mapWindow(_ response: GrokCreditsResponse) -> UsageWindow? {
        guard let config = response.config else { return nil }
        let percent: Double?
        if let direct = config.creditUsagePercent, direct.isFinite {
            percent = direct
        } else if let cap = config.onDemandCap?.val, cap > 0, let used = config.onDemandUsed?.val {
            percent = used / cap * 100
        } else {
            percent = nil
        }
        guard let percent, percent.isFinite else { return nil }
        return UsageWindow(
            kind: .weekly,
            usedFraction: min(max(percent / 100, 0), 1),
            resetsAt: UsageDates.iso8601(config.currentPeriod?.end) ?? UsageDates.iso8601(config.billingPeriodEnd),
            label: "Plano")
    }

    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .grok,
            account: self.account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState)
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw GrokProviderError(account: account.id)
        }
    }
}
