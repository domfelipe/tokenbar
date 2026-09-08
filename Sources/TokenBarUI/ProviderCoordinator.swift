import Foundation
import TokenBarCore
import TokenBarProviders

/// Configuração de wiring do coordinator — tudo injetável p/ testes e
/// selfcheck: environment (overrides TOKENBAR_*), dirs, e2e e fábrica de
/// stores de cursor. Default da fábrica (F3): store de cursores em SQLite
/// (`DBOffsetStore`, tabela `settings`) quando o banco abre — um POR provider,
/// chave `cursors:<provider>` — com fallback JSON POR provider no App Support
/// (`claude-cursors.json`, …) quando o DB não abre. OBRIGAÇÃO DURA F2:
/// compartilhar um store cruzaria providers (o rollover zera todos os paths
/// do store injetado). Fábrica injetada (testes/selfcheck) tem precedência.
public struct ProviderCoordinatorConfig: Sendable {
    public let environment: [String: String]
    public let home: URL
    public let supportDirectory: URL
    public let e2eDirectory: URL?
    public let makeOffsetStore: @Sendable (ProviderID) -> any FileOffsetStoring
    public let makeLedgerSnapshotStore: @Sendable (ProviderID) -> (any LedgerSnapshotStoring)?
    /// `false` quando o chamador injetou fábrica própria (testes/selfcheck) —
    /// nesse caso a store de cursores em SQLite NÃO substitui a injetada.
    let usesDefaultOffsetStore: Bool

    public init(
        environment: [String: String],
        home: URL,
        supportDirectory: URL,
        e2eDirectory: URL? = nil,
        makeOffsetStore: (@Sendable (ProviderID) -> any FileOffsetStoring)? = nil,
        makeLedgerSnapshotStore: (@Sendable (ProviderID) -> (any LedgerSnapshotStoring)?)? = nil
    ) {
        self.environment = environment
        self.home = home
        self.supportDirectory = supportDirectory
        self.e2eDirectory = e2eDirectory
        self.usesDefaultOffsetStore = (makeOffsetStore == nil)
        if let makeOffsetStore {
            self.makeOffsetStore = makeOffsetStore
        } else {
            let support = supportDirectory
            self.makeOffsetStore = { id in
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                return JSONFileOffsetStore(url: support.appendingPathComponent("\(id.rawValue)-cursors.json"))
            }
        }
        if let makeLedgerSnapshotStore {
            self.makeLedgerSnapshotStore = makeLedgerSnapshotStore
        } else {
            let support = supportDirectory
            self.makeLedgerSnapshotStore = { id in
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                return JSONLedgerSnapshotStore(url: support.appendingPathComponent("\(id.rawValue)-ledger.json"))
            }
        }
    }
}

/// Orquestrador F2 (spec §7): um ciclo por provider = ingest local (cursor
/// semeado do `nextCursor` PRÓPRIO do provider ou store fresco — contrato do
/// protocolo) + fetchUsage (sem rede quando não há credencial). Publica no
/// `SnapshotStore` (render gate) e escreve o heartbeat v2.
///
/// Concorrência:
/// - M1 por provider: `inFlight` (check+set atômico — classe @MainActor)
///   torna os 3 caminhos de ingest (scheduler, FSEvents+debounce, fallback
///   poll, refresh manual) single-flight POR provider; dois ingests sobrepostos
///   leriam os mesmos cursores e duplicariam o dia no ledger.
/// - Scheduler apenas para os API-driven (Codex, Z.ai) — Claude/Gemini são
///   file-driven: FSEvents + debounce + fallback poll de 15 min.
/// - Menu aberto: fire imediato (throttle 10 s) + `noteMenuOpened()` reafirmado
///   a cada ciclo enquanto aberto; `noteResult(ok)` devolve ao ocioso — a
///   spec §7 veda 2 fires simultâneos e exige os intervalos do scheduler.
/// - Sleep: pauseForSleep/resumeFromSleep (rede zero dormindo; wake = fire
///   imediato de todos) — observadores NSWorkspace ficam no AppState.
@MainActor
public final class ProviderCoordinator {
    /// Throttle do fire imediato ao abrir o menu (spec §7: não antes de 10 s
    /// da última abertura).
    public static let menuThrottle: TimeInterval = 10
    /// Fallback poll quando FSEvents não aplica (spec §7 / F1).
    static let fallbackPollInterval: Duration = .seconds(900)
    static let debounceQuiesce: Duration = .seconds(3)

