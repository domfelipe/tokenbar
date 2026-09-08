import Foundation
import TokenBarCore

/// Conta solicitada não é a conta local que este provider atende (F2 tem uma
/// conta por instalação: `.zai/local`).
public struct ZaiProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Resposta bem-formada que violou o contrato `success === true && code === 200`
/// (spec §2.3): erro tipado. A auth pode estar ok (não é 401/403) — o scheduler
/// trata como transiente; nunca vira dado no snapshot.
public struct ZaiAPIStatusError: Error, Sendable, Equatable {
    public let success: Bool?
    public let code: Int64?
    public let msg: String?

    public init(success: Bool?, code: Int64?, msg: String?) {
        self.success = success
        self.code = code
        self.msg = msg
    }
}

/// Um item de `data.limits[]` (spec §2.3). `percentage` define se o item vira
/// janela (ausente → item ignorado); `nextResetTime` é epoch em MILISSEGUNDOS
/// (Codex usa segundos — não confundir). Chaves extras (`usage`,
/// `currentValue`, `remaining`, `usageDetails`) são ignoradas sem quebrar.
struct ZaiLimit: Decodable, Sendable, Equatable {
    let rawType: String?
    let unit: Int64?
    let number: Double?
    let percentage: Double?
    let nextResetTime: Double?  // epoch ms

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        rawType = FlexibleJSON.string(c, "type")
        unit = FlexibleJSON.int64(c, "unit")
        number = FlexibleJSON.double(c, "number")
        percentage = FlexibleJSON.double(c, "percentage")
        nextResetTime = FlexibleJSON.double(c, "nextResetTime", "next_reset_time")
    }
}

/// Decoder tolerante da resposta `quota/limit` (spec §2.3): tudo opcional,
/// números int/double/string, `plan*` em qualquer alias — a validação
/// `success`/`code` é EXPLÍCITA (não confia no decode para isso).
struct ZaiQuotaResponse: Decodable, Sendable, Equatable {
    let success: Bool?
    let code: Int64?
    let msg: String?
    let planName: String?  // identidade do plano (sem slot no snapshot F2, padrão Codex)
    let limits: [ZaiLimit]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        success = FlexibleJSON.bool(c, "success")
        code = FlexibleJSON.int64(c, "code")
        msg = FlexibleJSON.string(c, "msg")
        planName = FlexibleJSON.string(c, "planName", "plan", "plan_type", "planType", "packageName", "level")
        limits = Self.limits(c)
    }

    /// `data.limits[]` com decode lossy POR ELEMENTO (spec §2.7: entrada
    /// desconhecida é descartada sem derrubar o resto) — o wrapper nunca
    /// throws, então o cursor do array avança normalmente.
    private static func limits(_ c: KeyedDecodingContainer<AnyKey>) -> [ZaiLimit] {
        guard let data = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("data")),
              var array = try? data.nestedUnkeyedContainer(forKey: AnyKey("limits"))
        else { return [] }
        var result: [ZaiLimit] = []
        while !array.isAtEnd {
            if let element = try? array.decode(ZaiLimitElement.self), let limit = element.limit {
                result.append(limit)
            }
        }
        return result
    }
}

/// Wrapper de elemento lossy: qualquer falha no decode do item vira
/// `limit: nil` (ex.: elemento não-objeto no array).
private struct ZaiLimitElement: Decodable {
    let limit: ZaiLimit?

    init(from decoder: Decoder) throws {
        limit = try? ZaiLimit(from: decoder)
    }
}

