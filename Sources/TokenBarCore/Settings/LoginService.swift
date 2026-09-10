import Foundation

/// Estado do item de login (launch at login) abstraído do SMAppService para
/// a janela de Settings (Task 3) usar uma implementação INJETÁVEL — testes
/// NUNCA tocam no SMAppService real (que gravaria estado do sistema).
public enum LoginItemStatus: Sendable, Equatable {
    /// Registrado e aprovado — vai abrir no login.
    case enabled
    /// Não registrado.
    case notRegistered
    /// Registrado mas aguardando aprovação do usuário (System Settings ›
    /// General › Login Items). HONESTO: tratamos como "não ativo" na UI, com
    /// aviso — prometer que está ativo seria mentira.
    case requiresApproval
    /// App não encontrado pelo serviço (bundle sem assinatura/caminho esquisito
    /// em build local) — tratado como não ativo.
    case notFound
}

/// Fronteira do launch at login (F5 Task 3). A implementação real fala com
/// `SMAppService.mainApp` (macOS 13+); erros de register/unregister SUBEM —
/// quem exibe é a Settings (aviso honesto, nunca crash).
public protocol LoginServiceManaging: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}
