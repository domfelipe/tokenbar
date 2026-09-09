import Foundation
import Testing
import GRDB
import TokenBarCore

/// F4 Task 3 — registry multi-conta: CRUD na tabela `accounts` (schema §6 +
/// migration v2 com credential_path/directory_path), validação, toggle ativa,
/// isolamento por provider e persistência entre aberturas.
@Suite
final class AccountRegistryTests {
    let dir: URL

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("accountregistry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeDatabase() throws -> AppDatabase {
        try AppDatabase.open(at: dir.appendingPathComponent("db-\(UUID().uuidString).sqlite"), calendar: calendar)
    }

    @Test("migration v2: colunas credential_path/directory_path existem")
    func migrationV2AddsColumns() throws {
        let url = dir.appendingPathComponent("schema-\(UUID().uuidString).sqlite")
        _ = try AppDatabase.open(at: url, calendar: calendar)
        let pool = try DatabasePool(path: url.path)
        let names = try pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(accounts)").map { $0["name"] as String }
        }
        #expect(Set(names).isSuperset(of: ["provider", "account_id", "label", "kind", "active"]))
        #expect(names.contains("credential_path"))
        #expect(names.contains("directory_path"))
    }

    @Test("add + list: persiste com key gerada e ativa por default")
    func addAndListRoundTrip() throws {
        let db = try makeDatabase()
        let registry = AccountRegistry(database: db)
        let account = try registry.add(
            provider: .codex, label: "Work", credentialPath: "/tmp/auth.json")

        #expect(account.accountKey.hasPrefix("acct-"))
        #expect(account.active)
        #expect(account.kind == "oauth")
        #expect(account.credentialPath == "/tmp/auth.json")
        #expect(account.directoryPath.isEmpty)

        let list = try registry.accounts(provider: .codex)
        #expect(list == [account])
        #expect(try registry.activeAccounts(provider: .codex) == [account])
    }

    @Test("validação: label vazio e credential path vazio são rejeitados")
    func validationRejectsEmptyFields() throws {
        let registry = AccountRegistry(database: try makeDatabase())
        #expect(throws: AccountRegistryError.emptyLabel) {
            _ = try registry.add(provider: .claude, label: "   ", credentialPath: "/tmp/a.json")
        }
        #expect(throws: AccountRegistryError.emptyCredentialPath) {
            _ = try registry.add(provider: .claude, label: "X", credentialPath: "  ")
        }
        #expect(try registry.accounts(provider: .claude).isEmpty, "nada foi gravado")
    }

    @Test("trim: label e paths com espaços nas bordas são normalizados")
    func trimsWhitespace() throws {
        let registry = AccountRegistry(database: try makeDatabase())
        let account = try registry.add(
            provider: .claude, label: "  Work  ", credentialPath: " /tmp/a.json ",
            directoryPath: "  /tmp/dir ")
        #expect(account.label == "Work")
        #expect(account.credentialPath == "/tmp/a.json")
        #expect(account.directoryPath == "/tmp/dir")
    }

    @Test("setActive(false) remove das ativas sem apagar o registro; reativa volta")
    func setActiveTogglesVisibility() throws {
        let registry = AccountRegistry(database: try makeDatabase())
        let account = try registry.add(provider: .zai, label: "Second", credentialPath: "/tmp/config.json")

        try registry.setActive(false, provider: .zai, accountKey: account.accountKey)
        // O registro PERMANECE (mesma key/label) com active = 0 no banco.
        let persisted = try registry.accounts(provider: .zai)
        #expect(persisted.map(\.accountKey) == [account.accountKey])
        #expect(persisted.map(\.active) == [false])
        #expect(try registry.activeAccounts(provider: .zai).isEmpty)

        try registry.setActive(true, provider: .zai, accountKey: account.accountKey)
        #expect(try registry.activeAccounts(provider: .zai).count == 1)
    }

    @Test("remove apaga a linha; remover chave inexistente é no-op")
    func removeDeletesAndIsIdempotent() throws {
        let registry = AccountRegistry(database: try makeDatabase())
        let account = try registry.add(provider: .codex, label: "Temp", credentialPath: "/tmp/a.json")

        try registry.remove(provider: .codex, accountKey: "nao-existe")  // no-op
        try registry.remove(provider: .codex, accountKey: account.accountKey)
        #expect(try registry.accounts(provider: .codex).isEmpty)
    }

    @Test("isolamento por provider: contas de claude não aparecem para codex")
    func providersAreIsolated() throws {
        let registry = AccountRegistry(database: try makeDatabase())
        _ = try registry.add(provider: .claude, label: "A", credentialPath: "/tmp/a.json")
        _ = try registry.add(provider: .codex, label: "B", credentialPath: "/tmp/b.json")

        #expect(try registry.accounts(provider: .claude).map(\.label) == ["A"])
        #expect(try registry.accounts(provider: .codex).map(\.label) == ["B"])
        #expect(try registry.accounts(provider: .zai).isEmpty)
    }

    @Test("persistência: reabrir o banco mantém as contas")
    func persistsAcrossReopen() throws {
        let url = dir.appendingPathComponent("reopen-\(UUID().uuidString).sqlite")
        let first = AccountRegistry(database: try AppDatabase.open(at: url, calendar: calendar))
        let account = try first.add(provider: .claude, label: "Durable", credentialPath: "/tmp/d.json")

        let second = AccountRegistry(database: try AppDatabase.open(at: url, calendar: calendar))
        #expect(try second.accounts(provider: .claude) == [account])
    }
}
