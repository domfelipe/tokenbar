import Foundation
import GRDB

/// Conta registrada pelo usuário (F4 multi-conta) — linha da tabela `accounts`
/// (spec §6 + migration v2). `accountKey` é a `account_id` canônica no
/// ledger/DB/cursor (`<provider>:<key>`); `credentialPath` é lido READ-ONLY
/// pelo provider no ciclo (nunca escrito, nunca logado — spec §9);
/// `directoryPath` vazio = conta API-only (sem ingest local própria).
public struct RegisteredAccount: Sendable, Equatable, Identifiable {
    public let provider: ProviderID
    public let accountKey: String
    public let label: String
    /// "oauth" | "apikey" (comentário do schema §6). Sem comportamento na F4 —
    /// a resolução de credencial é responsabilidade do provider no ciclo.
    public let kind: String
    public let active: Bool
    public let credentialPath: String
    public let directoryPath: String

    public var id: String { "\(provider.rawValue):\(accountKey)" }

    public init(
        provider: ProviderID, accountKey: String, label: String, kind: String,
        active: Bool, credentialPath: String, directoryPath: String
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.label = label
        self.kind = kind
        self.active = active
        self.credentialPath = credentialPath
        self.directoryPath = directoryPath
    }
}

/// Erros de validação do registry — tipados (a UI mostra mensagem própria;
/// nunca crasha nem inventa conta).
public enum AccountRegistryError: Error, Equatable, Sendable {
    case emptyLabel
    case emptyCredentialPath
}

/// CRUD do registry multi-conta (F4) sobre a tabela `accounts`. Fonte da
/// verdade da UI ("+ Add account", toggle ativo, remover) e da descoberta
/// MERGE dos providers (contas registradas + auto-descoberta, dedupe por key).
///
/// Threading: `AppDatabase` é Sendable (DatabasePool serializa escritas);
/// métodos síncronos não-isolados — o chamador roda fora da MainActor quando
/// em hot path (o coordinator consulta 1×/ciclo; a UI sob demanda).
public final class AccountRegistry: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Todas as contas (ativas e inativas) de um provider — a lista do painel
    /// de gerenciamento. Ordenação estável por label (UI determinística).
    public func accounts(provider: ProviderID) throws -> [RegisteredAccount] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT provider, account_id, label, kind, active, credential_path, directory_path
                    FROM accounts WHERE provider = ? ORDER BY label, account_id
                    """,
                arguments: [provider.rawValue])
            return rows.map(Self.account(from:))
        }
    }

    /// Só as ativas — o conjunto que o ciclo itera (1 leitura indexada/ciclo).
    public func activeAccounts(provider: ProviderID) throws -> [RegisteredAccount] {
        try accounts(provider: provider).filter(\.active)
    }

    /// Registra uma conta. Validação ANTES do INSERT: label e credential path
    /// não podem ser vazios (trimmed — espaço em branco não é valor). O path
    /// INEXISTENTE é aceito: a conta entra, degrada no ciclo e ganha badge de
    /// erro na linha (o usuário pode registrar antes de o arquivo existir).
    /// A `account_id` é gerada aqui (UUID) — estável, única por provider.
    @discardableResult
    public func add(
        provider: ProviderID, label: String, credentialPath: String,
        kind: String = "oauth", directoryPath: String = ""
    ) throws -> RegisteredAccount {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = credentialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { throw AccountRegistryError.emptyLabel }
        guard !trimmedPath.isEmpty else { throw AccountRegistryError.emptyCredentialPath }
        let account = RegisteredAccount(
            provider: provider,
            accountKey: "acct-" + UUID().uuidString.prefix(8).lowercased(),
            label: trimmedLabel,
            kind: kind,
            active: true,
            credentialPath: trimmedPath,
            directoryPath: directoryPath.trimmingCharacters(in: .whitespacesAndNewlines))
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (provider, account_id, label, kind, active, credential_path, directory_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    account.provider.rawValue, account.accountKey, account.label,
                    account.kind, account.active ? 1 : 0,
                    account.credentialPath, account.directoryPath,
                ])
        }
        return account
    }

    /// Remove a conta. Idempotente: remover chave inexistente é no-op (a UI
    /// pode repetir o pedido sem erro).
    public func remove(provider: ProviderID, accountKey: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM accounts WHERE provider = ? AND account_id = ?",
                arguments: [provider.rawValue, accountKey])
        }
    }

    /// Toggle "ativa" do painel: inativa para de ser ciclagem imediatamente
    /// (próximo ciclo não itera); o registro permanece para reativação.
    public func setActive(_ active: Bool, provider: ProviderID, accountKey: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE accounts SET active = ? WHERE provider = ? AND account_id = ?",
                arguments: [active ? 1 : 0, provider.rawValue, accountKey])
        }
    }

    static func account(from row: Row) -> RegisteredAccount {
        RegisteredAccount(
            provider: ProviderID(rawValue: row["provider"]) ?? .claude,
            accountKey: row["account_id"],
            label: row["label"],
            kind: row["kind"],
            active: (row["active"] as Int?) == 1,
            credentialPath: row["credential_path"],
            directoryPath: row["directory_path"])
    }
}