    public let store: SnapshotStore
    public let scheduler: AdaptiveScheduler
    private let config: ProviderCoordinatorConfig
    private let registry: ProviderRegistry

    /// Dirs observados por FSEvents (file-driven): Claude projects, Gemini tmp.
    private let watcherDirectories: [ProviderID: URL]
    /// Cursor semeado por provider = `nextCursor` do ciclo anterior (contrato:
    /// nunca cursor de outro provider nem construído fora daqui).
    private var cursorSeeds: [ProviderID: IngestCursor] = [:]
    private var offsetStores: [ProviderID: any FileOffsetStoring] = [:]
    /// Estado de exibição por provider — inclui os que ainda não têm dado
    /// (heartbeat v2 lista todos os registrados).
    private var displays: [ProviderID: ProviderDisplay] = [:]
    /// Token do último erro de ciclo por provider (selfcheck; tokenizado).
    private var cycleErrors: [ProviderID: String] = [:]

    private var inFlight: Set<ProviderID> = []  // M1 por provider
    private var loopTasks: [Task<Void, Never>] = []
    private var watchers: [ProviderID: TranscriptWatcher] = [:]
    private var debouncers: [ProviderID: Debouncer<ContinuousClock>] = [:]
    private var started = false
    private var isMenuOpen = false
    private var lastMenuTrigger: Date?

    public init(config: ProviderCoordinatorConfig, scheduler: AdaptiveScheduler? = nil) {
        self.config = config
        self.store = SnapshotStore()
        self.scheduler = scheduler ?? AdaptiveScheduler(clock: ContinuousClock())

        let env = config.environment
        let home = config.home
        let calendar = Calendar.current

        // F3: banco SQLite (schema spec §6) na support directory — o
        // TOKENBAR_SUPPORT_DIR do AppState isola app/e2e. Falha de abertura
        // → nil → comportamento F2 degradado (JSON stores, sem persistência):
        // DB nunca derruba o app.
        let database = try? AppDatabase.open(
            at: config.supportDirectory.appendingPathComponent(AppDatabase.databaseName),
            calendar: calendar)
        if let database {
            // Migração dos cursores legados F1/F2 (JSON → settings), uma vez
            // por arquivo (idempotente); o live store vira DBOffsetStore.
            for id in [ProviderID.claude, .codex, .gemini] {
                CursorMigrator.migrate(
                    provider: id,
                    jsonURL: config.supportDirectory.appendingPathComponent("\(id.rawValue)-cursors.json"),
                    database: database)
            }
        }

        // Um store POR provider (obrigação dura F2); guarda p/ semeadura de
        // primeira fase ("store fresco"). Com DB aberto e fábrica DEFAULT,
        // o store vivo é o DBOffsetStore (settings); fábrica injetada
        // (testes/selfcheck) tem precedência; sem DB → JSON legado (F2).
        let stores: [ProviderID: any FileOffsetStoring]
        if let database, config.usesDefaultOffsetStore {
            stores = [
                .claude: DBOffsetStore(database: database, provider: .claude),
                .codex: DBOffsetStore(database: database, provider: .codex),
                .gemini: DBOffsetStore(database: database, provider: .gemini),
            ]
        } else {
            stores = [
                .claude: config.makeOffsetStore(.claude),
                .codex: config.makeOffsetStore(.codex),
                .gemini: config.makeOffsetStore(.gemini),
            ]
        }
        offsetStores = stores
        // Snapshot do dia por provider (restart mid-day, Red Team F2 caso 7):
        // mesmo diretório dos cursores; Z.ai não tem ingest → sem snapshot.
        let ledgerStores: [ProviderID: any LedgerSnapshotStoring] = [
            .claude: config.makeLedgerSnapshotStore(.claude),
            .codex: config.makeLedgerSnapshotStore(.codex),
            .gemini: config.makeLedgerSnapshotStore(.gemini),
        ].compactMapValues { $0 }

        let claudeDirectory = ClaudeTranscriptLocator.resolve(environment: env, home: home).projectsDirectory
        let geminiDirectory = GeminiProvider.resolveGeminiDirectory(environment: env, home: home)
        let claude = ClaudeProvider(
            projectsDirectory: claudeDirectory,
            offsetStore: stores[.claude]!,
            calendar: calendar,
            ledgerSnapshotStore: ledgerStores[.claude],
            persisting: database
        )
        let codex = CodexProvider(
            sessionsDirectory: CodexProvider.resolveSessionsDirectory(environment: env, home: home),
            authReader: CodexAuthReader.resolve(environment: env, home: home),
            client: UsageHTTPClient(baseURL: CodexProvider.resolveBaseURL(environment: env)),
            offsetStore: stores[.codex]!,
            calendar: calendar,
            ledgerSnapshotStore: ledgerStores[.codex],
            persisting: database
        )
        let gemini = GeminiProvider(
            geminiDirectory: geminiDirectory,
            offsetStore: stores[.gemini]!,
            calendar: calendar,
            ledgerSnapshotStore: ledgerStores[.gemini],
            persisting: database
        )
        let zaiReader = ZaiCredentialReader.resolve(environment: env, home: home)
        let zai = ZaiProvider(
            credentialReader: zaiReader,
            client: UsageHTTPClient(baseURL: ZaiProvider.resolveBaseURL(environment: env, regionHint: zaiReader.read()?.regionBaseURL))
        )
        registry = ProviderRegistry(providers: [claude, codex, gemini, zai])
        watcherDirectories = [.claude: claudeDirectory, .gemini: geminiDirectory.appendingPathComponent("tmp", isDirectory: true)]
        for id in watcherDirectories.keys {
            debouncers[id] = Debouncer(quiesce: Self.debounceQuiesce, clock: ContinuousClock())
        }
    }

