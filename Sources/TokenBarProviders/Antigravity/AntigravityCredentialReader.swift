import Foundation
import TokenBarCore

/// Credencial OAuth do Antigravity — mesmo shape do `oauth_creds.json` da
/// referência MIT (`AntigravityOAuthCredentialsStore`): `access_token`
/// (alias camel), `project_id` opcional, `expiry_date` opcional (epoch s/ms
/// ou ISO). Mantida em memória, nunca logada.
public struct AntigravityCredential: Sendable, Equatable {
    public let accessToken: String
    public let projectID: String?
    public let expiresAt: Date?
}

/// Leitor read-only das credenciais Antigravity. Auto-descoberta no MESMO
/// caminho da referência (`~/.codexbar/antigravity/oauth_creds.json`); contas
/// registradas apontam o arquivo. `~/.gemini/antigravity-*` NÃO existe na
/// referência — nada inventado. Nunca loga.
///
/// Overrides de testes/wiring:
/// - env `TOKENBAR_ANTIGRAVITY_CREDS` → caminho do `oauth_creds.json`.
/// - Conta registrada: o path do próprio registro.
public struct AntigravityCredentialReader: Sendable {
    public let credentialsFileURL: URL?

    public init(credentialsFileURL: URL?) {
        self.credentialsFileURL = credentialsFileURL
    }

    public static func resolve(environment: [String: String], home: URL) -> AntigravityCredentialReader {
        let url: URL
        if let raw = environment["TOKENBAR_ANTIGRAVITY_CREDS"], !raw.isEmpty {
            url = URL(filePath: raw)
        } else {
            url = home.appendingPathComponent(".codexbar/antigravity/oauth_creds.json")
        }
        return AntigravityCredentialReader(credentialsFileURL: url)
    }

