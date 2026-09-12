import AppKit
import Foundation

// MARK: - Estado puro do lifecycle (testável headless, sem NSWindow)

/// Contabilidade de janelas extras abertas (analytics/add-account): qual
/// identidade está aberta e o que show/close fez. Pura e `Sendable` — o
/// `ExtraWindowManager` real consulta/muta esse estado, e os testes provam
/// as invariantes (show não duplica, close limpa, re-show reabre).
public struct WindowBookkeeping: Equatable, Sendable {
    /// Identidades com janela viva (ex.: "analytics", "addaccount:claude").
    public private(set) var openWindowIDs: Set<String> = []

    public init() {}

    /// Janela com essa identidade está aberta?
    public func isOpen(id: String) -> Bool {
        openWindowIDs.contains(id)
    }

    /// Registra um show. Retorna `true` se a janela foi CRIADA agora;
    /// `false` se já estava aberta (show idempotente — só re-foca, nunca
    /// duplica).
    @discardableResult
    public mutating func windowShown(id: String) -> Bool {
        let created = openWindowIDs.insert(id).inserted
        return created
    }

    /// Registra um close. Retorna `true` se havia referência a limpar
    /// (windowWillClose soltou a janela — última referência cai);
    /// `false` se não estava aberta (close espúrio é no-op).
    @discardableResult
    public mutating func windowClosed(id: String) -> Bool {
        openWindowIDs.remove(id) != nil
    }
}

// MARK: - Pedido de fecho por notificação (conteúdo → manager)

/// Pedidos de fecho emitidos pelo CONTEÚDO de uma janela gerenciada (ex.:
/// botões Cancel/Add do formulário de conta). O conteúdo não conhece a
/// janela que o hospeda — pede o fecho pela IDENTIDADE; o manager fecha
/// pelo mesmo caminho do close button. Evita o antigo padrão de capturar a
/// `NSWindow` direto numa closure de SwiftUI (referência escapando do
/// ciclo de vida gerenciado).
public enum ExtraWindowCloseRequest {
    public static let name = Notification.Name("tokenbar.extraWindow.closeRequest")
    public static let idKey = "id"
}

// MARK: - Manager real (NSWindowController único por identidade)

/// Gerenciador das janelas extras do painel (F3 analytics / F4 add-account).
///
/// Regra de lifecycle (fix do bug "cliques do painel não funcionam"):
/// UM `NSWindowController` por identidade — show é IDEMPOTENTE (janela já
/// aberta só ganha `makeKeyAndOrderFront`, nunca cria segunda), e o fecho
/// (close button, Cancel, quit) derruba o controller → `NSHostingView` e o
/// model da janela são liberados SEM deixar referência pendurada (era a
/// suspeita de use-after-free do diagnóstico — agora o estado é uma fonte
/// única, o `WindowBookkeeping`, e o controller é dono da janela).
///
/// Ativação: app de menu bar é acessório (LSUIElement) — toda janela extra
/// precisa de `NSApp.activate(ignoringOtherApps: true)` ANTES de
/// `makeKeyAndOrderFront`, ou abre atrás do app da frente (usuário vê
/// "não aconteceu nada"). O manager faz a ativação em TODO show (criação
/// E re-foco) — nunca fica a cargo do chamador.
@MainActor
public final class ExtraWindowManager: NSObject, NSWindowDelegate {
    /// Identidade da janela de analytics (uma por app).
    public static let analyticsID = "analytics"
    /// Identidade da janela de add-account (uma por provider-alvo).
    public static func addAccountID(provider: String) -> String {
        "addaccount:\(provider)"
    }

    /// Estado observável (invariante testável: mostra exatamente o que está
    /// vivo — controllers e bookkeeping nunca divergem).
    public private(set) var bookkeeping = WindowBookkeeping()

    /// Controllers vivos por identidade. `windowWillClose` remove a entrada —
    /// o controller (e com ele a window + conteúdo) é liberado no fecho.
    private var controllers: [String: NSWindowController] = [:]

