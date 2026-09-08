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
        // aberto). Uma linha por provider ativo + Refresh + Quit.
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 4) {
                let lines = appState.store.menuLines
                if lines.isEmpty {
                    Text("TokenBar — sem dados ainda")
                } else {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                    }
                }
            }
            .padding(10)
            .frame(minWidth: 200, alignment: .leading)
            .onAppear { appState.menuDidOpen() }
            .onDisappear { appState.menuDidClose() }
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
            Divider()
            Button("Quit TokenBar") {
                appState.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text(appState.store.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
