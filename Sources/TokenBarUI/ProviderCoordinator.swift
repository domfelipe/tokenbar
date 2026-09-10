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
///
/// F4 multi-conta: as fábricas recebem a chave da conta (`String?`, nil =
/// conta default/provider-scoped). Conta default mantém o nome/layout F2
/// (`claude-cursors.json`, `cursors:claude`); contas registradas ganham
/// namespace próprio (`claude-<accountKey>-cursors.json` /
/// `cursors:claude:<accountKey>` — ver `DBOffsetStore`).
public struct ProviderCoordinatorConfig: Sendable {
    public let environment: [String: String]
    public let home: URL
    public let supportDirectory: URL
    public let e2eDirectory: URL?
    public let makeOffsetStore: @Sendable (ProviderID, String?) -> any FileOffsetStoring
    public let makeLedgerSnapshotStore: @Sendable (ProviderID, String?) -> (any LedgerSnapshotStoring)?
    /// `false` quando o chamador injetou fábrica própria (testes/selfcheck) —
    /// nesse caso a store de cursores em SQLite NÃO substitui a injetada.
    let usesDefaultOffsetStore: Bool
    /// Gateway de notificações (F5 T2). `nil` (default) = gateway REAL
    /// (`UserNotificationGateway`), criado LAZY no primeiro uso — o init do
    /// coordinator NUNCA toca no UNUserNotificationCenter (tests runner não
    /// tem bundle id; ruling F5-NOTIF: nada de notificação no launch).
    /// Testes injetam um fake capturável.
    public let notificationGateway: (any NotificationSending)?

    public init(
        environment: [String: String],
        home: URL,
        supportDirectory: URL,
        e2eDirectory: URL? = nil,
        makeOffsetStore: (@Sendable (ProviderID, String?) -> any FileOffsetStoring)? = nil,
        makeLedgerSnapshotStore: (@Sendable (ProviderID, String?) -> (any LedgerSnapshotStoring)?)? = nil,
        notificationGateway: (any NotificationSending)? = nil
    ) {
        self.environment = environment
        self.home = home
        self.supportDirectory = supportDirectory
        self.e2eDirectory = e2eDirectory
        self.notificationGateway = notificationGateway
        self.usesDefaultOffsetStore = (makeOffsetStore == nil)
        if let makeOffsetStore {
            self.makeOffsetStore = makeOffsetStore
        } else {
            let support = supportDirectory
            self.makeOffsetStore = { id, accountKey in
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let name = accountKey.map { "\(id.rawValue)-\($0)-cursors.json" } ?? "\(id.rawValue)-cursors.json"
                return JSONFileOffsetStore(url: support.appendingPathComponent(name))
            }
        }
        if let makeLedgerSnapshotStore {
            self.makeLedgerSnapshotStore = makeLedgerSnapshotStore
        } else {
            let support = supportDirectory
            self.makeLedgerSnapshotStore = { id, accountKey in
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let name = accountKey.map { "\(id.rawValue)-\($0)-ledger.json" } ?? "\(id.rawValue)-ledger.json"
                return JSONLedgerSnapshotStore(url: support.appendingPathComponent(name))
            }
        }
    }
}

