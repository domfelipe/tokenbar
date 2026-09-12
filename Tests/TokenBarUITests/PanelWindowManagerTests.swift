import AppKit
import Foundation
import Testing
@testable import TokenBarUI

/// Lifecycle das janelas extras do painel (fix "cliques do painel não
/// funcionam"): o `WindowBookkeeping` prova as invariantes de estado (show
/// não duplica, close limpa referência, re-show reabre) e o
/// `ExtraWindowManager` prova as mesmas invariantes com `NSWindow` de
/// verdade — show idempotente reusa a MESMA janela, fecho (botão, notificação
/// do conteúdo, closeAll) devolve o estado a zero.
@MainActor
struct PanelWindowManagerTests {
    // MARK: - WindowBookkeeping (puro)

    @Test("bookkeeping: show cria uma vez; re-show é idempotente")
    func bookkeepingShowIsIdempotent() {
        var state = WindowBookkeeping()
        #expect(!state.isOpen(id: "analytics"))
        #expect(state.windowShown(id: "analytics") == true)  // criou
        #expect(state.isOpen(id: "analytics"))
        #expect(state.windowShown(id: "analytics") == false)  // já aberta: só re-foca
        #expect(state.openWindowIDs == ["analytics"])  // nunca duplica
    }

    @Test("bookkeeping: close limpa a referência; close espúrio é no-op")
    func bookkeepingCloseClearsReference() {
        var state = WindowBookkeeping()
        _ = state.windowShown(id: "addaccount:claude")
        #expect(state.windowClosed(id: "addaccount:claude") == true)  // limpou
        #expect(!state.isOpen(id: "addaccount:claude"))
        #expect(state.windowClosed(id: "addaccount:claude") == false)  // não estava aberta
    }

    @Test("bookkeeping: show → close → show reabre (ciclo completo)")
    func bookkeepingReopenCycle() {
        var state = WindowBookkeeping()
        _ = state.windowShown(id: "analytics")
        _ = state.windowClosed(id: "analytics")
        #expect(state.windowShown(id: "analytics") == true)  // re-show cria de novo
        #expect(state.isOpen(id: "analytics"))
    }

    @Test("bookkeeping: identidades independentes (analytics ≠ addaccount:provider)")
    func bookkeepingIndependentIdentities() {
        var state = WindowBookkeeping()
        _ = state.windowShown(id: ExtraWindowManager.analyticsID)
        _ = state.windowShown(id: ExtraWindowManager.addAccountID(provider: "claude"))
        #expect(state.openWindowIDs.count == 2)
        _ = state.windowClosed(id: ExtraWindowManager.analyticsID)
        #expect(!state.isOpen(id: ExtraWindowManager.analyticsID))
        #expect(state.isOpen(id: ExtraWindowManager.addAccountID(provider: "claude")))
    }

    // MARK: - ExtraWindowManager (NSWindow de verdade)

    /// Factory que conta invocações — re-show NÃO pode reconstruir conteúdo.
    @MainActor
    private final class CountingFactory {
        var calls = 0
        var lastWindow: NSWindow?
        func make() -> NSWindow {
            calls += 1
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: -2000, width: 200, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            lastWindow = window
            return window
        }
    }

    @Test("manager: show cria a janela UMA vez; re-show reusa (sem duplicar)")
    func managerShowDoesNotDuplicate() {
        let manager = ExtraWindowManager()
        let factory = CountingFactory()
        let created1 = manager.showWindow(id: "analytics", factory: factory.make)
        #expect(created1 == true)
        #expect(factory.calls == 1)
        #expect(manager.isWindowOpen(id: "analytics"))

        let created2 = manager.showWindow(id: "analytics", factory: factory.make)
        #expect(created2 == false)  // só re-focou
        #expect(factory.calls == 1)  // conteúdo NÃO reconstruído
        #expect(manager.bookkeeping.openWindowIDs == ["analytics"])  // sem duplicação
    }

    @Test("manager: close (botão) limpa referência; re-show cria nova janela")
    func managerCloseClearsAndReopen() {
        let manager = ExtraWindowManager()
        let factory = CountingFactory()
        _ = manager.showWindow(id: "analytics", factory: factory.make)
        let firstWindow = factory.lastWindow

        manager.closeWindow(id: "analytics")
        #expect(!manager.isWindowOpen(id: "analytics"))
        #expect(manager.bookkeeping.openWindowIDs.isEmpty)

        _ = manager.showWindow(id: "analytics", factory: factory.make)
        #expect(factory.calls == 2)  // nova janela de verdade
        #expect(factory.lastWindow !== firstWindow)
    }

    @Test("manager: fecho pelo close button da janela cai no windowWillClose")
    func managerWindowButtonClose() {
        let manager = ExtraWindowManager()
        let factory = CountingFactory()
        _ = manager.showWindow(id: "analytics", factory: factory.make)
        // Close button = window.close() → windowWillClose → referência limpa.
        factory.lastWindow?.close()
        #expect(!manager.isWindowOpen(id: "analytics"))
        #expect(manager.bookkeeping.openWindowIDs.isEmpty)
    }

    @Test("manager: pedido de fecho do CONTEÚDO (notificação) fecha pela identidade")
    func managerContentCloseRequest() {
        let manager = ExtraWindowManager()
        let factory = CountingFactory()
        _ = manager.showWindow(id: "addaccount:claude", factory: factory.make)
        #expect(manager.isWindowOpen(id: "addaccount:claude"))

        // Mesma notificação que o Cancel/Add do AddAccountView dispara.
        NotificationCenter.default.post(
            name: ExtraWindowCloseRequest.name, object: nil,
            userInfo: [ExtraWindowCloseRequest.idKey: "addaccount:claude"])

        #expect(!manager.isWindowOpen(id: "addaccount:claude"))
    }

    @Test("manager: closeAll derruba todas as identidades abertas (quit sem zumbi)")
    func managerCloseAll() {
        let manager = ExtraWindowManager()
        let factory = CountingFactory()
        _ = manager.showWindow(id: ExtraWindowManager.analyticsID, factory: factory.make)
        _ = manager.showWindow(
            id: ExtraWindowManager.addAccountID(provider: "claude"), factory: factory.make)
        #expect(manager.bookkeeping.openWindowIDs.count == 2)

        manager.closeAll()
        #expect(manager.bookkeeping.openWindowIDs.isEmpty)
        // Idempotente: closeAll com nada aberto é no-op.
        manager.closeAll()
        #expect(manager.bookkeeping.openWindowIDs.isEmpty)
    }

    @Test("manager: identidades distintas têm janelas distintas (retarget do add-account)")
    func managerDistinctIdentitiesDistinctWindows() {
        let manager = ExtraWindowManager()
        let factory = CountingFactory()
        _ = manager.showWindow(
            id: ExtraWindowManager.addAccountID(provider: "claude"), factory: factory.make)
        let claudeWindow = factory.lastWindow
        _ = manager.showWindow(
            id: ExtraWindowManager.addAccountID(provider: "codex"), factory: factory.make)
        #expect(factory.calls == 2)
        #expect(factory.lastWindow !== claudeWindow)  // providers → janelas próprias
        #expect(manager.bookkeeping.openWindowIDs.count == 2)
    }
}
