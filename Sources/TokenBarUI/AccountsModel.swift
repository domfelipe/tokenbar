import Foundation
import Observation
import TokenBarCore

/// Estado do gerenciamento de contas (F4) para a UI: lista por provider +
/// wrappers das operações do `AccountRegistry`. Toda mutação recarrega a lista
/// e avisa o callback de pós-mutação (o coordinator refresca o ciclo para o
/// painel refletir na hora). `registry == nil` (sem DB) = nada é operável —
/// a view esconde os controles (honesto: sem banco não há registro).
@MainActor
@Observable
public final class AccountsModel {
    /// Providers com suporte a multi-conta (capabilities `.multiAccount`) —
    /// provider sem suporte → controles ocultos (plan T3).
    public let multiAccountProviders: Set<ProviderID>
    public private(set) var accountsByProvider: [ProviderID: [RegisteredAccount]] = [:]
    public let registry: AccountRegistry?
    /// Rodado após cada mutação bem-sucedida (o app injeta um refresh).
    public var onMutation: (() -> Void)?

    public init(registry: AccountRegistry?, multiAccountProviders: Set<ProviderID>) {
        self.registry = registry
        self.multiAccountProviders = multiAccountProviders
        reload()
    }

    /// Re-carrega a lista do registry (abertura do painel, pós-mutação).
    public func reload() {
        guard let registry else {
            accountsByProvider = [:]
            return
        }
        var result: [ProviderID: [RegisteredAccount]] = [:]
        for id in multiAccountProviders {
            result[id] = (try? registry.accounts(provider: id)) ?? []
        }
        accountsByProvider = result
    }

    /// Contas do provider (lista de gerenciamento — ativas e inativas).
    public func accounts(for id: ProviderID) -> [RegisteredAccount] {
        accountsByProvider[id] ?? []
    }

    public func supportsMultiAccount(_ id: ProviderID) -> Bool {
        multiAccountProviders.contains(id)
    }

    @discardableResult
    public func add(
        provider: ProviderID, label: String, credentialPath: String, directoryPath: String
    ) throws -> RegisteredAccount {
        guard let registry else { throw AccountRegistryError.emptyCredentialPath }
        let account = try registry.add(
            provider: provider, label: label, credentialPath: credentialPath,
            directoryPath: directoryPath)
        reload()
        onMutation?()
        return account
    }

    public func remove(_ account: RegisteredAccount) {
        guard let registry else { return }
        try? registry.remove(provider: account.provider, accountKey: account.accountKey)
        reload()
        onMutation?()
    }

    public func setActive(_ active: Bool, account: RegisteredAccount) {
        guard let registry else { return }
        try? registry.setActive(active, provider: account.provider, accountKey: account.accountKey)
        reload()
        onMutation?()
    }
}

/// Validação do formulário de add-account (F4) — PURA e headless (testável
/// sem UI). Duas camadas, honestas:
/// - `blocking`: label/path vazios → o botão Add não habilita (o registry
///   rejeitaria com o mesmo erro).
/// - `warnings`: path inexistente → a conta PODE ser criada (o ciclo degrada
///   com badge de erro — cadastro antes do arquivo existir é legítimo), mas o
///   form avisa na hora.
public enum AddAccountForm {
    public struct Validation: Equatable, Sendable {
        public var blocking: [String]
        public var warnings: [String]

        public var isAddable: Bool { blocking.isEmpty }

        public init(blocking: [String] = [], warnings: [String] = []) {
            self.blocking = blocking
            self.warnings = warnings
        }
    }

    /// Campos trimmed como o registry faz — a validação da UI não pode divergir.
    public static func validate(
        label: String, credentialPath: String, directoryPath: String
    ) -> Validation {
        var result = Validation()
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCredential = credentialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLabel.isEmpty { result.blocking.append("Label is required.") }
        if trimmedCredential.isEmpty {
            result.blocking.append("Credential file is required.")
        } else if !FileManager.default.fileExists(atPath: trimmedCredential) {
            result.warnings.append("Credential file does not exist yet — the account will show an error badge until it does.")
        }
        if !trimmedDirectory.isEmpty,
           !FileManager.default.fileExists(atPath: trimmedDirectory) {
            result.warnings.append("Data directory does not exist yet.")
        }
        return result
    }
}