    // MARK: - Ciclo de vida

    public func start() async {
        guard !started else { return }
        started = true

        // API-driven: um loop do scheduler por provider (spec §7).
        for provider in registry.all where provider.capabilities.contains(.apiUsage) {
            let id = provider.id
            await scheduler.register(provider: id) { [weak self] in
                await self?.cycle(provider: id)
            }
        }

        // File-driven: FSEvents → debounce 3 s; fallback poll de 15 min.
        for id in watcherDirectories.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let directory = watcherDirectories[id]!
            let watcher = TranscriptWatcher(directory: directory)
            watchers[id] = watcher
            let events = watcher.events()  // consumidor ANTES do start (padrão F1)
            watcher.start()
            let debouncer = debouncers[id]
            loopTasks.append(Task { [weak self] in
                for await _ in events {
                    guard let self else { break }
                    await debouncer?.touch()
                    await debouncer?.wait()
                    if Task.isCancelled { break }
                    await self.cycle(provider: id)
                }
            })
            loopTasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.fallbackPollInterval)
                    guard let self else { return }
                    await self.cycle(provider: id)
                }
            })
        }

        // Primeiro ciclo imediato de todos (padrão F1).
        await refreshAllNow()
    }

    public func stop() {
        for task in loopTasks { task.cancel() }
        loopTasks.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        // Pause (e não cancel) o scheduler: barras os fires de rede; ao sair o
        // app termina de qualquer forma.
        Task { await scheduler.pauseForSleep() }
    }

    // MARK: - Ciclo por provider

    /// Refresh manual (botão/primeiro ciclo): um ciclo de cada provider
    /// registrado, em ordem de registro (C, X, G, Z).
    public func refreshAllNow() async {
        for provider in registry.all {
            await cycle(provider: provider.id)
        }
    }

    /// Um ciclo do provider: ingest local + fetchUsage → display → publish →
    /// noteResult (o scheduler decide o intervalo). Skip-if-busy: ciclo em
    /// curso deste provider → este vira não-op (o próximo tick re-ingere).
    func cycle(provider id: ProviderID) async {
        guard let provider = registry.provider(for: id) else { return }
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        var ok = true
        var errorToken: String?

        // Conta: a descoberta quando visível; fallback é a conta local canônica
        // que todo provider F2 atende (sem credencial → snapshot degradado,
        // nunca rede — spec §5).
        let accounts = await provider.discoverAccounts()
        let account = accounts.first ?? AccountRef(id: AccountID(provider: id, key: "local"), label: "local")

        // 1) Ingest local (Claude/Codex/Gemini): semeia do nextCursor PRÓPRIO
        // do ciclo anterior; primeira vez, do store fresco (contrato de cursor).
        if provider.capabilities.contains(.localIngest) {
            let seed = cursorSeeds[id] ?? IngestCursor(fileOffsets: offsetStores[id]?.cursors() ?? [:])
            do {
                let batch = try await provider.ingestLocal(account, from: seed)
                cursorSeeds[id] = batch.nextCursor
                var display = displays[id] ?? .empty
                display.todayTokens = batch.providerTotals[id] ?? 0
                display.fetchedAt = Date()
                displays[id] = display
            } catch {
                // Mantém o último total bom (nunca dado errado). Provider sem
                // display nenhum ainda entra no payload — o heartbeat v2 lista
                // TODOS os registrados, e o token de erro não pode se perder
                // num provider que nunca conseguiu dado (regressão T8).
                ok = false
                errorToken = Self.errorToken(error)
                if displays[id] == nil { displays[id] = .empty }
            }
        }

        // 2) FetchUsage: local-only nunca gera rede; API sem credencial degrada
        // (`.missing`) sem request; erro de rede → último snapshot bom fica.
        do {
            let snapshot = try await provider.fetchUsage(account)
            let critical = criticalWindow(in: snapshot.windows)
            var display = displays[id] ?? .empty
            display.percent = critical?.usedFraction.map { $0 * 100 }
            display.resetsAt = critical?.resetsAt
            display.authState = snapshot.authState
            display.source = snapshot.source
            display.fetchedAt = snapshot.fetchedAt
            displays[id] = display
        } catch {
            ok = false
            errorToken = errorToken ?? Self.errorToken(error)
            // Idem: provider API-driven com o primeiro ciclo em erro (rede
            // morta, 401, 500…) NÃO some do diagnóstico — entra vazio com o
            // token do erro anexado (regressão T8: zai sumia do heartbeat v2).
            if displays[id] == nil { displays[id] = .empty }
        }

        if let errorToken {
            cycleErrors[id] = errorToken
        } else {
            cycleErrors.removeValue(forKey: id)
        }
        publish()

        let pressure = displays[id]?.percent.map { $0 / 100 }  // 0...1 p/ scheduler
        await scheduler.noteResult(provider: id, ok: ok, pressure: pressure)
        // Menu aberto: reafirma cadência de 60 s — exceto sob pressão (30 s
        // vence o menu, spec §7).
        if isMenuOpen, (pressure ?? 0) < 0.8 {
            await scheduler.noteMenuOpened()
        }
    }

    // MARK: - Menu (spec §7: fire imediato com throttle; reafirmar enquanto aberto)

    public func menuDidOpen() {
        isMenuOpen = true
        let now = Date()
        if let last = lastMenuTrigger, now.timeIntervalSince(last) < Self.menuThrottle { return }
        lastMenuTrigger = now
        Task { [weak self] in
            guard let self else { return }
            await self.scheduler.noteMenuOpened()
            await self.refreshAllNow()
        }
    }

    public func menuDidClose() {
        isMenuOpen = false
    }

    // MARK: - Sleep (observadores NSWorkspace no AppState)

    public func sleepDidBegin() {
        Task { await scheduler.pauseForSleep() }
    }

    public func wakeDidHappen() {
        Task { await scheduler.resumeFromSleep() }  // fire imediato de todos
    }

    // MARK: - Saídas

    private func publish() {
        store.apply(MenuBarContent(providers: displays))
        if let e2eDirectory = config.e2eDirectory {
            E2EHeartbeat.write(menuBarText: store.menuBarText, providers: displays, directory: e2eDirectory)
        }
    }

    /// Payload v2 completo (selfcheck): inclui erros tokenizados por provider.
    public func diagnosticPayload(now: Date = Date()) -> [String: Any] {
        E2EHeartbeat.payload(menuBarText: store.menuBarText, providers: displays, errors: cycleErrors, now: now)
    }

    /// Token curto do erro — nunca a mensagem crua (URLs/shape; spec §9).
    static func errorToken(_ error: Error) -> String {
        switch error as? UsageHTTPError {
        case .network: return "network"
        case .http: return "http"
        case .decode: return "decode"
        case .unauthorized: return "unauthorized"
        case nil: return String(describing: type(of: error))
        }
    }
}
