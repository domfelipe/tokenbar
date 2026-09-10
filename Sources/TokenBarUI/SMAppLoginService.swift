import ServiceManagement
import TokenBarCore

/// Implementação REAL do launch at login (F5 Task 3) sobre `SMAppService`
/// (macOS 13+). O estado-fonte é o do SISTEMA — o serviço persiste o
/// registro, então o nosso banco NÃO guarda essa chave (uma verdade só).
/// Erros de register/unregister sobem para a Settings exibir (aviso
/// honesto, nunca crash).
public struct SMAppLoginService: LoginServiceManaging {
    public init() {}

    public func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
