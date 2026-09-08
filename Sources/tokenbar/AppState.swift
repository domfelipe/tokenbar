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
final class AppState: NSObject, NSWindowDelegate {
    private let coordinator: ProviderCoordinator

    var store: SnapshotStore { coordinator.store }

    override init() {
        let env = ProcessInfo.processInfo.environment
        // Override de testes/e2e (T8): isola cursores/ledger em um diretório
        // próprio — sem ele, corpora descartáveis acumulam entradas no App
        // Support real e o snapshot do dia as ressuscita entre runs.
        let supportDir = env["TOKENBAR_SUPPORT_DIR"].map {
            let url = URL(fileURLWithPath: $0, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let e2eDir = env["TOKENBAR_E2E_DIR"].map {
            let url = URL(filePath: $0)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: env,
            home: URL(filePath: NSHomeDirectory()),
            supportDirectory: supportDir,
            e2eDirectory: e2eDir
        ))
        super.init()  // NSObject: antes de qualquer uso de self (delegates)
        installSleepObservers()
    }

    func start() {
        Task { await coordinator.start() }
    }

    func stop() {
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

    // MARK: - Analytics (F3 Task 3): janela PRÓPRIA, sob demanda

    /// Janela de analytics — `nil` = fechada/descartada. As views e o modelo
    /// SÓ existem enquanto ela está aberta (orçamento de RAM ≤40MB): fechar
    /// derruba a referência, o NSHostingView solta o `AnalyticsModel` e os
    /// charts/arrays vão embora com ele.
    private var analyticsWindow: NSWindow?

    /// Item "Analytics…": abre (ou traz à frente) a janela própria — nunca
    /// o painel. Idempotente: janela já aberta só ganha foco.
    func showAnalytics() {
        NSApp.activate(ignoringOtherApps: true)
        if let analyticsWindow {
            analyticsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let model = AnalyticsModel(database: coordinator.historyDatabase)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TokenBar Analytics"
        window.contentView = NSHostingView(rootView: AnalyticsView(model: model))
        window.isReleasedWhenClosed = false  // ciclo de vida é NOSSO (nil no close)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        analyticsWindow = window
    }

    /// Fecho da janela de analytics = descartar views + modelo (spec F3:
    /// "fechar descarta").
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === analyticsWindow else { return }
        analyticsWindow = nil  // última referência: NSHostingView e o modelo vão junto
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
