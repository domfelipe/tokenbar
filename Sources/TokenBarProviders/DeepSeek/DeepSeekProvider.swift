import Foundation
import TokenBarCore

/// Leitor read-only da API key da plataforma DeepSeek — portado da referência
/// MIT CodexBar (`Sources/CodexBarCore/Providers/DeepSeek/DeepSeekProviderDescriptor.swift`:
/// credencial do tipo API key). Arquivo da conta registrada (entrada manual)
/// ou env `DEEPSEEK_API_KEY`. Nunca loga.
public struct DeepSeekCredentialReader: Sendable {
    public static let environmentKey = "DEEPSEEK_API_KEY"

    public let environment: [String: String]
    public let keyFileURL: URL?

    public init(environment: [String: String], keyFileURL: URL? = nil) {
        self.environment = environment
        self.keyFileURL = keyFileURL
    }

    public func read() -> String? {
        if let keyFileURL {
            return Self.readKeyFile(at: keyFileURL)
        }
        guard let raw = environment[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    static func readKeyFile(at url: URL) -> String? {
        guard FileKind.isRegularFile(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Conta solicitada não é a conta que esta instância atende.
public struct DeepSeekProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Resposta `/user/balance` sem `balance_infos` utilizável — erro tipado
/// (rethrow → backoff; nunca vira dado no snapshot).
public struct DeepSeekAPIError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Provider da plataforma DeepSeek, F5 Task 5 — API-only (saldo, não quota).
///
/// Fonte MIT: `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift`
/// (`fetchBalanceData` + structs `DeepSeekBalanceResponse`/`DeepSeekBalanceInfo`).
///
/// - `fetchUsage`: API key → `GET https://api.deepseek.com/user/balance` com
///   Bearer → saldo da conta em `balance_infos[0].total_balance` →
///   `credits`. 401/403 → `.invalid` + snapshot vazio; rede/contrato →
///   rethrow (backoff).
/// - SEM janelas de uso: a API de saldo não devolve quota — e sem percent/tokens
///   o provider NÃO aparece no texto do menu (`hasData` falso). Honestidade
///   primeiro: o saldo real fica no snapshot p/ a UI de credits; nada de
///   percent inventado. (docs/specs/f5-providers.md § DeepSeek.)
/// - Não portado: usage/cost do `platform.deepseek.com` — exigem PLATFORM
///   token separado e a referência os trata como opcionais.
public final class DeepSeekProvider: Sendable, UsageProvider {
    public static let defaultBaseURL = URL(string: "https://api.deepseek.com")!
    public static let balancePath = "user/balance"

    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    public var account: AccountID { AccountID(provider: .deepseek, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    public let accountKey: String
    private let label: String
    private let accounts: AccountRegistry?

    private let credentialReader: DeepSeekCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: DeepSeekCredentialReader,
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

    public var id: ProviderID { .deepseek }

    public var capabilities: ProviderCapabilities { [.apiUsage, .credits, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read() != nil ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .deepseek)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .deepseek, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let apiKey = credentialReader.read() else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }

        do {
            let data = try await client.getJSON(
                path: Self.balancePath,
                bearer: apiKey,
                headers: ["User-Agent": Self.userAgent])
            let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            guard let info = response.balanceInfos?.first, let total = info.totalBalance, total.isFinite else {
                throw DeepSeekAPIError("balance payload missing balance_infos/total_balance")
            }
            return UsageSnapshot(
                provider: .deepseek,
                account: self.account,
                windows: [],
                credits: CreditsInfo(remaining: total, unlimited: false),
                fetchedAt: fetchedAt,
                source: .api,
                authState: .ok)
        } catch let error as UsageHTTPError where error == .unauthorized {
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }
        // Demais erros (rede, http != 401/403, decode, DeepSeekAPIError): rethrow.
    }

    // MARK: - Decoders

    struct DeepSeekBalanceResponse: Decodable, Sendable {
        let isAvailable: Bool?
        let balanceInfos: [BalanceInfo]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            isAvailable = FlexibleJSON.bool(c, "is_available", "isAvailable")
            balanceInfos = FlexibleJSON.optional([BalanceInfo].self, c, "balance_infos", "balanceInfos")
        }
    }

    struct BalanceInfo: Decodable, Sendable {
        let currency: String?
        /// A API devolve o saldo como STRING ("110.00") — aceita número também.
        let totalBalance: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            currency = FlexibleJSON.string(c, "currency")
            totalBalance = FlexibleJSON.double(c, "total_balance", "totalBalance")
        }
    }

    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .deepseek,
            account: self.account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState)
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw DeepSeekProviderError(account: account.id)
        }
    }
}
