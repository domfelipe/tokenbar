import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F4 Task 3 — modelo de UI do gerenciamento de contas + validação pura do
/// formulário (bloqueio por campo vazio; path inexistente é AVISO, não
/// bloqueio — a conta pode nascer degradada e ganhar badge no ciclo).
@MainActor
struct AccountsModelTests {
    private func makeDatabase() throws -> AppDatabase {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("accountsmodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try AppDatabase.open(at: dir.appendingPathComponent("db.sqlite"))
    }

    @Test("model: add/remove/toggle refletem no registry e disparam onMutation")
    func modelOperationsWrapRegistry() throws {
        let db = try makeDatabase()
        let registry = AccountRegistry(database: db)
        let model = AccountsModel(
            registry: registry, multiAccountProviders: [.claude, .codex, .zai])
        var mutations = 0
        model.onMutation = { mutations += 1 }

        #expect(model.supportsMultiAccount(.claude))
        #expect(!model.supportsMultiAccount(.gemini))

        let added = try model.add(
            provider: .claude, label: "Work",
            credentialPath: "/tmp/auth.json", directoryPath: "")
        #expect(mutations == 1)
        #expect(model.accounts(for: .claude).map(\.accountKey) == [added.accountKey])

        model.setActive(false, account: added)
        #expect(mutations == 2)
        #expect(try registry.activeAccounts(provider: .claude).isEmpty)
        #expect(model.accounts(for: .claude).count == 1, "lista de gerenciamento mantém inativa")

        model.remove(added)
        #expect(mutations == 3)
        #expect(model.accounts(for: .claude).isEmpty)
    }

    @Test("model: sem registry (degradação F2) não opera e não crasha")
    func modelWithoutRegistryDegrades() throws {
        let model = AccountsModel(registry: nil, multiAccountProviders: [.claude])
        #expect(model.accounts(for: .claude).isEmpty)
        model.reload()
        model.remove(RegisteredAccount(
            provider: .claude, accountKey: "acct-x", label: "x", kind: "oauth",
            active: true, credentialPath: "/tmp/x", directoryPath: ""))
        #expect(throws: AccountRegistryError.emptyCredentialPath) {
            _ = try model.add(provider: .claude, label: "x", credentialPath: "", directoryPath: "")
        }
    }

    // MARK: - Validação do formulário (pura)

    @Test("validação: vazio bloqueia; existente passa limpo")
    func validationBlocksEmptyFields() {
        var result = AddAccountForm.validate(label: "", credentialPath: "/tmp/a", directoryPath: "")
        #expect(!result.isAddable)
        #expect(result.blocking.contains("Label is required."))

        result = AddAccountForm.validate(label: "W", credentialPath: "   ", directoryPath: "")
        #expect(!result.isAddable)
        #expect(result.blocking.contains("Credential file is required."))

        let ok = AddAccountForm.validate(
            label: "Work",
            credentialPath: FileManager.default.temporaryDirectory.path,
            directoryPath: "")
        #expect(ok.isAddable)
        #expect(ok.warnings.isEmpty)
    }

    @Test("validação: path inexistente é aviso (conta pode nascer degradada)")
    func validationWarnsOnMissingPath() {
        let result = AddAccountForm.validate(
            label: "Broken",
            credentialPath: "/tokenbar/nao/existe-\(UUID().uuidString).json",
            directoryPath: "")
        #expect(result.isAddable, "path inexistente NÃO bloqueia (badge de erro no ciclo)")
        #expect(result.warnings.count == 1)

        let withDir = AddAccountForm.validate(
            label: "Broken",
            credentialPath: "/tokenbar/nao/existe.json",
            directoryPath: "/tokenbar/nao/existe-dir")
        #expect(withDir.warnings.count == 2)
    }
}