/// Provider do Z.ai coding plan (ZCode/Z.ai), F2 — API-only (spec §2.5: sem
/// ingest local).
///
/// - `fetchUsage`: credencial de `~/.zcode/v2/` (apiKey de `config.json` na
///   ordem 1, OAuth `oauth:zai:access_token` de `credentials.json` no fallback,
///   spec §2.2) → `GET {base}/api/monitor/usage/quota/limit` com Bearer.
///   Valida `success === true && code === 200`; 401/403 (com a 2ª credencial
///   também rejeitada) → `authState: .invalid` + snapshot vazio `.localOnly`;
///   erro de rede/HTTP/contrato → rethrow (o AdaptiveScheduler trata backoff;
///   spec §5 regra 3 — nunca retry interno).
/// - Sem credencial: `discoverAccounts() == []` e snapshot `.missing` vazio.
/// - Menu: `Z:81%` — o wiring (T7) escolhe a janela TOKENS; este provider
///   expõe TODAS as janelas da resposta.
public final class ZaiProvider: Sendable, UsageProvider {
    /// URL canônica global da spec §2.1 (override por env `TOKENBAR_ZAI_API`;
    /// região CN via hint do `config.json`, §2.2).
    public static let defaultBaseURL = URL(string: "https://api.z.ai")!
    public static let quotaPath = "api/monitor/usage/quota/limit"

    public static let userAgent = "TokenBar/\(ProvidersInfo.version)"

    public var account: AccountID { AccountID(provider: .zai, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    /// Key da conta que ESTA instância serve ("local" na canônica; contas
    /// registradas recebem instância própria no wiring — F4).
    public let accountKey: String
    /// Label de exibição da conta registrada (igual ao key em instâncias locais).
    private let label: String
    /// Registry multi-conta (F4): presente na instância canônica, alimenta a
    /// descoberta MERGE. `nil` = comportamento F2.
    private let accounts: AccountRegistry?

    private let credentialReader: ZaiCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: ZaiCredentialReader,
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

    /// Resolução de base URL p/ wiring (testes injetam direto no init). Ordem:
    /// env `TOKENBAR_ZAI_API` → `regionHint` (detectado do host do
    /// `options.baseURL`, spec §2.2/§2.7) → global canônica (§2.1).
    public static func resolveBaseURL(environment: [String: String], regionHint: URL? = nil) -> URL {
        if let raw = environment["TOKENBAR_ZAI_API"], !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        if let regionHint {
            return regionHint
        }
        return defaultBaseURL
    }

    // MARK: - UsageProvider

    public var id: ProviderID { .zai }

    /// API-only na F2: Z.ai não tem arquivo de sessão com contagem de tokens
    /// mapeada (spec §2.5) — sem `.localIngest`. F4: `.multiAccount` — contas
    /// com config.json registrado ganham instância própria no wiring.
    public var capabilities: ProviderCapabilities { [.apiUsage, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    /// Descoberta MERGE (F4): auto (credencial presente) + contas ATIVAS do
    /// registry, dedupe por key. Falha de leitura do registry → só as auto.
    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read()?.hasCredential == true ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .zai)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .zai, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let credential = credentialReader.read(), credential.hasCredential else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }

        // Ordem da spec §2.2: apiKey primeiro (mesmo tipo de credencial que o
        // CLI consome) e, se 401/403, o OAuth do coding plan. Isso NÃO é retry
        // do mesmo request (contrato §5 regra 3 segue valendo) — é a segunda
        // credencial, no máximo 2 requests por ciclo.
        var tokens: [String] = []
        if let apiKey = credential.apiKey { tokens.append(apiKey) }
        if let oauth = credential.oauthToken, oauth != tokens.first { tokens.append(oauth) }

        var rejectedUnauthorized = false
        for token in tokens {
            do {
                let data = try await client.getJSON(
                    path: Self.quotaPath,
                    bearer: token,
                    headers: ["User-Agent": Self.userAgent]
                )
                let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: data)
                guard response.success == true, response.code == 200 else {
                    throw ZaiAPIStatusError(success: response.success, code: response.code, msg: response.msg)
                }
                return apiSnapshot(response, fetchedAt: fetchedAt)
            } catch let error as UsageHTTPError where error == .unauthorized {
                rejectedUnauthorized = true  // tenta a próxima credencial, se houver
            }
            // Demais erros (rede, http != 401/403, decode de shape novo,
            // ZaiAPIStatusError): rethrow — backoff do scheduler; último
            // snapshot bom permanece (nunca dado errado).
        }
        return degraded(authState: rejectedUnauthorized ? .invalid : .missing, fetchedAt: fetchedAt)
    }

    // MARK: - Snapshots

