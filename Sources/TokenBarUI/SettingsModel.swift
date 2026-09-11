import Foundation
import Observation
import TokenBarCore

/// Modelo da janela de Settings (F5 Task 3, spec §8) — @Observable puro
/// (headless-testável): a view só renderiza o estado e despacha ações.
///
/// FONTES DA VERDADE:
/// - Intervalos e visibilidade do menu bar: tabela `settings` via
///   `AppSettingsStore` (o modelo persiste; o coordinator aplica no launch
///   e recebe republish da visibilidade para o texto do menu bar mudar na
///   hora — sem restart).
/// - Alertas: `AlertEngine` é o dono da config (`alerts:*`); o modelo lê no
///   init via `AlertEngine.readConfig` (decodificação ÚNICA) e escreve via
///   `apply(config:)`.
/// - Launch at login: o estado-fonte é o SMAppService (serviço do sistema) —
///   NADA é persistido no nosso banco para não haver duas verdades.
///
/// RULING F5-NOTIF: `requestAuthorization()` é chamado EXPLICITAMENTE aqui,
/// só quando o usuário liga o toggle de alertas — nunca no launch/init. Se
/// negada: alerts ficam DESLIGADOS e o aviso honesto aparece na própria
/// janela (o painel reflete `.blocked`/`.disabled` no rodapé, T2).
@MainActor
@Observable
public final class SettingsModel {
    /// Faixa dos thresholds NA UI (o motor aceita 1...100; a janela é mais
    /// conservadora — plan Task 3: "sliders/steppers 10-100").
    public static let thresholdRange = 10...100
    /// Passo dos steppers de threshold (cobre defaults 50/75/90/95).
    public static let thresholdStep = 5
    /// Teto de thresholds (higiene: mais que isso não cabe na janela).
    public static let maxThresholds = 8
    /// Opções do lembrete de reset (minutos antes; `nil` = desligado).
    public static let reminderOptions: [Int?] = [nil, 5, 15, 30]

    // MARK: Estado publicado

    /// Refresh com o painel aberto (foreground; default 60 s, spec §7).
    public private(set) var foregroundRefreshSeconds: Int
    /// Refresh em background/ocioso (default 300 s, spec §7).
    public private(set) var idleRefreshSeconds: Int
    /// Providers presentes no texto do menu bar (Task 3). Default = todos.
    public private(set) var visibleProviders: Set<ProviderID>

    public private(set) var alertsEnabled: Bool
    /// Thresholds em ordem CRESCENTE (invariante mantido por edição).
    public private(set) var thresholds: [Int]
    /// Lembrete N minutos antes do reset; `nil` = desligado.
    public private(set) var resetReminderMinutes: Int?
    /// Estado REAL da autorização de notificação (honesto — atualizado ao
    /// abrir a janela e após cada pedido).
    public private(set) var notificationStatus: NotificationAuthorizationState = .notDetermined

    /// Estado do launch at login, direto do serviço do sistema.
    public private(set) var launchAtLogin: Bool
    /// Aviso honesto de launch at login (erro de registro, aprovação
    /// pendente). `nil` = nada a dizer.
    public private(set) var launchNotice: String?
    /// Aviso honesto de alertas (permissão negada etc.). `nil` = nada a dizer.
    public private(set) var alertsNotice: String?

    /// Providers da lista de checkboxes (todos os conhecidos do motor).
    public var allProviders: [ProviderID] { ProviderID.allCases }

    // MARK: Dependências (todas opcionais p/ testes headless)

    private let store: AppSettingsStore
    private let alerts: AlertEngine?
    private let scheduler: AdaptiveScheduler?
    private let notifications: (any NotificationSending)?
    private let login: any LoginServiceManaging
    /// Republish da visibilidade no coordinator (texto do menu bar muda na
    /// hora). Persistência fica com o próprio modelo (tabela `settings`).
    private let republishVisibility: (@MainActor (Set<ProviderID>) -> Void)?

    public init(
        database: AppDatabase?,
        alerts: AlertEngine?,
        scheduler: AdaptiveScheduler?,
        notifications: (any NotificationSending)?,
        login: any LoginServiceManaging,
        republishVisibility: (@MainActor (Set<ProviderID>) -> Void)? = nil
    ) {
        self.store = AppSettingsStore(database: database)
        self.alerts = alerts
        self.scheduler = scheduler
        self.notifications = notifications
        self.login = login
        self.republishVisibility = republishVisibility

        foregroundRefreshSeconds = store.loadMenuIntervalSeconds()
        idleRefreshSeconds = store.loadIdleIntervalSeconds()
        visibleProviders = store.loadVisibleProviders()

        // Config de alertas: leitura ÚNICA via engine (mesmo decode), para a
        // janela abrir refletindo o que está persistido.
        let config = AlertEngine.readConfig(database: database)
        alertsEnabled = config.enabled
        // Lista vazia persistida = sem threshold alerts; a UI mantém mínimo
        // de 1 linha p/ editar — coerente com o invariante da janela (a
        // escrita só acontece quando o usuário edita algo).
        thresholds = config.thresholds.isEmpty ? AlertConfig.default.thresholds : config.thresholds
        resetReminderMinutes = config.resetReminderMinutes

        let status = login.status()
        launchAtLogin = (status == .enabled)
        if status == .requiresApproval {
            launchNotice = "TokenBar is waiting for approval in System Settings › General › Login Items."
        }
    }

    // MARK: - Refresh intervals (foreground/background)