/// Orquestrador F2 (spec §7): um ciclo por provider = ingest local (cursor
/// semeado do `nextCursor` PRÓPRIO do provider ou store fresco — contrato do
/// protocolo) + fetchUsage (sem rede quando não há credencial). Publica no
/// `SnapshotStore` (render gate) e escreve o heartbeat v2.
///
/// F4 multi-conta: o ciclo itera a conta canônica ("local", layout F2
/// preservado) + TODAS as contas ATIVAS do registry (ruling F4-MULTIACCOUNT:
/// troca efetiva de credencial multi-provider é F5 — aqui cada conta
/// registrada ganha uma INSTÂNCIA de provider própria com credencial/dir do
/// registro lidos read-only, cursor/ledger/hwm por conta). Agregado do
/// provider = tokens somados + janela crítica da conta de maior fração
/// (decisão registrada: pior caso visível, mesmo critério D5 do menu bar).
///
/// Concorrência:
/// - M1 por provider: `inFlight` (check+set atômico — classe @MainActor)
///   torna os 3 caminhos de ingest (scheduler, FSEvents+debounce, fallback
///   poll, refresh manual) single-flight POR provider; dois ingests sobrepostos
///   leriam os mesmos cursores e duplicariam o dia no ledger.
/// - Scheduler apenas para os API-driven (Codex, Z.ai) — Claude/Gemini são
///   file-driven: FSEvents + debounce + fallback poll de 15 min. Contas
///   registradas de providers file-driven ciclizam na cadência do provider
///   (o ciclo por provider cobre todas as contas).
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
    /// Calendar do ciclo (rollover do ledger, janelas e pacing) — o mesmo
    /// injetado nos providers no init.
    private let calendar: Calendar
    /// Banco aberto no init (F3); `nil` = degradação F2 (sem persistência e
    /// sem custo: `todayCostUsd` do display fica `nil` — nunca chutado).
    /// Retido além do wiring dos providers para a consulta do custo do dia.
    private let database: AppDatabase?
    /// Exposição só-LEITURA do banco p/ a UI de F3 (linha 7d do painel,
    /// analytics, export). Queries rodam FORA da MainActor no chamador.
    public var historyDatabase: AppDatabase? { database }
    /// Registry multi-conta (F4): CRUD da tabela `accounts`. `nil` quando o
    /// banco não abriu (degradação F2) — a UI esconde "+ Add account" (sem DB
    /// não há onde registrar; honesto, não desabilitado por engano).
    public let accountRegistry: AccountRegistry?
    /// Motor de alertas (F5 T2): thresholds/dedupe sobre as janelas do ciclo.
    /// Exposto p/ a janela de Settings (T3) aplicar config — que pede a
    /// permissão de notificação EXPLICITAMENTE (ruling F5-NOTIF).
    public let alertEngine: AlertEngine
    /// Gateway de notificações: injetado (testes) ou real, criado LAZY.
    /// PÚBLICO para a janela de Settings (T3) pedir a autorização no toggle
    /// de alertas — acessá-lo NÃO pede permissão (ruling F5-NOTIF: só o
    /// toggle chama `requestAuthorization()`).
    public var notifications: any NotificationSending {
        if let injected = config.notificationGateway { return injected }
        if let cachedGateway { return cachedGateway }
        let real = UserNotificationGateway()
        cachedGateway = real
        return real
    }
    private var cachedGateway: (any NotificationSending)?
    /// Support directory (o export grava em `<support>/exports`).
    public var supportDirectory: URL { config.supportDirectory }
    /// Providers visíveis no TEXTO do menu bar (F5 Task 3) — carregado da
    /// tabela `settings` no init e mantido vivo pela janela de Settings via
    /// `applyMenuBarVisibility` (a persistência fica com o SettingsModel).
    public private(set) var menuBarVisibleProviders: Set<ProviderID> =
        AppSettingsStore.defaultVisibleProviders

    /// Dirs observados por FSEvents (file-driven): Claude projects, Gemini tmp.
    private let watcherDirectories: [ProviderID: URL]
    /// Resoluções de wiring reutilizadas pelas instâncias de conta (F4).
    private let defaultClaudeDirectory: URL
    private let defaultCodexSessionsDirectory: URL
    private let defaultCodexBaseURL: URL
    private let defaultZaiCredentialsURL: URL

    /// Cursor semeado por (provider, conta) = `nextCursor` do ciclo anterior
    /// (contrato: nunca cursor de outro provider/conta nem construído fora).
    private var cursorSeeds: [ProviderID: [String: IngestCursor]] = [:]
    private var offsetStores: [ProviderID: any FileOffsetStoring] = [:]
    /// Stores por conta (F4), criados lazily e retidos — o ledger da instância
    /// de conta é estado do dia; recriar a instância zeraria o "hoje".
    private var accountOffsetStores: [ProviderID: [String: any FileOffsetStoring]] = [:]
    private var accountLedgerStores: [ProviderID: [String: (any LedgerSnapshotStoring)?]] = [:]
    private var accountInstances: [ProviderID: [String: any UsageProvider]] = [:]
    /// Estado de exibição por provider — inclui os que ainda não têm dado
    /// (heartbeat v2 lista todos os registrados).
    private var displays: [ProviderID: ProviderDisplay] = [:]
    /// Último estado bom POR CONTA (F4): a conta degradada mantém o último
    /// total/janelas bons — nunca dado errado, mesmo padrão do provider.
    private var perAccountDisplays: [ProviderID: [String: ProviderDisplay]] = [:]
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

        let env = config.environment
        let home = config.home
        let calendar = Calendar.current
        self.calendar = calendar

        // F3: banco SQLite (schema spec §6) na support directory — o
        // TOKENBAR_SUPPORT_DIR do AppState isola app/e2e. Falha de abertura
        // → nil → comportamento F2 degradado (JSON stores, sem persistência):
        // DB nunca derruba o app. O diretório TEM que existir antes do open
        // (DatabasePool não cria diretórios): o AppState cria via
        // SupportDirectory.resolve e as fábricas default também criam, mas o
        // selfcheck passa um dir próprio com fábricas injetadas — sem o
        // createDirectory aqui o DB dele NUNCA abria e o history7d ficava
        // sempre omitido (review T4, Important). Aberto ANTES do scheduler
        // (F5 Task 3): os intervalos persistidos na tabela `settings` são o
        // estado inicial do scheduler — sem restart quando a Settings troca
        // (setters vivos do actor aplicam na hora).
        try? FileManager.default.createDirectory(
            at: config.supportDirectory, withIntermediateDirectories: true)
        let database = try? AppDatabase.open(
            at: config.supportDirectory.appendingPathComponent(AppDatabase.databaseName),
            calendar: calendar)
        self.database = database
        self.accountRegistry = database.map(AccountRegistry.init)
        // Motor de alertas (F5 T2): config + dedupe lidos do banco (settings);
        // sem DB → só memória (degrada honesta, default DESLIGADO — F5-NOTIF).
        alertEngine = AlertEngine(database: database)

        // F5 Task 3: preferências do usuário no launch — scheduler com os
        // intervalos persistidos (foreground/menu e background/ocioso) e o
        // texto do menu bar com a visibilidade persistida.
        let settings = AppSettingsStore(database: database)
        self.scheduler = scheduler ?? AdaptiveScheduler(
            clock: ContinuousClock(),
            idleInterval: Duration.seconds(settings.loadIdleIntervalSeconds()),
            menuInterval: Duration.seconds(settings.loadMenuIntervalSeconds()))
        menuBarVisibleProviders = settings.loadVisibleProviders()

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
        // Conta default = key nil → chave legada `cursors:<provider>`.
        let stores: [ProviderID: any FileOffsetStoring]
        if let database, config.usesDefaultOffsetStore {
            stores = [
                .claude: DBOffsetStore(database: database, provider: .claude),
                .codex: DBOffsetStore(database: database, provider: .codex),
                .gemini: DBOffsetStore(database: database, provider: .gemini),
            ]
        } else {
            stores = [
                .claude: config.makeOffsetStore(.claude, nil),
                .codex: config.makeOffsetStore(.codex, nil),
                .gemini: config.makeOffsetStore(.gemini, nil),
            ]
        }
        offsetStores = stores
        // Snapshot do dia por provider (restart mid-day, Red Team F2 caso 7):
        // mesmo diretório dos cursores; Z.ai não tem ingest → sem snapshot.
        let ledgerStores: [ProviderID: any LedgerSnapshotStoring] = [
            .claude: config.makeLedgerSnapshotStore(.claude, nil),
            .codex: config.makeLedgerSnapshotStore(.codex, nil),
            .gemini: config.makeLedgerSnapshotStore(.gemini, nil),
        ].compactMapValues { $0 }

        let claudeDirectory = ClaudeTranscriptLocator.resolve(environment: env, home: home).projectsDirectory
        let geminiDirectory = GeminiProvider.resolveGeminiDirectory(environment: env, home: home)
        let claude = ClaudeProvider(
            projectsDirectory: claudeDirectory,
            offsetStore: stores[.claude]!,
            calendar: calendar,
            ledgerSnapshotStore: ledgerStores[.claude],
            persisting: database,
            accounts: accountRegistry
        )
        let codexSessionsDirectory = CodexProvider.resolveSessionsDirectory(environment: env, home: home)
        let codexBaseURL = CodexProvider.resolveBaseURL(environment: env)
        let codex = CodexProvider(
            sessionsDirectory: codexSessionsDirectory,
            authReader: CodexAuthReader.resolve(environment: env, home: home),
            client: UsageHTTPClient(baseURL: codexBaseURL),
            offsetStore: stores[.codex]!,
            calendar: calendar,
            ledgerSnapshotStore: ledgerStores[.codex],
            persisting: database,
            accounts: accountRegistry
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
            client: UsageHTTPClient(baseURL: ZaiProvider.resolveBaseURL(environment: env, regionHint: zaiReader.read()?.regionBaseURL)),
            accounts: accountRegistry)
        // Providers F5 (Tasks 4–5): todos API-only com degradação local-first
        // (sem credencial → discoverAccounts [] + snapshot .missing — some da
        // barra, nunca erro). Isolamento: quebra de um NÃO afeta os demais.
        let cursor = CursorProvider(
            credentialReader: .resolve(environment: env, home: home),
            client: UsageHTTPClient(baseURL: CursorProvider.resolveBaseURL(environment: env)),
            accounts: accountRegistry)
        let openrouter = OpenRouterProvider(
            credentialReader: OpenRouterCredentialReader(environment: env),
            client: UsageHTTPClient(baseURL: OpenRouterProvider.resolveBaseURL(environment: env)),
            accounts: accountRegistry)
        registry = ProviderRegistry(providers: [claude, codex, gemini, zai, cursor, openrouter])
        watcherDirectories = [.claude: claudeDirectory, .gemini: geminiDirectory.appendingPathComponent("tmp", isDirectory: true)]
        for id in watcherDirectories.keys {
            debouncers[id] = Debouncer(quiesce: Self.debounceQuiesce, clock: ContinuousClock())
        }
        // Resoluções reutilizadas pelas instâncias de conta registrada (F4).
        defaultClaudeDirectory = claudeDirectory
        defaultCodexSessionsDirectory = codexSessionsDirectory
        defaultCodexBaseURL = codexBaseURL
        defaultZaiCredentialsURL = zaiReader.credentialsFileURL
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

    /// Provider tem suporte a multi-conta (F4)? A UI usa p/ mostrar o botão
    /// "+ Add account" (provider sem suporte → botão oculto, plan T3).
    public func supportsMultiAccount(_ id: ProviderID) -> Bool {
        registry.provider(for: id)?.capabilities.contains(.multiAccount) ?? false
    }

    /// Raiz de scan canônica do provider (conta default) — insumo do guard de
    /// overlap do registro de contas (review T3: dir de conta sobrepondo a
    /// raiz canônica dobraria o histórico provider-wide de forma persistente).
    /// `nil` = provider sem ingest local (nada a proteger).
    public func canonicalScanRoot(for id: ProviderID) -> URL? {
        switch id {
        case .claude: return defaultClaudeDirectory
        case .codex: return defaultCodexSessionsDirectory
        case .gemini: return watcherDirectories[.gemini]
        default: return nil
        }
    }

    /// Um ciclo do provider: descoberta MERGE de contas → por conta (ingest
    /// local + fetchUsage) → agregado → publish → noteResult. Skip-if-busy:
    /// ciclo em curso deste provider → este vira não-op (o próximo tick
    /// re-ingere). Erro de conta registrada degrada A CONTA (badge na linha),
    /// nunca o provider — ok do scheduler vem da conta canônica (F2 compat).
    func cycle(provider id: ProviderID) async {
        guard let provider = registry.provider(for: id) else { return }
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        // Descoberta MERGE (1×/ciclo — "refresh de contas no ciclo"): auto +
        // registry, dedupe por key (contrato do protocolo; rótulos vêm daqui).
        let discovered = await provider.discoverAccounts()
        let registered = (try? accountRegistry?.activeAccounts(provider: id)) ?? []

        // Alvos do ciclo: a conta canônica SEMPRE (F2: snapshot degradado
        // mesmo sem credencial — spec §5) + as registradas ativas com key
        // própria (dedupe por key com a canônica).
        var targets: [(instance: any UsageProvider, ref: AccountRef, entry: RegisteredAccount?)] = []
        let defaultRef = discovered.first { $0.id.key == "local" }
            ?? AccountRef(id: AccountID(provider: id, key: "local"), label: "local")
        targets.append((provider, defaultRef, nil))
        for entry in registered where entry.accountKey != "local" {
            if let instance = accountInstance(provider: id, entry: entry) {
                targets.append((instance, AccountRef(id: AccountID(provider: id, key: entry.accountKey), label: entry.label), entry))
            }
        }
        pruneAccountCaches(provider: id, liveKeys: Set(["local"] + registered.map(\.accountKey)))

        let database = self.database

        // Fase 1 — INGEST POR CONTA (F4): só a conta canônica e registradas
        // com dir própria (conta API-only não re-ingere o corpus compartilhado).
        // Erro de uma conta não derruba as demais (degrada sozinha).
        var accountDisplays: [AccountDisplay] = []
        var primaryOK = true
        var primaryErrorToken: String?
        for target in targets {
            let key = target.ref.id.key
            var display = perAccountDisplays[id]?[key] ?? ProviderDisplay.empty
            var ok = true
            var errorToken: String?

            if ingestsLocal(instance: target.instance, entry: target.entry) {
                let seed = cursorSeeds[id]?[key]
                    ?? IngestCursor(fileOffsets: accountOffsetStore(provider: id, key: key).cursors())
                do {
                    let batch = try await target.instance.ingestLocal(target.ref, from: seed)
                    cursorSeeds[id, default: [:]][key] = batch.nextCursor
                    display.todayTokens = batch.providerTotals[id] ?? 0
                    // Mesmo padrão F2: ingest saudável carimba o ciclo.
                    display.fetchedAt = Date()
                } catch {
                    // Mantém o último total bom da conta (nunca dado errado).
                    ok = false
                    errorToken = Self.errorToken(error)
                }
            }
            perAccountDisplays[id, default: [:]][key] = display
            if target.entry == nil {
                // ok do provider = ok da conta canônica (F2 compat: scheduler,
                // backoff e cicloErrors como antes).
                primaryOK = ok
                primaryErrorToken = errorToken
            }
        }

        // Fase 2 — Histórico provider-wide (F3/F4): DEPOIS da ingest (as
        // queries de 7d/30d/custo têm que ver o dia corrente recém-persistido
        // — ordem F2/F3 preservada) e SÓ para providers com ingest local —
        // API-only (zai) nunca persistiu diários: sem leitura, heartbeat
        // OMITE history (comportamento F3). 1 conjunto de queries por CICLO,
        // FORA da MainActor; daily_agg soma contas, então 7d/30d/série já são
        // agregados; o input de PACING é POR CONTA. Falha → nil → o painel
        // mantém o último valor bom (padrão F3).
        let loadsHistory = provider.capabilities.contains(.localIngest)
        let pacingKeys = targets
            .filter { ingestsLocal(instance: $0.instance, entry: $0.entry) }
            .map(\.ref.id.key)
        let stats: HistoryStats? = loadsHistory
            ? await Task.detached(priority: .utility) { () -> HistoryStats? in
                guard let database else { return nil }
                let week = try? database.weekTotal(provider: id)
                let month = try? database.weekTotal(provider: id, days: 30)
                let series = (try? database.dailySeries(provider: id, days: 30)) ?? []
                let todayCost = try? database.todayCostUSD(provider: id)
                // Top model 7d (F5): primeiro do breakdown (tokens desc) do
                // PRÓPRIO provider; sem histórico → nil (linha omitida).
                let topModel = ((try? database.modelBreakdown(days: 7, provider: id)) ?? [])
                    .first?.model
                var pacingByAccount: [String: [(day: Date, total: Int64)]] = [:]
                for key in pacingKeys {
                    pacingByAccount[key] = (try? database.pacingInput(
                        provider: id, account: AccountID(provider: id, key: key), days: 30)) ?? []
                }
                return HistoryStats(
                    week: week, month: month, series: series,
                    todayCost: todayCost, topModel: topModel, pacingByAccount: pacingByAccount)
            }.value
            : nil

        // Fase 3 — FetchUsage POR CONTA: local-only nunca gera rede; API sem
        // credencial degrada (`.missing`) sem request; erro de rede → último
        // snapshot bom da conta fica. Janelas bem-sucedidas alimentam o
        // AlertEngine (F5 T2) no fim do ciclo.
        var cycleSnapshots: [(provider: ProviderID, account: AccountID, windows: [UsageWindow])] = []
        for target in targets {
            let key = target.ref.id.key
            var display = perAccountDisplays[id]?[key] ?? ProviderDisplay.empty
            var ok = true
            var errorToken: String?

            do {
                let snapshot = try await target.instance.fetchUsage(target.ref)
                cycleSnapshots.append(
                    (provider: id, account: target.ref.id, windows: snapshot.windows))
                let critical = criticalWindow(in: snapshot.windows)
                display.percent = critical?.usedFraction.map { $0 * 100 }
                display.resetsAt = critical?.resetsAt
                display.windows = snapshot.windows
                // Forecast de pacing contra a janela crítica DA CONTA, com o
                // input diário da PRÓPRIA conta (daily_agg por conta). Sem
                // janela com fração/reset conhecidos → nil (sem chute).
                let pacingInput = stats?.pacingByAccount[key] ?? []
                display.pacing = critical.flatMap {
                    PacingEngine.forecast(
                        dailySums: pacingInput,
                        window: $0,
                        now: Date(),
                        calendar: calendar)
                }
                display.authState = snapshot.authState
                display.source = snapshot.source
                display.fetchedAt = snapshot.fetchedAt
            } catch {
                ok = false
                errorToken = errorToken ?? Self.errorToken(error)
            }

            perAccountDisplays[id, default: [:]][key] = display
            // Conta inválida (path registrado inexistente) → badge na linha;
            // a conta segue no ciclo e degrada sozinha (sem derrubar o resto).
            let invalid = Self.hasInvalidPath(entry: target.entry)
            accountDisplays.append(AccountDisplay(
                key: key,
                label: target.ref.label,
                active: target.entry?.active ?? true,
                invalidCredential: invalid,
                display: display))

            if target.entry == nil {
                // A conta canônica manda: ingest (fase 1) E fetch (fase 3)
                // precisam ter sucesso — como no caminho único F2/F3.
                primaryOK = primaryOK && ok
                primaryErrorToken = primaryErrorToken ?? errorToken
            }
        }

        var aggregate = Self.aggregateAccountsDisplay(accountDisplays, base: displays[id] ?? .empty)
        // Histórico provider-wide por cima do agregado (mesma semântica F3:
        // com DB e provider de ingest, valor do ciclo — query falha → nil/flag
        // false; sem DB ou API-only, o campo nem é tocado).
        if loadsHistory, database != nil {
            aggregate.todayCostUsd = stats?.todayCost
            if let stats {
                if let week = stats.week {
                    aggregate.weekTokens = week.tokens
                    aggregate.weekCostUsd = week.costUSD
                    aggregate.weekHistoryAvailable = true
                } else {
                    aggregate.weekHistoryAvailable = false
                }
                if let month = stats.month {
                    aggregate.monthTokens = month.tokens
                    aggregate.monthCostUsd = month.costUSD
                    aggregate.monthHistoryAvailable = true
                } else {
                    aggregate.monthHistoryAvailable = false
                }
                aggregate.monthSeries = stats.series.map {
                    PanelDayPoint(day: $0.day, tokens: $0.tokens, costUSD: $0.costUSD)
                }
                // "Top model" do painel (F5) — painel-only, menu bar intocado.
                aggregate.topModel7d = stats.topModel
            } else {
                aggregate.weekHistoryAvailable = false
                aggregate.monthHistoryAvailable = false
            }
        }
        displays[id] = aggregate

        if let primaryErrorToken {
            cycleErrors[id] = primaryErrorToken
        } else {
            cycleErrors.removeValue(forKey: id)
        }
        publish()

        // Alertas (F5 T2): thresholds sobre os snapshots DESTE ciclo, entrega
        // pelo gateway e estado honesto no painel. Default DESLIGADO — quando
        // off, nada toca no gateway/permissão (ruling F5-NOTIF).
        await dispatchAlerts(snapshots: cycleSnapshots, now: Date())

        let pressure = displays[id]?.percent.map { $0 / 100 }  // 0...1 p/ scheduler
        await scheduler.noteResult(provider: id, ok: primaryOK, pressure: pressure)
        // Menu aberto: reafirma cadência de 60 s — exceto sob pressão (30 s
        // vence o menu, spec §7).
        if isMenuOpen, (pressure ?? 0) < 0.8 {
            await scheduler.noteMenuOpened()
        }
    }

    // MARK: - Multi-conta (F4)

    /// A conta alvo ingere local? Canônica de provider com `.localIngest`
    /// sempre; registrada só com `directory_path` próprio (conta API-only não
    /// re-ingere o corpus compartilhado — evita dupla contagem por conta).
    private func ingestsLocal(instance: any UsageProvider, entry: RegisteredAccount?) -> Bool {
        guard instance.capabilities.contains(.localIngest) else { return false }
        if let entry { return !entry.directoryPath.isEmpty }
        return true
    }

    /// Path registrado inválido (badge de erro na linha da conta):
    /// credencial inexistente OU NÃO-REGULAR (FIFO/device/diretório — Red
    /// Team F4 caso 4: o reader nunca vai conseguir ler; o badge é honesto
    /// ANTES de a conta degradar no ciclo); diretório de ingest inexistente
    /// ou não-diretório.
    static func hasInvalidPath(entry: RegisteredAccount?) -> Bool {
        guard let entry else { return false }
        if !FileKind.isRegularFile(atPath: entry.credentialPath) { return true }
        if !entry.directoryPath.isEmpty, !FileKind.isDirectory(atPath: entry.directoryPath) {
            return true
        }
        return false
    }

    /// Instância de provider da conta registrada — criada uma vez e retida
    /// (ledger/cursores são estado do dia; recriar zeraria o "hoje"). Conta
    /// sem suporte (gemini e futuros) → nil.
    private func accountInstance(provider id: ProviderID, entry: RegisteredAccount) -> (any UsageProvider)? {
        if let cached = accountInstances[id]?[entry.accountKey] { return cached }
        guard let built = makeAccountProvider(id, entry) else { return nil }
        accountInstances[id, default: [:]][entry.accountKey] = built
        return built
    }

    private func makeAccountProvider(_ id: ProviderID, _ entry: RegisteredAccount) -> (any UsageProvider)? {
        let key = entry.accountKey
        // Dir vazia = conta API-only: a instância aponta pro dir default mas
        // NUNCA ingere (`ingestsLocal` nega) — só fetchUsage com a credencial.
        let directory = entry.directoryPath.isEmpty
            ? nil : URL(fileURLWithPath: entry.directoryPath, isDirectory: true)
        switch id {
        case .claude:
            return ClaudeProvider(
                projectsDirectory: directory ?? defaultClaudeDirectory,
                offsetStore: accountOffsetStore(provider: id, key: key),
                calendar: calendar,
                ledgerSnapshotStore: accountLedgerStore(provider: id, key: key),
                persisting: database,
                accountKey: key,
                label: entry.label)
        case .codex:
            return CodexProvider(
                sessionsDirectory: directory ?? defaultCodexSessionsDirectory,
                authReader: CodexAuthReader(authFileURL: URL(filePath: entry.credentialPath)),
                client: UsageHTTPClient(baseURL: defaultCodexBaseURL),
                offsetStore: accountOffsetStore(provider: id, key: key),
                calendar: calendar,
                ledgerSnapshotStore: accountLedgerStore(provider: id, key: key),
                persisting: database,
                accountKey: key,
                label: entry.label)
        case .zai:
            let reader = ZaiCredentialReader(
                configFileURL: URL(filePath: entry.credentialPath),
                credentialsFileURL: defaultZaiCredentialsURL)
            return ZaiProvider(
                credentialReader: reader,
                client: UsageHTTPClient(baseURL: ZaiProvider.resolveBaseURL(
                    environment: config.environment,
                    regionHint: reader.read()?.regionBaseURL)),
                accountKey: key,
                label: entry.label)
        case .cursor:
            return CursorProvider(
                credentialReader: CursorCredentialReader(
                    databaseFileURL: nil,
                    tokenFileURL: URL(filePath: entry.credentialPath)),
                client: UsageHTTPClient(baseURL: CursorProvider.resolveBaseURL(environment: config.environment)),
                accountKey: key,
                label: entry.label)
        case .openrouter:
            return OpenRouterProvider(
                credentialReader: OpenRouterCredentialReader(
                    keyFileURL: URL(filePath: entry.credentialPath)),
                client: UsageHTTPClient(baseURL: OpenRouterProvider.resolveBaseURL(environment: config.environment)),
                accountKey: key,
                label: entry.label)
        default:
            return nil
        }
    }

    /// Store de cursores POR CONTA (F4): DB aberto + fábrica default →
    /// `DBOffsetStore` com namespace `cursors:<provider>:<key>` (a conta
    /// default usa a chave legada `cursors:<provider>`); senão a fábrica
    /// (default JSON `<provider>-<key>-cursors.json`).
    private func accountOffsetStore(provider id: ProviderID, key: String) -> any FileOffsetStoring {
        if let cached = accountOffsetStores[id]?[key] { return cached }
        let store: any FileOffsetStoring
        if let database, config.usesDefaultOffsetStore {
            store = DBOffsetStore(database: database, provider: id, accountKey: key)
        } else {
            store = config.makeOffsetStore(id, key)
        }
        accountOffsetStores[id, default: [:]][key] = store
        return store
    }

    private func accountLedgerStore(provider id: ProviderID, key: String) -> (any LedgerSnapshotStoring)? {
        if let cached = accountLedgerStores[id]?[key] { return cached }
        let store = config.makeLedgerSnapshotStore(id, key)
        accountLedgerStores[id, default: [:]][key] = store
        return store
    }

    /// Contas removidas do registry perdem instância/stores/seeds (higiene de
    /// memória; recriar do zero é seguro — re-ingest do corpus reconstrói).
    private func pruneAccountCaches(provider id: ProviderID, liveKeys: Set<String>) {
        for (key, _) in accountInstances[id] ?? [:] where !liveKeys.contains(key) {
            accountInstances[id]?.removeValue(forKey: key)
            accountOffsetStores[id]?.removeValue(forKey: key)
            accountLedgerStores[id]?.removeValue(forKey: key)
            cursorSeeds[id]?.removeValue(forKey: key)
            perAccountDisplays[id]?.removeValue(forKey: key)
        }
    }

    /// Agregado multi-conta (puro, testável): tokens SOMADOS entre as contas;
    /// janelas/percent/resetsAt/pacing/auth/fonte da conta com a MAIOR fração
    /// de janela crítica (pior caso visível — mesmo critério D5 do menu bar;
    /// empate vence a primeira, ordem do ciclo: canônica primeiro). Nenhuma
    /// fração conhecida → primeira conta (modo local, comportamento F2).
    /// `fetchedAt` = o mais recente. Histórico provider-wide é aplicado pelo
    /// ciclo por cima. Com UMA conta o resultado equivale ao caminho anterior.
    static func aggregateAccountsDisplay(
        _ accounts: [AccountDisplay], base previous: ProviderDisplay
    ) -> ProviderDisplay {
        guard !accounts.isEmpty else { return previous }
        var result = previous
        result.todayTokens = accounts.reduce(0) { $0 + $1.display.todayTokens }

        var critical: AccountDisplay?
        var bestFraction = -1.0
        for account in accounts {
            guard let fraction = criticalWindow(in: account.display.windows)?.usedFraction,
                  fraction > bestFraction else { continue }
            bestFraction = fraction
            critical = account
        }
        let source = critical ?? accounts[0]
        let criticalWindowValue = criticalWindow(in: source.display.windows)
        result.windows = source.display.windows
        result.percent = criticalWindowValue?.usedFraction.map { $0 * 100 }
        result.resetsAt = criticalWindowValue?.resetsAt
        result.pacing = source.display.pacing
        result.authState = source.display.authState
        result.source = source.display.source
        result.fetchedAt = accounts.map(\.display.fetchedAt).max() ?? previous.fetchedAt
        result.accounts = accounts
        return result
    }

    // MARK: - Alertas (F5 T2, spec §8)

    /// Avalia o `AlertEngine` sobre os snapshots do ciclo e entrega cada
    /// evento novo pelo gateway (dedupe é responsabilidade do engine — o
    /// coordinator só despacha). Atualiza o estado honesto do painel:
    /// off → `.disabled` (sem tocar em gateway/permissão); ligado → reflete
    /// a autorização REAL do gateway (`enabled`/`notConfigured`/`blocked`).
    /// Internal para os testes de wiring injetarem snapshots direto.
    func dispatchAlerts(
        snapshots: [(provider: ProviderID, account: AccountID, windows: [UsageWindow])],
        now: Date
    ) async {
        let config = await alertEngine.config
        guard config.enabled else {
            store.setAlertsStatus(.disabled)
            return
        }
        let events = await alertEngine.evaluate(snapshots: snapshots, now: now)
        for event in events {
            await notifications.deliver(event)
        }
        switch await notifications.authorizationState() {
        case .granted: store.setAlertsStatus(.enabled)
        case .notDetermined: store.setAlertsStatus(.notConfigured)
        case .denied: store.setAlertsStatus(.blocked)
        }
    }

    // MARK: - Settings vivas (F5 Task 3)

    /// Janela de Settings trocou os providers visíveis no texto do menu bar:
    /// estado vivo + republish imediato (o render gate da F1 cuida de só
    /// re-renderizar quando a string exibida muda de fato). Persistência fica
    /// com o SettingsModel (tabela `settings`); aqui é só o estado em runtime.
    public func applyMenuBarVisibility(_ visible: Set<ProviderID>) {
        guard menuBarVisibleProviders != visible else { return }
        menuBarVisibleProviders = visible
        publish()
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
        // F5 Task 3: o texto do menu bar respeita a visibilidade escolhida
        // na Settings (default = todos).
        store.apply(MenuBarContent(
            providers: displays, visibleProviders: menuBarVisibleProviders))
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

/// Conjunto de leituras de histórico de UM ciclo (F4): 7d/30d totals + série
/// diária do chart + custo do dia + input de pacing POR CONTA. Atravessa a
/// fronteira do `Task.detached` — tudo Sendable (tuplas de Sendable são
/// Sendable). Cada leitura falha INDEPENDENTEMENTE (nil → painel mantém o
/// último valor bom / heartbeat omite — padrão F3).
private struct HistoryStats: Sendable {
    /// `nil` = query 7d falhou → flag do heartbeat omite.
    var week: AppDatabase.WeekTotal?
    /// `nil` = query 30d falhou (o 7d pode ter vindo) → idem.
    var month: AppDatabase.WeekTotal?
    var series: [AppDatabase.DailySeriesRow]
    /// `nil` = query falhou (com DB aberto) → custo do dia some do painel
    /// (mesmo padrão F2/F3: nunca 0 fake).
    var todayCost: Double?
    /// Modelo com mais tokens na janela 7d do provider (F5, linha "Top
    /// model" do painel). `nil` = sem breakdown do provider na janela.
    var topModel: String?
    /// Input do PacingEngine por chave de conta (daily_agg por conta; contas
    /// sem ingest ficam de fora — engine recebe vazio e devolve nil).
    var pacingByAccount: [String: [(day: Date, total: Int64)]]
}
