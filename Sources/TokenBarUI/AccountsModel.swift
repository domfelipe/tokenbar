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
    /// Raiz de scan CANÔNICA por provider (conta default, resolvida no
    /// wiring do coordinator) — insumo do guard de overlap do registro.
    public let canonicalRoots: [ProviderID: String]
    /// Rodado após cada mutação bem-sucedida (o app injeta um refresh).
    public var onMutation: (() -> Void)?

    public init(
        registry: AccountRegistry?,
        multiAccountProviders: Set<ProviderID>,
        canonicalRoots: [ProviderID: String] = [:]
    ) {
        self.registry = registry
        self.multiAccountProviders = multiAccountProviders
        self.canonicalRoots = canonicalRoots
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

    /// Raízes de scan EM USO pelo provider: a canônica + as dirs das contas
    /// registradas. Fonte do guard de overlap do formulário.
    public func existingScanRoots(provider: ProviderID) -> [String] {
        var roots: [String] = []
        if let canonical = canonicalRoots[provider], !canonical.isEmpty {
            roots.append(canonical)
        }
        for account in accounts(for: provider) where !account.directoryPath.isEmpty {
            roots.append(account.directoryPath)
        }
        return roots
    }

    /// Guard de overlap (review T3, Important): dir candidata sobrepondo uma
    /// raiz em uso é registro BLOQUEADO — dois scans sobre o mesmo arquivo
    /// dobram o agregado E o histórico provider-wide de forma PERSISTENTE
    /// (daily_agg não é limpo pela remoção da conta; o namespace de hwm por
    /// conta garante NÃO-colisão, justamente o que permitiria a duplicação).
    public func directoryOverlaps(provider: ProviderID, directoryPath: String) -> Bool {
        existingScanRoots(provider: provider)
            .contains { AddAccountForm.scanRootsOverlap(directoryPath, $0) }
    }

    @discardableResult
    public func add(
        provider: ProviderID, label: String, credentialPath: String, directoryPath: String
    ) throws -> RegisteredAccount {
        guard let registry else { throw AccountRegistryError.emptyCredentialPath }
        // Defesa em profundidade (Red Team F4 caso 5): o guard de overlap é da
        // UI/formulário, mas TODO add que passa pelo app valida de novo aqui —
        // dir sobreposta dobraria o agregado e o histórico provider-wide de
        // forma PERSISTENTE. O registry puro (Core) segue sem o guard por não
        // conhecer as raízes canônicas — documentado no decisoes-f4.
        if directoryOverlaps(provider: provider, directoryPath: directoryPath) {
            throw AccountsModelError.directoryOverlaps
        }
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

/// Erro de operação de conta bloqueada na camada de app (F4): o overlap é
/// validado no `AccountsModel.add` (defesa em profundidade além do form).
public enum AccountsModelError: Error, Equatable, Sendable {
    case directoryOverlaps
}

/// Validação do formulário de add-account (F4) — PURA e headless (testável
/// sem UI). Duas camadas, honestas:
/// - `blocking`: label/path vazios e diretório sobreposto a uma raiz de scan
///   em uso → o botão Add não habilita.
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
        label: String, credentialPath: String, directoryPath: String,
        existingScanRoots: [String] = []
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
        } else if !FileKind.isRegularFile(atPath: trimmedCredential) {
            // Red Team F4 caso 4: FIFO/device não são credencial legível — o
            // reader degrada nil; avisa na hora em vez de badge silencioso.
            result.warnings.append("Credential path is not a regular file — the account will not be able to read it.")
        }
        if !trimmedDirectory.isEmpty {
            // Overlap BLOQUEIA (não é warning): dirs sobrepostas dobram o
            // histórico provider-wide de forma persistente (review T3).
            let overlaps = existingScanRoots.contains {
                scanRootsOverlap(trimmedDirectory, $0)
            }
            if overlaps {
                result.blocking.append("Directory overlaps an existing account's scan root.")
            } else if !FileManager.default.fileExists(atPath: trimmedDirectory) {
                result.warnings.append("Data directory does not exist yet.")
            }
        }
        return result
    }

    /// Overlap de raízes de scan: igualdade ou contenção em qualquer sentido,
    /// com symlinks RESOLVIDOS nos dois lados (um link apontando pro mesmo dir
    /// é o mesmo scan root). Paths inexistentes resolvem o prefixo existente —
    /// o guard vale também para dirs ainda não criadas.
    public static func scanRootsOverlap(_ a: String, _ b: String) -> Bool {
        let ra = normalized(a)
        let rb = normalized(b)
        guard !ra.isEmpty, !rb.isEmpty else { return false }
        return ra == rb || ra.hasPrefix(rb + "/") || rb.hasPrefix(ra + "/")
    }

    private static func normalized(_ path: String) -> String {
        // NSString.expandingTildeInPath-style API: a variante String
        // (`resolvingSymlinksInPath`) não está disponível neste toolchain.
        var resolved = (path as NSString).resolvingSymlinksInPath
        while resolved.count > 1, resolved.hasSuffix("/") {
            resolved.removeLast()
        }
        return resolved
    }
}