    public static func resolve() -> AntigravityCredentialReader {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            home: URL(filePath: NSHomeDirectory()))
    }

    /// Guard Red Team F4: só REGULAR file. JSON inválido/sem token → `nil`.
    /// Token VENCIDO continua legível (o provider decide: `.invalid` sem
    /// request — não há refresh read-only).
    public func read() -> AntigravityCredential? {
        guard let credentialsFileURL,
              FileKind.isRegularFile(atPath: credentialsFileURL.path),
              let data = try? Data(contentsOf: credentialsFileURL)
        else { return nil }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> AntigravityCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawToken = (object["access_token"] as? String) ?? (object["accessToken"] as? String)
        guard let trimmedToken = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedToken.isEmpty
        else { return nil }
        let project = ((object["project_id"] as? String) ?? (object["projectId"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var expiresAt: Date?
        let expiryRaw = (object["expiry_date"] as? Double) ?? (object["expiresAt"] as? Double)
        if let epoch = expiryRaw, epoch.isFinite, epoch > 0 {
            expiresAt = Date(timeIntervalSince1970: epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch)
        } else if let iso = object["expiry_date"] as? String {
            expiresAt = UsageDates.iso8601(iso)
        }
        return AntigravityCredential(
            accessToken: trimmedToken,
            projectID: (project?.isEmpty ?? true) ? nil : project,
            expiresAt: expiresAt)
    }
}

/// Conta solicitada não é a conta que esta instância atende.
public struct AntigravityProviderError: Error, Sendable, Equatable {
    public let account: AccountID

    public init(account: AccountID) {
        self.account = account
    }
}

/// Payload sem nenhum `remainingFraction` utilizável — erro tipado (rethrow →
/// backoff; nunca vira dado no snapshot).
public struct AntigravityAPIError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Provider do Antigravity (Google IDE), F5 Task 5 — API-only.
///
/// Fonte MIT: `Sources/CodexBarCore/Providers/Antigravity/AntigravityRemoteUsageFetcher.swift`
/// (endpoint `fetchAvailableModels` + parse `AntigravityRemoteModel`).
///
/// - `fetchUsage`: access token do `oauth_creds.json` → `POST
///   https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
///   (read-only; corpo `{}` ou `{"project": id}`) → janelas por modelo com
///   `quotaInfo.remainingFraction`. Token vencido → `.invalid` SEM request
///   (não há refresh: exigiria client OAuth do IDE — fora de escopo
///   read-only).
/// - Sem credencial: `discoverAccounts() == []` e snapshot vazio `.missing`
///   (provider entra DESABILITADO na prática até registrar conta — degradação
///   honesta da Task 5).
/// - Menu: `V:<pior modelo>%` — o wiring escolhe a janela crítica.
public final class AntigravityProvider: Sendable, UsageProvider {
    public static let defaultBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    public static let modelsEndpoint = "v1internal:fetchAvailableModels"
    public static let userAgent = "antigravity"

    public var account: AccountID { AccountID(provider: .antigravity, key: accountKey) }
    public var accountRef: AccountRef { AccountRef(id: account, label: accountKey == "local" ? "local" : label) }

    public let accountKey: String
    private let label: String
    private let accounts: AccountRegistry?

    private let credentialReader: AntigravityCredentialReader
    private let client: UsageHTTPClient

    public init(
        credentialReader: AntigravityCredentialReader,
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

    public var id: ProviderID { .antigravity }

    public var capabilities: ProviderCapabilities { [.apiUsage, .multiAccount] }

    public func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch {
        try guardKnownAccount(account)
        return IngestBatch(events: [], eventsApplied: 0, providerTotals: [:], nextCursor: cursor)
    }

    public func discoverAccounts() async -> [AccountRef] {
        var refs: [AccountRef] = credentialReader.read() != nil ? [accountRef] : []
        guard let accounts else { return refs }
        let registered = (try? accounts.activeAccounts(provider: .antigravity)) ?? []
        for entry in registered where !refs.contains(where: { $0.id.key == entry.accountKey }) {
            refs.append(AccountRef(id: AccountID(provider: .antigravity, key: entry.accountKey), label: entry.label))
        }
        return refs
    }

    public func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot {
        try guardKnownAccount(account)
        let fetchedAt = Date()
        guard let credential = credentialReader.read() else {
            return degraded(authState: .missing, fetchedAt: fetchedAt)
        }
        // Token vencido → sem request (não há refresh read-only; relogin no
        // IDE resolve). 60 s de folga, padrão `isUsable` da referência.
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSinceNow <= 60 {
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }

        var bodyObject: [String: Any] = [:]
        if let projectID = credential.projectID {
            bodyObject["project"] = projectID
        }
        let body = (try? JSONSerialization.data(withJSONObject: bodyObject)) ?? Data("{}".utf8)

        do {
            let data = try await client.postJSON(
                url: client.baseURL.appending(path: Self.modelsEndpoint),
                bearer: credential.accessToken,
                headers: ["User-Agent": Self.userAgent],
                body: body)
            let response = try JSONDecoder().decode(AntigravityModelsResponse.self, from: data)
            let windows = Self.mapWindows(response)
            guard !windows.isEmpty else {
                throw AntigravityAPIError("no model quota fractions in payload")
            }
            return UsageSnapshot(
                provider: .antigravity,
                account: self.account,
                windows: windows,
                credits: nil,
                fetchedAt: fetchedAt,
                source: .api,
                authState: .ok)
        } catch let error as UsageHTTPError where error == .unauthorized {
            return degraded(authState: .invalid, fetchedAt: fetchedAt)
        }
        // Demais erros (rede, http != 401/403, decode, AntigravityAPIError): rethrow.
    }

    // MARK: - Decoders

    struct AntigravityModelsResponse: Decodable, Sendable {
        let models: [String: RemoteModel]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            models = FlexibleJSON.optional([String: RemoteModel].self, c, "models")
        }
    }

    struct RemoteModel: Decodable, Sendable {
        let displayName: String?
        let label: String?
        let quotaInfo: QuotaInfo?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            displayName = FlexibleJSON.string(c, "displayName")
            label = FlexibleJSON.string(c, "label")
            quotaInfo = FlexibleJSON.optional(QuotaInfo.self, c, "quotaInfo")
        }
    }

    struct QuotaInfo: Decodable, Sendable {
        let remainingFraction: Double?
        let resetTime: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            remainingFraction = FlexibleJSON.double(c, "remainingFraction", "remaining_fraction")
            resetTime = FlexibleJSON.string(c, "resetTime", "reset_time")
        }
    }

    /// Uma janela por modelo com fração utilizável (referência `parseModelQuotas`):
    /// fração = 1 − remainingFraction; label = displayName → label → modelId;
    /// resetsAt = ISO8601. Ordenada por label (determinismo p/ UI/testes).
    static func mapWindows(_ response: AntigravityModelsResponse) -> [UsageWindow] {
        let models = response.models ?? [:]
        var entries: [(String, UsageWindow)] = []
        for (modelID, model) in models {
            guard let remaining = model.quotaInfo?.remainingFraction, remaining.isFinite else { continue }
            let candidates: [String?] = [model.displayName, model.label]
            let label = candidates.compactMap { candidate -> String? in
                guard let candidate, !candidate.isEmpty else { return nil }
                return candidate
            }.first ?? modelID
            entries.append((label, UsageWindow(
                kind: .daily,
                usedFraction: min(max(1 - remaining, 0), 1),
                resetsAt: UsageDates.iso8601(model.quotaInfo?.resetTime),
                label: label)))
        }
        return entries.sorted(by: { $0.0 < $1.0 }).map(\.1)
    }

    private func degraded(authState: AuthState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .antigravity,
            account: self.account,
            windows: [],
            credits: nil,
            fetchedAt: fetchedAt,
            source: .localOnly,
            authState: authState)
    }

    private func guardKnownAccount(_ account: AccountRef) throws {
        guard account.id == self.account else {
            throw AntigravityProviderError(account: account.id)
        }
    }
}
