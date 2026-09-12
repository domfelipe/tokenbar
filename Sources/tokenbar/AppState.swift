import AppKit
import Foundation
import Observation
import os
import SwiftUI
import TokenBarCore
import TokenBarProviders
import TokenBarUI

/// Log do app (export/analytics): tokenizado, nunca conteúdo de evento.
private let appLog = Logger(subsystem: "dev.domhubs.TokenBar", category: "app")

/// Cola SwiftUI/NSWorkspace do app F2: monta o `ProviderCoordinator` com os
/// overrides de ambiente e repassa os eventos de ciclo de vida. Toda a regra
/// de ciclo/scheduler/heartbeat vive no coordinator (testável fora do
/// executável — alvo `tokenbar` não é importável pelos testes).
@MainActor
final class AppState: NSObject {
    private let coordinator: ProviderCoordinator
    /// Gerenciamento de contas (F4): registry do coordinator + providers com
    /// suporte. Mutação → refresh imediato (painel reflete na hora).
    let accountsModel: AccountsModel
    /// Modelo da janela de Settings (F5 Task 3): banco/engine/scheduler/
    /// gateway do coordinator + SMAppService real. Toggle de alertas chama
    /// requestAuthorization() EXPLICITAMENTE (ruling F5-NOTIF); trocas de
    /// intervalo/visibilidade aplicam vivos no scheduler/republish — sem
    /// restart.
    let settingsModel: SettingsModel

    var store: SnapshotStore { coordinator.store }

    override init() {
        let env = ProcessInfo.processInfo.environment
        // Override de testes/e2e (T8): isola cursores/ledger/DB em um diretório
        // próprio — sem ele, corpora descartáveis acumulam entradas no App
        // Support real e o snapshot do dia as ressuscita entre runs. Regra
        // compartilhada com o `history` CLI (SupportDirectory.resolve) para os
        // dois caminhos abrirem o MESMO banco.
        let supportDir = SupportDirectory.resolve(environment: env)
        let e2eDir = env["TOKENBAR_E2E_DIR"].map {
            let url = URL(filePath: $0)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Locais primeiro: closures abaixo capturam a constante, não self
        // (self só é utilizável após super.init — NSObject).
        // Gateway de captura do e2e (F5 T7): `TOKENBAR_E2E_ALERTS_CAPTURE` no
        // ambiente troca o UNUserNotificationCenter real pelo gateway que grava
        // os alertas em arquivo (prova de disparo sem centro de notificação —
        // o caminho de render/identificador é o mesmo do gateway real).
        let e2eAlertsCapture = env["TOKENBAR_E2E_ALERTS_CAPTURE"]
            .map { E2EAlertCaptureGateway(fileURL: URL(filePath: $0)) }
        let coord = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: env,
            home: URL(filePath: NSHomeDirectory()),
            supportDirectory: supportDir,
            e2eDirectory: e2eDir,
            notificationGateway: e2eAlertsCapture
        ))
        coordinator = coord
        let multiAccount = Set(ProviderID.allCases.filter { coord.supportsMultiAccount($0) })
        // Raízes canônicas de scan: insumo do guard de overlap do registro
        // (dir de conta sobre a canônica dobraria o histórico — review T3).
        var canonicalRoots: [ProviderID: String] = [:]
        for id in multiAccount {
            if let root = coord.canonicalScanRoot(for: id) {
                canonicalRoots[id] = root.path
            }
        }
        accountsModel = AccountsModel(
            registry: coord.accountRegistry,
            multiAccountProviders: multiAccount,
            canonicalRoots: canonicalRoots)
        // F5 Task 3: republish da visibilidade do menu bar direto no
        // coordinator (ambos MainActor; o coordinator não retém o modelo —
        // sem ciclo).
        settingsModel = SettingsModel(
            database: coord.historyDatabase,
            alerts: coord.alertEngine,
            scheduler: coord.scheduler,
            notifications: coord.notifications,
            login: SMAppLoginService(),
            republishVisibility: { coord.applyMenuBarVisibility($0) })
        super.init()  // NSObject: antes de qualquer uso de self (delegates)
        accountsModel.onMutation = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.refreshAllNow() }
        }
        installSleepObservers()
    }
    func start() {
        Task { await coordinator.start() }
    }

    func stop() {
        extraWindows.closeAll()  // nenhuma janela extra fica zumbi no quit
        coordinator.stop()
    }

    func forceIngest() async {
        await coordinator.refreshAllNow()
    }

    /// Painel abriu: fire imediato (throttle 10 s) + cadência de menu no scheduler.
    func menuDidOpen() {
        coordinator.menuDidOpen()
    }

    func menuDidClose() {
        coordinator.menuDidClose()
    }

    // MARK: - Janelas extras (F3 analytics / F4 add-account)

    /// Ciclo de vida das janelas extras (fix do painel): controller ÚNICO por
    /// identidade, show idempotente, close limpa referência, ativação de app
    /// acessório em todo show. Testável no target TokenBarUI.
    private let extraWindows = ExtraWindowManager()

    /// Item "Add account…": abre (ou traz à frente) o formulário para o
    /// provider indicado. Idempotente: janela já aberta do MESMO provider só
    /// ganha foco; provider DIFERENTE fecha a atual e abre a nova (o alvo do
    /// formulário nunca fica obsoleto).
    func showAddAccount(for provider: ProviderID) {
        guard accountsModel.registry != nil else {
            appLog.error("add account ignorado: sem banco (degradação F2)")
            return
        }
        let id = ExtraWindowManager.addAccountID(provider: provider.rawValue)
        extraWindows.showWindow(id: id) { [accountsModel] in
            let hosting = NSHostingView(
                rootView: AddAccountView(provider: provider, model: accountsModel) {
                    // Cancel/Add: fecha pela identidade (mesmo caminho do
                    // close button — nunca referência direta de janela).
                    NotificationCenter.default.post(
                        name: ExtraWindowCloseRequest.name, object: nil,
                        userInfo: [ExtraWindowCloseRequest.idKey: id])
                })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Add Account"
            window.contentView = hosting
            window.center()
            return window
        }
    }

    /// Item "Usage dashboard": abre (ou traz à frente) a janela própria —
    /// nunca o painel. Idempotente: janela já aberta só ganha foco.
    func showAnalytics() {
        extraWindows.showWindow(id: ExtraWindowManager.analyticsID) { [coordinator] in
            let model = AnalyticsModel(database: coordinator.historyDatabase)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "TokenBar Analytics"
            window.contentView = NSHostingView(rootView: AnalyticsView(model: model))
            window.center()
            return window
        }
    }

    // MARK: - Export CSV/JSON (F3 Task 3)

    /// Item "Export history…": escreve `history-<timestamp>.csv|.json` em
    /// `<support>/exports/` (query + escrita FORA da MainActor) e revela os
    /// dois arquivos no Finder. Janela própria nunca envolvida.
    func exportHistory() async {
        guard let database = coordinator.historyDatabase else {
            appLog.error("export ignorado: sem banco (degradação F2)")
            return
        }
        let support = coordinator.supportDirectory
        let urls = await Task.detached(priority: .userInitiated) { () -> [URL]? in
            let exporter = HistoryExporter(database: database, supportDirectory: support)
            return try? exporter.exportAll()
        }.value
        guard let urls, !urls.isEmpty else {
            appLog.error("export falhou (disco/permissão?) — ver persistenceLog")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Spec §7: rede zero dormindo; ao acordar, refresh imediato de todos.
    private func installSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.coordinator.sleepDidBegin() }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.coordinator.wakeDidHappen() }
        }
    }
}
