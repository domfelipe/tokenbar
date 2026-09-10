import Foundation
import TokenBarCore
import UserNotifications

/// Estado de autorização de notificação, abstraido do UNUserNotificationCenter
/// para o gateway ser injetável (testes NUNCA tocam o centro real — plano T2).
public enum NotificationAuthorizationState: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

/// Fronteira de entrega de notificações (F5 T2, spec §8). O coordinator
/// despacha `AlertEvent`s por aqui; a implementação real fala com o
/// UNUserNotificationCenter.
///
/// RULING F5-NOTIF: `requestAuthorization()` é chamado EXPLICITAMENTE pela
/// janela de Settings (Task 3) quando o usuário ativa alertas — NUNCA no
/// launch, NUNCA no init do coordinator. Sem permissão, `deliver` é no-op
/// (o estado real aparece na UI — honesto, sem prompt escondido).
public protocol NotificationSending: Sendable {
    /// Pede permissão ao sistema. `true` = concedida. Só Settings chama.
    func requestAuthorization() async -> Bool
    /// Estado atual da autorização (para o estado honesto no painel).
    func authorizationState() async -> NotificationAuthorizationState
    /// Entrega um alerta. Sem autorização → no-op silencioso.
    func deliver(_ event: AlertEvent) async
}

/// Implementação real sobre `UNUserNotificationCenter`.
public struct UserNotificationGateway: NotificationSending {
    public init() {}

    public func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        default:
            return .notDetermined
        }
    }

    public func deliver(_ event: AlertEvent) async {
        guard await authorizationState() == .granted else { return }
        let content = UNMutableNotificationContent()
        let rendered = Self.render(event)
        content.title = rendered.title
        content.body = rendered.body
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: event), content: content, trigger: nil)
        // Erro de entrega (sem permissão de última hora etc.) → ignorado:
        // notificação é aditiva, nunca condição de crash.
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Identificador estável por (provider, conta, janela, causa): substitui
    /// o banner anterior da mesma causa em vez de empilhar.
    static func identifier(for event: AlertEvent) -> String {
        let cause = event.thresholdPct.map { "t\($0)" } ?? "reminder"
        return "tokenbar.alert.\(event.provider.rawValue).\(event.account.key).\(event.windowKind.rawValue).\(cause)"
    }

    // MARK: - Renderização EN (strings de UI vivem na UI, não no Core)

    /// Nomes de exibição dos providers (D5; EN — padrão do painel).
    static func providerName(_ id: ProviderID) -> String {
        switch id {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .zai: return "Z.ai"
        case .cursor: return "Cursor"
        case .openrouter: return "OpenRouter"
        case .copilot: return "Copilot"
        }
    }

    /// Threshold: título "Claude · 90% of weekly window used"; lembrete:
    /// "Claude · weekly window resets soon". Body com countdown do reset
    /// ("Resets in 2h 15m") ou "Reset time unknown" — nunca inventado.
    public static func render(_ event: AlertEvent) -> (title: String, body: String) {
        let name = providerName(event.provider)
        let countdown: String
        if let resetsAt = event.resetsAt {
            let text = ProviderPanelModel.countdownText(from: event.firedAt, to: resetsAt)
            countdown = text == "renewed" ? "Reset time unknown" : "Resets in " + text
        } else {
            countdown = "Reset time unknown"
        }
        switch event.kind {
        case .threshold:
            let threshold = event.thresholdPct ?? 0
            return (
                "\(name) · \(threshold)% of \(event.windowKind.rawValue) window used",
                countdown
            )
        case .resetReminder:
            return ("\(name) · \(event.windowKind.rawValue) window resets soon", countdown)
        }
    }
}
