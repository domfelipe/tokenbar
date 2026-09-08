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

    // MARK: - Guard de overlap (review T3, Important)

    /// Fixture real com dir canônica, dir irmã e symlink → canônica.
    @Test("validação: diretório sobreposto a raiz em uso é BLOQUEADO; irmão passa")
    func validationBlocksOverlappingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlap-\(UUID().uuidString)", isDirectory: true)
        let canonical = root.appendingPathComponent("canon", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        for dir in [canonical, sibling] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let link = root.appendingPathComponent("link-to-canon")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: canonical.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let roots = [canonical.path]
        let credential = sibling.path  // existe → sem warning de credencial

        func validate(directory: String) -> AddAccountForm.Validation {
            AddAccountForm.validate(
                label: "Work", credentialPath: credential,
                directoryPath: directory, existingScanRoots: roots)
        }

        // Igual → bloqueado.
        var result = validate(directory: canonical.path)
        #expect(!result.isAddable)
        #expect(result.blocking.contains("Directory overlaps an existing account's scan root."))

        // Contida na raiz (subdir) → bloqueado.
        result = validate(directory: canonical.appendingPathComponent("sub").path)
        #expect(!result.isAddable)

        // Contendo a raiz (pai) → bloqueado.
        result = validate(directory: root.path)
        #expect(!result.isAddable)

        // Symlink resolvendo pro mesmo dir → bloqueado.
        result = validate(directory: link.path)
        #expect(!result.isAddable, "symlink para a canônica é o mesmo scan root")

        // Irmão não-sobreposto → passa limpo.
        let ok = validate(directory: sibling.path)
        #expect(ok.isAddable)
        #expect(ok.blocking.isEmpty && ok.warnings.isEmpty)

        // Dir inexistente SEM overlap → segue sendo só aviso (nunca bloqueio).
        let missing = validate(directory: root.appendingPathComponent("futura").path)
        #expect(missing.isAddable)
        #expect(missing.warnings.count == 1)
    }

    @Test("model: raízes em uso = canônica + registradas; guard pina overlap por provider")
    func modelScanRootsAndOverlapGuard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlap-model-\(UUID().uuidString)", isDirectory: true)
        let canonical = root.appendingPathComponent("canon", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        for dir in [canonical, work, sibling] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try makeDatabase()
        let registry = AccountRegistry(database: db)
        let model = AccountsModel(
            registry: registry,
            multiAccountProviders: [.claude, .zai],
            canonicalRoots: [.claude: canonical.path])

        // Só a canônica em uso antes de qualquer registro.
        #expect(model.existingScanRoots(provider: .claude) == [canonical.path])

        // Guard: igual/contida → overlap; irmã → não.
        #expect(model.directoryOverlaps(provider: .claude, directoryPath: canonical.path))
        #expect(model.directoryOverlaps(provider: .claude, directoryPath: canonical.appendingPathComponent("sub").path))
        #expect(!model.directoryOverlaps(provider: .claude, directoryPath: sibling.path))

        // Conta registrada com dir própria entra nas raízes em uso.
        let account = try model.add(
            provider: .claude, label: "Work",
            credentialPath: sibling.path, directoryPath: work.path)
        #expect(Set(model.existingScanRoots(provider: .claude)) == Set([canonical.path, work.path]))
        #expect(model.directoryOverlaps(provider: .claude, directoryPath: work.path),
                "dir de outra conta registrada também é raiz em uso")

        // Provider diferente: mesma dir NÃO é overlap (queries são por provider).
        #expect(!model.directoryOverlaps(provider: .zai, directoryPath: canonical.path))

        // Remoção devolve a raiz ao estado livre.
        model.remove(account)
        #expect(!model.directoryOverlaps(provider: .claude, directoryPath: work.path))
    }
}