    private func apiSnapshot(_ r: ZaiQuotaResponse, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .zai,
            account: account,  // spec §2.4: `.zai/local` enquanto houver uma só credencial
            windows: r.limits.compactMap(Self.mapWindow),
            credits: nil,  // CREDIT_LIMIT é janela de plano, não saldo USD (spec §2.4)
            fetchedAt: fetchedAt,
            source: .api,
            authState: .ok
        )
    }

    /// Snapshot degradado (spec §2.6: "snapshot vazio"): Z.ai não tem ingest
    /// local, então sem API não há dado nenhum — janelas vazias e fonte
    /// `.localOnly`; a UI não desenha linha de janela pra ele.
    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .zai,
            account: account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState
        )
    }

    // MARK: - Mapeamento de janelas (decisões F2 da Task 5)

    /// Classificação tolerante do `type`: o plugin histórico usa
    /// `TOKENS_LIMIT`/`TIME_LIMIT`/`CREDIT_LIMIT` (spec §2.3); o radical basta
    /// (aceita forma curta). Type novo → `unknown` — NÃO descartamos (spec §2.3
    /// descartava): vira janela `.daily` com label cru, exibindo o percentual
    /// real que a API mandou sob o rótulo honesto de que não o reconhecemos.
    static func classify(_ rawType: String?) -> ZaiLimitKind {
        guard let rawType, !rawType.isEmpty else { return .unknown }
        let upper = rawType.uppercased()
        if upper.contains("TOKENS") { return .tokens }
        if upper.contains("TIME") { return .time }
        if upper.contains("CREDIT") { return .credit }
        return .unknown
    }

    /// kind por tipo com refinamento por unidade: `unit` 6 (semana) →
    /// `.weekly`; TOKENS → `.session`; TIME/CREDIT/desconhecido → `.daily`.
    static func windowKind(_ kind: ZaiLimitKind, unit: Int64?) -> WindowKind {
        if kind == .unknown { return .daily }
        if unit == 6 { return .weekly }
        return kind == .tokens ? .session : .daily
    }

    /// Label por janela. Exceção semântica da spec §2.3: `TIME` com `unit=5,
    /// number=1` é o marcador MENSAL MCP (janela de 30 dias), não "1 minuto" →
    /// label "MCP". Tipos/unidades desconhecidos → label cru (debugável, nunca
    /// dado inventado).
    static func windowLabel(_ kind: ZaiLimitKind, rawType: String?, unit: Int64?, number: Double?) -> String {
        if kind == .time, unit == 5, number == 1 { return "MCP" }
        // Int(Double) trapa fora do range de Int (Red Team T8 P1: `number:
        // 1e300` de payload hostil/bugado) — satura ANTES de converter.
        let count = number.map { n -> Int in
            guard n.isFinite else { return 1 }
            return max(1, Int(min(max(n.rounded(), 0), 100_000)))
        } ?? 1
        switch unit {
        case 3: return "\(count)h"
        case 1: return "\(count)d"
        case 5: return "\(count)min"
        case 6: return "Semanal"
        default: break
        }
        let base = (rawType?.isEmpty == false) ? rawType! : "limite"
        return unit == nil ? base : "\(base) u\(unit!)"
    }

    /// `percentage` 0–100 → fração 0...1 (saturada); `nextResetTime` epoch em
    /// MS → `Date` (÷1000). Item sem `percentage` não vira janela (brief:
    /// "para cada limit com percentage").
    static func mapWindow(_ limit: ZaiLimit) -> UsageWindow? {
        guard let percentage = limit.percentage else { return nil }
        let kind = classify(limit.rawType)
        return UsageWindow(
            kind: windowKind(kind, unit: limit.unit),
            usedFraction: min(max(percentage / 100, 0), 1),
            resetsAt: limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000.0) },
            label: windowLabel(kind, rawType: limit.rawType, unit: limit.unit, number: limit.number)
        )
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw ZaiProviderError(account: account.id)
        }
    }
}

/// Radical de `type` reconhecido (ver `ZaiProvider.classify`).
enum ZaiLimitKind: Equatable, Sendable {
    case tokens, time, credit, unknown
}
