import Foundation
import TokenBarCore

/// Leitor read-only da API key do Alibaba/Qwen Coding Plan — portado da
/// referência MIT CodexBar
/// (`Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanSettingsReader.swift`):
/// env na ordem `ALIBABA_CODING_PLAN_API_KEY` → `ALIBABA_QWEN_API_KEY` →
/// `DASHSCOPE_API_KEY`; contas registradas apontam um ARQUIVO com a key crua.
/// `~/.qwen` NÃO é lido (a referência não o lê — nada inventado). Nunca loga.
public struct AlibabaCredentialReader: Sendable {
    public static let apiTokenEnvironmentKeys = [
        "ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_QWEN_API_KEY", "DASHSCOPE_API_KEY",
    ]

    public let environment: [String: String]
    public let keyFileURL: URL?

    public init(environment: [String: String], keyFileURL: URL? = nil) {
        self.environment = environment
        self.keyFileURL = keyFileURL
    }

    /// Arquivo de conta registrada vence a env (conta é mais específica).
    public func read() -> String? {
        if let keyFileURL {
            return Self.readKeyFile(at: keyFileURL)
        }
        for key in Self.apiTokenEnvironmentKeys {
            if let value = Self.cleaned(environment[key]) { return value }
        }
        return nil
    }

    static func readKeyFile(at url: URL) -> String? {
        guard FileKind.isRegularFile(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return cleaned(raw)
    }

    /// `cleaned` da referência: trim + aspas envolventes + vazio → nil.
    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2
        {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

/// Conta solicitada não é a conta que esta instância atende.
public struct AlibabaProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Resposta do console sem os blocos de quota esperados — erro tipado
/// (rethrow → backoff; nunca vira dado no snapshot).
public struct AlibabaAPIError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Provider do Alibaba/Qwen Coding Plan, F5 Task 5 — API-only.
///
/// Fonte MIT: `Sources/CodexBarCore/Providers/Alibaba/{AlibabaCodingPlanUsageFetcher,AlibabaCodingPlanAPIRegion,AlibabaCodingPlanUsageSnapshot}.swift`.
///
/// - `fetchUsage`: API key → `POST {gateway}/data/api.json?action=
///   zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2&...`
///   com Bearer + `x-api-key` + `X-DashScope-API-Key` (mesma key — ordem da
///   referência). O gateway PRIMÁRIO é o baseURL injetado no client (canônico
///   intl no wiring; injetável p/ e2e); fallback = gateway CANÔNICO da outra
///   região (1 tentativa extra/ciclo, como `shouldRetryOnAlternateRegion`).
///   401/403 nas duas → `.invalid`; erro de rede → rethrow (backoff).
/// - Payload: busca recursiva por `codingPlanQuotaInfo` (aliases snake) e
///   janelas `per5Hour*`/`perWeek*`/`perBillMonth*` (com aliases da
///   referência). Sem quota utilizável em nenhuma região → `AlibabaAPIError`.
/// - Menu: `Q:<5h>%` — o wiring escolhe a janela crítica (5h costuma ser a
///   maior fração); o snapshot expõe as três janelas.
public final class AlibabaProvider: Sendable, UsageProvider {
    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    /// Região da referência (`AlibabaCodingPlanAPIRegion`).
    public struct Region: Sendable, Equatable {
        public let id: String
        public let gateway: URL
        public let regionID: String
        public let commodityCode: String

        init(id: String, gateway: URL, regionID: String, commodityCode: String) {
            self.id = id
            self.gateway = gateway
            self.regionID = regionID
            self.commodityCode = commodityCode
        }
    }

    /// Regiões canônicas da referência: intl (Model Studio) e cn (Bailian).
    public static let regions: [Region] = [
        Region(id: "intl", gateway: URL(string: "https://modelstudio.console.alibabacloud.com")!,
               regionID: "ap-southeast-1", commodityCode: "sfm_codingplan_public_intl"),
        Region(id: "cn", gateway: URL(string: "https://bailian.console.aliyun.com")!,
               regionID: "cn-beijing", commodityCode: "sfm_codingplan_public_cn"),
    ]

    static func canonicalRegion(_ id: String) -> Region {
        regions.first { $0.id == id } ?? regions[0]
    }

    /// Região primária: env `TOKENBAR_ALIBABA_REGION=cn` → cn; default intl.
    static func primaryRegionID(environment: [String: String]) -> String {
        environment["TOKENBAR_ALIBABA_REGION"]?.lowercased() == "cn" ? "cn" : "intl"
    }

    public var account: AccountID { AccountID(provider: .alibaba, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    public let accountKey: String
    private let label: String
    private let accounts: AccountRegistry?

    private let credentialReader: AlibabaCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: AlibabaCredentialReader,
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

    /// Gateway canônico da região primária (usado no wiring p/ o client;
    /// testes/e2e injetam outra base direto no `UsageHTTPClient`).
    public static func resolveBaseURL(environment: [String: String]) -> URL {
        canonicalRegion(primaryRegionID(environment: environment)).gateway
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .alibaba }

    public var capabilities: ProviderCapabilities { [.apiUsage, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read() != nil ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .alibaba)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .alibaba, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let apiKey = credentialReader.read() else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }

        let primaryID = Self.primaryRegionID(environment: credentialReader.environment)
        let primary = Self.Region(
            id: primaryID,
            gateway: client.baseURL,
            regionID: Self.canonicalRegion(primaryID).regionID,
            commodityCode: Self.canonicalRegion(primaryID).commodityCode)
        let ordered = [primary, Self.canonicalRegion(primaryID == "cn" ? "intl" : "cn")]

        var rejectedUnauthorized = false
        for region in ordered {
            do {
                let data = try await client.postJSON(
                    url: Self.quotaURL(region: region),
                    bearer: apiKey,
                    headers: Self.requestHeaders(apiKey: apiKey),
                    body: Self.requestBody(region: region))
                let json = try JSONSerialization.jsonObject(with: data)
                if let quota = Self.findQuotaInfo(in: json) {
                    return apiSnapshot(quota, planName: Self.findPlanName(in: json), fetchedAt: fetchedAt)
                }
                // Payload sem quota NESTA região → tenta a outra (a referência
                // trata "quota indisponível na região" com troca de região).
                if region.id == ordered.last?.id {
                    throw AlibabaAPIError("no quota windows in payload (both regions)")
                }
            } catch let error as UsageHTTPError where error == .unauthorized {
                rejectedUnauthorized = true  // tenta a região alternativa
            }
            // Demais erros (rede, http, decode): rethrow — backoff do scheduler.
        }
        return degraded(authState: rejectedUnauthorized ? .invalid : .missing, fetchedAt: fetchedAt)
    }

    // MARK: - Request (contrato da referência, modo API key)

    /// Headers da referência: a MESMA key vai em `Authorization` (Bearer, via
    /// client), `x-api-key` e `X-DashScope-API-Key`.
    static func requestHeaders(apiKey: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "x-api-key": apiKey,
            "X-DashScope-API-Key": apiKey,
        ]
    }

    static func quotaURL(region: Region) -> URL {
        var components = URLComponents(url: region.gateway, resolvingAgainstBaseURL: false)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: region.regionID),
        ]
        return components.url!
    }

    static func requestBody(region: Region) -> Data {
        let payload: [String: Any] = [
            "queryCodingPlanInstanceInfoRequest": ["commodityCode": region.commodityCode],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    // MARK: - Parse (busca recursiva tolerante)

    /// Janela de quota: pares (labels usados, total em unidades de quota).
    static let windowKeys: [(used: [String], total: [String], reset: [String], kind: WindowKind, label: String)] = [
        (["per5HourUsedQuota", "perFiveHourUsedQuota"], ["per5HourTotalQuota", "perFiveHourTotalQuota"],
         ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"], .session, "5h"),
        (["perWeekUsedQuota"], ["perWeekTotalQuota"], ["perWeekQuotaNextRefreshTime"], .weekly, "Semanal"),
        (["perBillMonthUsedQuota", "perMonthUsedQuota"], ["perBillMonthTotalQuota", "perMonthTotalQuota"],
         ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"], .weekly, "Mensal"),
    ]

    /// Primeiro dicionário na árvore JSON que contém `codingPlanQuotaInfo`
    /// (alias snake) OU diretamente alguma chave de quota — mesmo espírito do
    /// `OneConsoleJSON.findObject`/`findQuotaInfo` da referência.
    static func findQuotaInfo(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let nested = dict["codingPlanQuotaInfo"] as? [String: Any] { return nested }
            if let nested = dict["coding_plan_quota_info"] as? [String: Any] { return nested }
            if hasQuotaKeys(dict) { return dict }
            for key in dict.keys.sorted() {
                if let found = findQuotaInfo(in: dict[key]!) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array where findQuotaInfo(in: item) != nil {
                return findQuotaInfo(in: item)
            }
        }
        return nil
    }

    static func hasQuotaKeys(_ dict: [String: Any]) -> Bool {
        let allKeys = Set(windowKeys.flatMap { $0.used + $0.total })
        return !allKeys.isDisjoint(with: dict.keys)
    }

    static func findPlanName(in value: Any) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in ["planName", "plan_name", "packageName", "package_name"] {
            if let name = dict[key] as? String, !name.isEmpty { return name }
        }
        if let infos = dict["codingPlanInstanceInfos"] as? [[String: Any]] ??
            (dict["codingPlanInstanceInfos"] as? [Any]).map({ $0.compactMap { $0 as? [String: Any] } }) {
            for info in infos {
                for key in ["planName", "instanceName", "packageName"] {
                    if let name = info[key] as? String, !name.isEmpty { return name }
                }
            }
        }
        for key in dict.keys.sorted() {
            if let nested = dict[key] as? [String: Any], let name = findPlanName(in: nested) {
                return name
            }
        }
        return nil
    }

    // MARK: - Snapshots

    private func apiSnapshot(_ quota: [String: Any], planName: String?, fetchedAt: Date) -> UsageSnapshot {
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                if let n = quota[key] as? Double, n.isFinite { return n }
                if let n = quota[key] as? Int { return Double(n) }
                if let s = quota[key] as? String, let n = Double(s), n.isFinite { return n }
            }
            return nil
        }
        func date(_ keys: [String]) -> Date? {
            for key in keys {
                if let epoch = number([key]), let parsed = UsageDates.epochOrISO(epoch) { return parsed }
                if let s = quota[key] as? String, let parsed = UsageDates.oneConsole(s) { return parsed }
            }
            return nil
        }
        var windows: [UsageWindow] = []
        for (usedKeys, totalKeys, resetKeys, kind, label) in Self.windowKeys {
            guard let used = number(usedKeys), let total = number(totalKeys), total > 0 else { continue }
            windows.append(UsageWindow(
                kind: kind,
                usedFraction: min(max(used / total, 0), 1),
                resetsAt: date(resetKeys),
                label: label))
        }
        return UsageSnapshot(
            provider: .alibaba,
            account: self.account,
            windows: windows,
            credits: nil,
            fetchedAt: fetchedAt,
            source: .api,
            authState: .ok)
    }

    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .alibaba,
            account: account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState)
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw AlibabaProviderError(account: account.id)
        }
    }
}
