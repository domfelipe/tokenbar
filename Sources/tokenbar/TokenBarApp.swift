import Foundation
import SwiftUI
import TokenBarUI

@main
enum TokenBarMain {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "selfcheck" {
            try? await SelfCheck.run(arguments: Array(arguments.dropFirst()))
            return
        }
        // F3 Task 4: `history` não sobe o app de menu bar — lê o banco, imprime
        // a série no stdout (contrato csv/json) e sai. Mesmo padrão do
        // selfcheck: subcomando resolve e retorna antes do `TokenBarApp.main()`.
        if arguments.count > 1, arguments[1] == "history" {
            let status = HistoryCommand.run(arguments: Array(arguments.dropFirst(2)))
            exit(status)
        }
        TokenBarApp.main()
    }
}

struct TokenBarApp: App {
    @State private var appState: AppState

    init() {
        // start() na instância crua: acessar o wrappedValue de @State antes da
        // instalação dispara warning; a instância em si já é utilizável aqui.
        let state = AppState()
        _appState = State(initialValue: state)
        state.start()
    }

    var body: some Scene {
        // Estilo .window: dá onAppear/onDisappear do painel — é assim que o
        // wiring cumpre a spec §7 (fire imediato ao abrir, reafirmar enquanto
        // aberto). F5 (ruling F5-DESIGN): o painel INTEIRO é o design portado
        // da referência (chip-bar, barra segmentada, dashboard, ações e
        // rodapé Refresh/Settings/About/Quit dentro da view) — o app só
        // fornece as ações.
        MenuBarExtra {
            // F4 Task 3: painel recebe o modelo de contas + ação de abrir o
            // formulário de add-account (janela própria). O alvo é o provider
            // da aba COM suporte a multi-conta; sem suporte na aba → o
            // primeiro com suporte (fallback do item F4; aba sem suporte não
            // registra linha morta — review T3 Minor 2). Sem DB (degradação
            // F2) → showAddAccount loga e ignora. Settings fica desabilitado
            // até a Task 3 (linha presente, clique não).
            ProviderPanelView(
                store: appState.store,
                accounts: appState.accountsModel,
                addAccountAction: { selected in
                    let target = appState.accountsModel.supportsMultiAccount(selected)
                        ? selected
                        : appState.accountsModel.multiAccountProviders
                            .sorted { $0.rawValue < $1.rawValue }.first
                    if let target {
                        appState.showAddAccount(for: target)
                    }
                },
                refreshAction: { Task { await appState.forceIngest() } },
                analyticsAction: { appState.showAnalytics() },
                exportAction: { Task { await appState.exportHistory() } },
                aboutAction: { NSApp.orderFrontStandardAboutPanel(nil) },
                quitAction: {
                    appState.stop()
                    NSApp.terminate(nil)
                })
                .onAppear { appState.menuDidOpen() }
                .onDisappear { appState.menuDidClose() }
        } label: {
            // Logos dos providers ao lado do relógio (pedido do usuário) —
            // a string canônica continua no label de acessibilidade.
            ProviderMenuBarLabel(store: appState.store)
        }
        .menuBarExtraStyle(.window)

        // F5 Task 3: janela de ajustes (⌘,) — launch at login, intervalos de
        // refresh, alertas e providers do menu bar. O SettingsModel é criado
        // no AppState com as partes do coordinator (engine de alertas,
        // scheduler, gateway, banco).
        Settings {
            SettingsView(model: appState.settingsModel)
        }
    }
}