    override public init() {
        super.init()
        // Conteúdo pede fecho pela identidade (Cancel/Add do formulário):
        // mesmo caminho do close button — nunca referência direta de janela.
        NotificationCenter.default.addObserver(
            forName: ExtraWindowCloseRequest.name, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?[ExtraWindowCloseRequest.idKey] as? String else { return }
            MainActor.assumeIsolated {
                self?.closeWindow(id: id)
            }
        }
    }

    /// Janela com essa identidade está aberta?
    public func isWindowOpen(id: String) -> Bool {
        bookkeeping.isOpen(id: id)
    }

    /// Mostra a janela da identidade dada, criando-a pela factory se (e só
    /// se) não existir. Retorna `true` se criou; `false` se só re-focou.
    ///
    /// A factory roda APENAS na criação — re-show de janela existente não
    /// reconstrói conteúdo (models de analytics/add-account sobrevivem ao
    /// fechar-reabrir do painel do menu bar, que é transitório).
    ///
    /// Referência à VELHA janela em fecho diferido: o bookkeeping marca o
    /// close NA HORA (re-show logo após recria — comportamento visível),
    /// mas o controller só é solto no próximo ciclo da main run loop,
    /// DEPOIS da sequência de close do NSWindow terminar. Soltar o
    /// controller dentro de `windowWillClose` liberava a janela no MEIO do
    /// próprio fecho — travava a event loop do app (o painel do menu bar
    /// deixava de abrir: sintoma "nada que eu clico funciona").
    @discardableResult
    public func showWindow(id: String, factory: () -> NSWindow) -> Bool {
        // Acessório: sem ativação a janela abre atrás do app da frente.
        // `NSApp?`: em processo de teste não há app — ativação é no-op lá.
        NSApp?.activate(ignoringOtherApps: true)
        if let controller = controllers[id], let window = controller.window,
           bookkeeping.isOpen(id: id) {
            window.makeKeyAndOrderFront(nil)
            _ = bookkeeping.windowShown(id: id)  // idempotente: já aberta
            return false
        }
        let window = factory()
        window.isReleasedWhenClosed = false  // ciclo de vida é do controller
        window.delegate = self
        let controller = NSWindowController(window: window)
        controllers[id] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        _ = bookkeeping.windowShown(id: id)
        return true
    }

    /// Fecha a janela da identidade dada (se aberta). Dispara o mesmo
    /// caminho do close button: `close()` → `windowWillClose(_:)` → limpa.
    public func closeWindow(id: String) {
        guard let controller = controllers[id], let window = controller.window else { return }
        window.close()
    }

    /// Fecha TODAS as janelas extras (usado no quit — nenhuma fica zumbi
    /// após `NSApp.terminate`).
    public func closeAll() {
        for id in Array(controllers.keys) {
            closeWindow(id: id)
        }
    }

    /// Fecho de qualquer janela gerenciada: o bookkeeping marca o close
    /// NA HORA (spec F3: "fechar descarta" — estado visível imediato) e o
    /// controller é solto DEFERIDO (ver `showWindow`). Fechos de janelas
    /// NÃO gerenciadas são ignorados. (NSWindowDelegate é MainActor no SDK
    /// — mesmo padrão do AppState.)
    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        guard let entry = controllers.first(where: { $0.value.window === closing }) else {
            return  // janela de fora do manager (Settings scene, painel)
        }
        let id = entry.key
        let closingController = entry.value
        _ = bookkeeping.windowClosed(id: id)
        DispatchQueue.main.async { [weak self] in
            // Só solta se NINGUÉM recriou a identidade enquanto o fecho
            // terminava (re-show imediato cria controller novo — intocado).
            guard let self, self.controllers[id] === closingController else { return }
            closing.delegate = nil
            self.controllers[id] = nil
        }
    }
}
