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
        MenuBarExtra {
            Text("TokenBar F1 — local mode")
            Divider()
            Button("Refresh now") {
                Task { await appState.forceIngest() }
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
    }
}
