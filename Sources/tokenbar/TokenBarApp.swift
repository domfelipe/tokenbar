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
        // aberto). F4: painel rico (abas por provider com logo, barras de
        // janela com countdown, pacing, custos e chart 30d) no lugar da lista
        // de texto; ações preservadas; multi-conta (F4 Task 3) com seção de
        // contas por aba e item "Add account…".
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                // F4 Task 3: painel recebe o modelo de contas + ação de abrir
                // o formulário de add-account (janela própria).
                ProviderPanelView(
                    store: appState.store,
                    accounts: appState.accountsModel,
                    addAccountAction: { appState.showAddAccount(for: $0) })
                Divider()
                Button("Refresh now") {
                    Task { await appState.forceIngest() }
                }
                Divider()
                // F3 Task 3: analytics em janela PRÓPRIA (não o painel) e export
                // CSV/JSON do histórico (30d) com reveal no Finder. Sem atalhos
                // próprios (padrão F2: só o Quit tem — evita colidir com bindings
                // padrão do macOS).
                Button("Analytics…") {
                    appState.showAnalytics()
                }
                Button("Export history…") {
                    Task { await appState.exportHistory() }
                }
                // F4 Task 3: multi-conta — abre o form para o provider da aba
                // selecionada (ou o primeiro com suporte). Sem DB (degradação
                // F2) ou sem suporte → item oculto (honesto: nada a registrar).
                if appState.accountsModel.registry != nil {
                    Button("Add account…") {
                        let target = appState.store.selectedProvider
                            ?? appState.accountsModel.multiAccountProviders.sorted { $0.rawValue < $1.rawValue }.first
                        if let target {
                            appState.showAddAccount(for: target)
                        }
                    }
                }
                Divider()
                Button("Quit TokenBar") {
                    appState.stop()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(10)
            .frame(minWidth: 280, alignment: .leading)
            .onAppear { appState.menuDidOpen() }
            .onDisappear { appState.menuDidClose() }
        } label: {
            Text(appState.store.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
