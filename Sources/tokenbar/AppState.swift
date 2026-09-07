import AppKit
import Foundation
import TokenBarCore
import TokenBarProviders
import TokenBarUI

/// Cola SwiftUI/NSWorkspace do app F2: monta o `ProviderCoordinator` com os
/// overrides de ambiente e repassa os eventos de ciclo de vida. Toda a regra
/// de ciclo/scheduler/heartbeat vive no coordinator (testável fora do
/// executável — alvo `tokenbar` não é importável pelos testes).
@MainActor
final class AppState {
    private let coordinator: ProviderCoordinator

    var store: SnapshotStore { coordinator.store }

    init() {
        let env = ProcessInfo.processInfo.environment
        // Override de testes/e2e (T8): isola cursores/ledger em um diretório
        // próprio — sem ele, corpora descartáveis acumulam entradas no App
        // Support real e o snapshot do dia as ressuscita entre runs.
        let supportDir = env["TOKENBAR_SUPPORT_DIR"].map {
            let url = URL(filePath: $0, isDirectory: true)
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