    public func setForegroundRefresh(seconds: Int) async {
        let clamped = seconds.clamped(to: AppSettingsStore.menuRange)
        guard clamped != foregroundRefreshSeconds else { return }
        foregroundRefreshSeconds = clamped
        store.saveMenuIntervalSeconds(clamped)
        await scheduler?.setMenuInterval(.seconds(clamped))
    }

    public func setIdleRefresh(seconds: Int) async {
        let clamped = seconds.clamped(to: AppSettingsStore.idleRange)
        guard clamped != idleRefreshSeconds else { return }
        idleRefreshSeconds = clamped
        store.saveIdleIntervalSeconds(clamped)
        await scheduler?.setIdleInterval(.seconds(clamped))
    }

    // MARK: - Menu bar (quais providers aparecem no texto)

    public func setProviderVisible(_ id: ProviderID, _ visible: Bool) async {
        var updated = visibleProviders
        if visible {
            updated.insert(id)
        } else {
            updated.remove(id)
        }
        guard updated != visibleProviders else { return }
        visibleProviders = updated
        store.saveVisibleProviders(updated)
        republishVisibility?(updated)
    }

    // MARK: - Alertas (ruling F5-NOTIF: requestAuthorization EXPLÍCITO aqui)

    public func setAlertsEnabled(_ enabled: Bool) async {
        if enabled {
            guard let notifications else {
                // Sem gateway (ambiente de teste/sem notificações): honesto —
                // não liga nem finge que ligou.
                alertsNotice = "Notifications are unavailable in this environment."
                return
            }
            let granted = await notifications.requestAuthorization()
            notificationStatus = await notifications.authorizationState()
            alertsEnabled = granted
            alertsNotice = granted
                ? nil
                : "Notifications are not authorized. Allow TokenBar in System Settings › Notifications to turn alerts on."
        } else {
            alertsEnabled = false
            alertsNotice = nil
        }
        await pushAlertConfig()
    }

    /// Atualiza o estado da autorização mostrado na janela (on appear).
    public func refreshNotificationStatus() async {
        guard let notifications else { return }
        notificationStatus = await notifications.authorizationState()
    }

    /// Edita o threshold do índice mantendo a ordem CRESCENTE estrita e a
    /// faixa 10...100: o novo valor é preso entre os vizinhos (prev+1 e
    /// next−1) — nunca desordena, nunca duplica.
    public func updateThreshold(at index: Int, value: Int) async {
        guard thresholds.indices.contains(index) else { return }
        let lower = index > 0
            ? max(thresholds[index - 1] + 1, Self.thresholdRange.lowerBound)
            : Self.thresholdRange.lowerBound
        let upper = index < thresholds.count - 1
            ? min(thresholds[index + 1] - 1, Self.thresholdRange.upperBound)
            : Self.thresholdRange.upperBound
        guard lower <= upper else { return }
        let clamped = value.clamped(to: lower...upper)
        guard clamped != thresholds[index] else { return }
        thresholds[index] = clamped
        await pushAlertConfig()
    }

    /// Acrescenta um threshold acima do último (+passo, clamp no teto).
    public func addThreshold() async {
        guard thresholds.count < Self.maxThresholds else { return }
        let last = thresholds.last ?? Self.thresholdRange.lowerBound - Self.thresholdStep
        let value = (last + Self.thresholdStep).clamped(
            to: Self.thresholdRange.lowerBound...Self.thresholdRange.upperBound)
        guard value > last else { return }
        thresholds.append(value)
        await pushAlertConfig()
    }

    /// Remove o threshold do índice (mínimo de 1 — a lista nunca fica vazia
    /// na janela; desligar alerts é o toggle global).
    public func removeThreshold(at index: Int) async {
        guard thresholds.count > 1, thresholds.indices.contains(index) else { return }
        thresholds.remove(at: index)
        await pushAlertConfig()
    }

    public func setResetReminder(minutes: Int?) async {
        guard resetReminderMinutes != minutes else { return }
        resetReminderMinutes = minutes
        await pushAlertConfig()
    }

    /// Escrita ÚNICA da config no engine (que persiste em `settings`).
    private func pushAlertConfig() async {
        guard let alerts else { return }
        await alerts.apply(config: AlertConfig(
            enabled: alertsEnabled,
            thresholds: thresholds,
            resetReminderMinutes: resetReminderMinutes))
    }

    // MARK: - Launch at login (fonte da verdade = SMAppService)

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try login.register()
            } else {
                try login.unregister()
            }
            launchNotice = nil
        } catch {
            // Erro HONESTO na janela — estado real vem do serviço (abaixo),
            // nunca assumimos sucesso nem crash. O aviso fica ATÉ o usuário
            // conseguir a troca (sucesso limpa) — releitura de estado não o
            // apaga (o estado não mudou; apagar seria esconder a falha).
            launchNotice = "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    /// Rele o estado do serviço (on appear e após cada toggle). Cuida do
    /// aviso de aprovação pendente; erros de register/unregister são
    /// preservados (só o sucesso os limpa).
    public func refreshLoginStatus() {
        let status = login.status()
        launchAtLogin = (status == .enabled)
        switch status {
        case .requiresApproval:
            launchNotice = "TokenBar is waiting for approval in System Settings › General › Login Items."
        case .enabled, .notRegistered, .notFound:
            if launchNotice?.hasPrefix("TokenBar is waiting for approval") == true {
                launchNotice = nil
            }
        }
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
