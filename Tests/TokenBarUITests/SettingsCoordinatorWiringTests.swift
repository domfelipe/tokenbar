import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F5 Task 3 — wiring Settings ↔ coordinator: a visibilidade dos providers
/// no texto do menu bar carregada da tabela `settings` no launch, o texto
/// respeitando o conjunto (provider com dado, mas escondido, some) e a
/// troca AO VIVO via `applyMenuBarVisibility` (sem restart, render gate
/// da F1 intocado). Intervalos persistidos também entram no scheduler vivo.
@MainActor
struct SettingsCoordinatorWiringTests {
    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    @Test("visibilidade persistida carrega no launch; texto some/volta ao vivo")
    func visibilityLoadsAtLaunchAndRepublishesLive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-settings-coord-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claudeDir, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Corpus Claude sintético: 33 + 44 = 77 tokens → fragmento "C:77".
        let line =
            "{\"type\":\"assistant\",\"timestamp\":\"\(isoNow())\",\"message\":{\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":33,\"output_tokens\":44}}}"
        try (line + "\n").write(
            to: claudeDir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        // Pré-persiste: NENHUM provider visível (escolha válida — menu "TB").
        let seedDatabase = try AppDatabase.open(
            at: support.appendingPathComponent(AppDatabase.databaseName),
            calendar: .current, pricing: nil)
        let seedStore = AppSettingsStore(database: seedDatabase)
        seedStore.saveVisibleProviders([])
        seedStore.saveIdleIntervalSeconds(900)
        seedStore.saveMenuIntervalSeconds(30)

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: [
                "TOKENBAR_CLAUDE_DIR": claudeDir.path,
                "TOKENBAR_CODEX_DIR": root.appendingPathComponent("codex").path,
                "TOKENBAR_CODEX_AUTH": root.appendingPathComponent("none.json").path,
                "TOKENBAR_CODEX_API": "http://127.0.0.1:1",
                "TOKENBAR_GEMINI_DIR": root.appendingPathComponent("gemini").path,
                "TOKENBAR_ZAI_CONFIG": root.appendingPathComponent("zai.json").path,
                "TOKENBAR_ZAI_API": "http://127.0.0.1:1",
            ],
            home: root,  // home fake: nada real é lido
            supportDirectory: support,
            e2eDirectory: e2e))

        // Launch: estado veio da tabela `settings` (e o scheduler arranca com
        // os intervalos persistidos — sem restart quando a Settings troca).
        #expect(coordinator.menuBarVisibleProviders == [])
        #expect(await coordinator.scheduler.idleInterval == .seconds(900))
        #expect(await coordinator.scheduler.menuInterval == .seconds(30))

        // Ciclo: claude TEM dado, mas está escondido → texto "TB".
        await coordinator.refreshAllNow()
        #expect(coordinator.store.menuBarText == "TB")

        // Settings republish ao vivo: claude volta → "C:77" (render gate
        // publica porque a string exibida mudou).
        await coordinator.applyMenuBarVisibility([.claude])
        #expect(coordinator.menuBarVisibleProviders == [.claude])
        #expect(coordinator.store.menuBarText == "C:77")

        // Esconder de novo volta a "TB" (mesma porta, caminho de ida e volta).
        await coordinator.applyMenuBarVisibility([])
        #expect(coordinator.store.menuBarText == "TB")
    }
}
