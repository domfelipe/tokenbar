import Foundation
import TokenBarCore
import TokenBarProviders
import TokenBarUI

@MainActor
final class AppState {
    let store = SnapshotStore()

    private let provider: ClaudeProvider
    private let watcher: TranscriptWatcher
    private let debouncer: Debouncer<ContinuousClock>
    private var loopTask: Task<Void, Never>?
    private let e2eDir: URL?

    init() {
        let env = ProcessInfo.processInfo.environment
        let locator = ClaudeTranscriptLocator.resolve(environment: env, home: URL(filePath: NSHomeDirectory()))
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        provider = ClaudeProvider(
            projectsDirectory: locator.projectsDirectory,
            offsetStore: JSONFileOffsetStore(url: supportDir.appendingPathComponent("cursors.json")),
            calendar: .current
        )
        watcher = TranscriptWatcher(directory: locator.projectsDirectory)
        debouncer = Debouncer(quiesce: .seconds(3), clock: ContinuousClock())
        e2eDir = env["TOKENBAR_E2E_DIR"].map {
            let url = URL(filePath: $0)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task.detached { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        watcher.stop()
        loopTask?.cancel()
        loopTask = nil
    }

    func forceIngest() async {
        await ingestNow()
    }

    private func ingestNow() async {
        // IngestOutcome tem init internal — extrair totals em vez de construir fallback.
        let totals = (try? await provider.ingestOnce(now: Date()))?.providerTotals ?? [:]
        let content = MenuBarContent(todayTokens: totals)
        store.apply(content)
        if let e2eDir {
            E2EHeartbeat.write(menuBarText: store.menuBarText, totals: totals, directory: e2eDir)
        }
    }

    /// Ciclo F1: subscribe nos eventos ANTES de iniciar o watcher; primeiro ingest
    /// imediato; depois FSEvents → debounce 3 s; fallback: poll de 15 min caso o
    /// volume não suporte FSEvents. (Scheduler adaptativo de rede completo = F2.)
    private func runLoop() async {
        let events = watcher.events()
        watcher.start()
        await ingestNow()

        let fallback = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                await self?.ingestNow()
            }
        }
        defer { fallback.cancel() }

        for await _ in events {
            await debouncer.touch()
            await debouncer.wait()
            if Task.isCancelled { break }
            await ingestNow()
        }
    }
}
