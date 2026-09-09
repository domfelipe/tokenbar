import Foundation
import TokenBarCore
import TokenBarProviders
import TokenBarUI

/// Selfcheck v2 (F2): um ciclo de CADA provider + snapshot das APIs —
/// `{"menuBarText", "providers": {id: {menuBar, percent, todayTokens,
/// authState, fetchedAt, error?}}, "updatedAt"}`.
///
/// - Bases de API honram `TOKENBAR_CODEX_API`/`TOKENBAR_ZAI_API`; SEM
///   credencial não há request nenhum (degrada `.missing`, spec §5).
/// - Stores de cursor em memória: o selfcheck nunca consome os arquivos do app
///   (re-scan completo do dia, sem interferir nos cursores reais).
/// - Erro de ciclo vira token curto por provider (`network`, `http`...) —
///   nunca mensagem crua com URL/shape (spec §9).
enum SelfCheck {
    @MainActor
    static func run(arguments: [String]) async throws {
        var environment = ProcessInfo.processInfo.environment
        // Override clássico do selfcheck F1: dir de projects do Claude via argv.
        // `arguments` já vem sem o nome do programa (dropFirst no main), então o
        // token "selfcheck" em si é filtrado — usá-lo como caminho zera o scan.
        if let dir = arguments.first(where: { $0 != "selfcheck" }) {
            environment["TOKENBAR_CLAUDE_DIR"] = dir
        }
        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: environment,
            home: URL(filePath: NSHomeDirectory()),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenbar-selfcheck", isDirectory: true),
            e2eDirectory: nil,
            makeOffsetStore: { _, _ in SelfCheckOffsetStore() },
            // Sem snapshot de ledger: o selfcheck é somente-leitura sobre o
            // mundo real — nunca toca os arquivos do app (padrão dos cursores).
            makeLedgerSnapshotStore: { _, _ in nil }
        ))
        await coordinator.refreshAllNow()
        let payload = coordinator.diagnosticPayload()
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

private final class SelfCheckOffsetStore: FileOffsetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: FileCursor] = [:]

    func cursors() -> [String: FileCursor] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ cursor: FileCursor?, for path: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let cursor { storage[path] = cursor } else { storage.removeValue(forKey: path) }
    }
}
