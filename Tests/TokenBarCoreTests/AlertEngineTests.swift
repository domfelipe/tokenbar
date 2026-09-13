import Foundation
import Testing
@testable import TokenBarCore

/// F5 T2 — AlertEngine: cruzamento de threshold, dedupe 1×, re-arm por queda
/// e por renovação de janela, lembrete de reset 1× por janela, config em
/// settings e persistência do estado que sobrevive restart. Tempo INJETADO
/// (`now` por avaliação) — determinístico, sem sleep real.
@Suite
final class AlertEngineTests {
    let dir: URL
    /// Época base fixa (todo tempo do teste é derivado dela).
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-alerts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeDatabase() throws -> AppDatabase {
        try AppDatabase.open(
            at: dir.appendingPathComponent(AppDatabase.databaseName),
            calendar: .current, pricing: nil)
    }

    func enabledEngine(_ db: AppDatabase, reminder: Int? = nil) async -> AlertEngine {
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [50, 75, 90, 95], resetReminderMinutes: reminder))
        return engine
    }

    func window(
        _ kind: WindowKind, _ fraction: Double?, resetsAt: Date? = nil
    ) -> UsageWindow {
        UsageWindow(kind: kind, usedFraction: fraction, resetsAt: resetsAt, label: kind.rawValue)
    }

    func snapshot(
        _ windows: [UsageWindow], _ provider: ProviderID = .claude, _ key: String = "local"
    ) -> (provider: ProviderID, account: AccountID, windows: [UsageWindow]) {
        (provider: provider, account: AccountID(provider: provider, key: key), windows: windows)
    }

    func thresholdsFired(_ events: [AlertEvent]) -> [Int] {
        events.filter { $0.kind == .threshold }.compactMap(\.thresholdPct)
    }

    // MARK: - Cruzamento e dedupe

    @Test("cruzamento para cima dispara 1×; segue suprimido até re-armar")
    func crossingFiresOnceThenSuppresses() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let weekly = window(.weekly, 0.52, resetsAt: base + 86_400)

        // Primeira observação já acima de 50 → cruza (app aberto no meio da
        // janela alerta; o dedupe PERSISTIDO impede re-disparo no restart).
        let first = await engine.evaluate(snapshots: [snapshot([weekly])], now: base)
        #expect(thresholdsFired(first) == [50])

        // Mesma janela, mesma fração → dedupe, nada novo.
        let repeatEval = await engine.evaluate(snapshots: [snapshot([weekly])], now: base + 60)
        #expect(repeatEval.isEmpty)

        // Sobe para 76 → só o 75 é novo (o 50 segue suprimido).
        let at76 = await engine.evaluate(
            snapshots: [snapshot([window(.weekly, 0.76, resetsAt: base + 86_400)])],
            now: base + 120)
        #expect(thresholdsFired(at76) == [75])
    }

    @Test("re-arm por queda: fração cai abaixo do threshold e cruza de novo")
    func reArmsWhenFractionDropsBelow() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let high = window(.weekly, 0.92, resetsAt: base + 86_400)
        #expect(thresholdsFired(await engine.evaluate(snapshots: [snapshot([high])], now: base)) == [50, 75, 90])

        // 0.80 (< 90, > 75): nada dispara; o 90 re-arma silenciosamente.
        let mid = window(.weekly, 0.80, resetsAt: base + 86_400)
        #expect(await engine.evaluate(snapshots: [snapshot([mid])], now: base + 60).isEmpty)

        // 0.92 de novo (mesma janela): 50/75 continuam suprimidos, o 90
        // re-dispara porque re-armou.
        let again = await engine.evaluate(snapshots: [snapshot([high])], now: base + 120)
        #expect(thresholdsFired(again) == [90])

        // Queda total → re-arma TUDO (nada dispara abaixo de 50).
        let low = window(.weekly, 0.40, resetsAt: base + 86_400)
        #expect(await engine.evaluate(snapshots: [snapshot([low])], now: base + 180).isEmpty)

        // E o próximo cruzamento acima (agora ≥ 95) re-dispara os quatro.
        let maxed = window(.weekly, 0.96, resetsAt: base + 86_400)
        #expect(thresholdsFired(await engine.evaluate(snapshots: [snapshot([maxed])], now: base + 240)) == [50, 75, 90, 95])
    }

    @Test("re-arm por renovação: resetsAt renovado re-dispara na mesma fração")
    func reArmsWhenWindowRenews() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let week1 = window(.weekly, 0.96, resetsAt: base + 86_400)
        #expect(thresholdsFired(await engine.evaluate(snapshots: [snapshot([week1])], now: base)) == [50, 75, 90, 95])

        // Mesma fração, MESMA janela → suprimido.
        #expect(await engine.evaluate(snapshots: [snapshot([week1])], now: base + 60).isEmpty)

        // Janela renovou (novo resetsAt), fração igual → dispara de novo.
        let week2 = window(.weekly, 0.96, resetsAt: base + 7 * 86_400)
        let renewed = await engine.evaluate(snapshots: [snapshot([week2])], now: base + 7 * 86_400)
        #expect(thresholdsFired(renewed) == [50, 75, 90, 95])
    }

    @Test("janelas independentes: session e weekly dedupam separados")
    func windowKindsDedupeSeparately() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let windows = [
            window(.session, 0.91, resetsAt: base + 3_600),
            window(.weekly, 0.91, resetsAt: base + 86_400),
        ]
        let events = await engine.evaluate(snapshots: [snapshot([windows[0]])], now: base)
        #expect(thresholdsFired(events) == [50, 75, 90])
        // Janela weekly entra depois → dispara os próprios thresholds.
        let weeklyOnly = await engine.evaluate(snapshots: [snapshot(windows)], now: base + 1)
        #expect(thresholdsFired(weeklyOnly) == [50, 75, 90])
    }

    // MARK: - Lembrete de reset

    @Test("lembrete de reset: 1× por janela dentro de [resetsAt−N, resetsAt)")
    func resetReminderFiresOncePerWindow() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db, reminder: 15)

        // Fração baixa (sem threshold), reset em 10 min → dentro da janela
        // do lembrete (dueAt = resetsAt − 15min < now) → dispara.
        let due = window(.weekly, 0.10, resetsAt: base + 600)
        var events = await engine.evaluate(snapshots: [snapshot([due])], now: base)
        #expect(events.count == 1)
        #expect(events.first?.kind == .resetReminder)
        #expect(events.first?.thresholdPct == nil)
        #expect(events.first?.resetsAt == base + 600)

        // Mesma janela de novo → 1× só.
        events = await engine.evaluate(snapshots: [snapshot([due])], now: base + 60)
        #expect(events.isEmpty)

        // Ainda fora do horário (reset em 30 min, lembrete de 15) → nada.
        let early = window(.weekly, 0.10, resetsAt: base + 1_800)
        events = await engine.evaluate(snapshots: [snapshot([early])], now: base + 120)
        #expect(events.isEmpty)

        // Janela RENOVADA dentro do horário → novo lembrete (renewal re-arma).
        let renewed = window(.weekly, 0.10, resetsAt: base + 700)
        events = await engine.evaluate(snapshots: [snapshot([renewed])], now: base + 180)
        #expect(events.first?.kind == .resetReminder)

        // Reset já passado → nunca (lembrete de janela vencida é mentira).
        let past = window(.weekly, 0.10, resetsAt: base - 60)
        events = await engine.evaluate(snapshots: [snapshot([past])], now: base + 240)
        #expect(events.isEmpty)
    }

    // MARK: - Honestidade (Red Team)

    @Test("fração nil ou não-finita é ignorada — nada inventado, nada trapando")
    func nilOrNonFiniteFractionsIgnored() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let windows = [
            window(.weekly, nil, resetsAt: base + 86_400),
            window(.session, Double.nan, resetsAt: base + 3_600),
            window(.daily, Double.infinity, resetsAt: base + 86_400),
        ]
        #expect(await engine.evaluate(snapshots: [snapshot([windows[0]])], now: base).isEmpty)
        #expect(await engine.evaluate(snapshots: [snapshot([windows[1]])], now: base).isEmpty)
        #expect(await engine.evaluate(snapshots: [snapshot([windows[2]])], now: base).isEmpty)
    }

    @Test("frações absurdas saturam em 0...1 antes de comparar")
    func fractionSaturatesBeforeCompare() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let over = window(.weekly, 2.5, resetsAt: base + 86_400)
        let events = await engine.evaluate(snapshots: [snapshot([over])], now: base)
        #expect(thresholdsFired(events) == [50, 75, 90, 95])
        // O evento carrega a fração SATURADA.
        #expect(events.allSatisfy { $0.usedFraction == 1.0 })
    }

    @Test("contas isoladas: alerta de uma conta não vaza na outra")
    func accountsAreIsolated() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let hot = snapshot([window(.weekly, 0.91, resetsAt: base + 86_400)], .claude, "work")
        let calm = snapshot([window(.weekly, 0.20, resetsAt: base + 86_400)], .claude, "personal")
        let events = await engine.evaluate(snapshots: [hot, calm], now: base)
        #expect(thresholdsFired(events) == [50, 75, 90])
        #expect(events.allSatisfy { $0.account.key == "work" })
    }

    @Test("config desligada (default) → nenhum evento e nenhum estado gravado")
    func disabledProducesNothing() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)  // default: enabled false
        let hot = snapshot([window(.weekly, 0.99, resetsAt: base + 86_400)], .codex, "local")
        #expect(await engine.evaluate(snapshots: [hot], now: base).isEmpty)
        let config = await engine.config
        #expect(config == .default)
        #expect(config.enabled == false)
        #expect(try db.setting(forKey: AlertEngine.stateKey) == nil)
    }

    // MARK: - Config em settings (T3 consome)

    @Test("config em settings: thresholds customizados via apply sobrevivem a restart")
    func configRoundtripThroughSettings() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [80, 30, 30, 150], resetReminderMinutes: 20))

        // Normalização: duplicata fora, 150 fora, ordenado.
        var config = await engine.config
        #expect(config.thresholds == [30, 80])
        #expect(config.enabled)
        #expect(config.resetReminderMinutes == 20)

        // Persistida: avaliação usa a config aplicada (só 30 e 80 disparam).
        let hot = snapshot([window(.weekly, 0.85, resetsAt: base + 86_400)], .claude, "local")
        #expect(thresholdsFired(await engine.evaluate(snapshots: [hot], now: base)) == [30, 80])

        // Restart: novo engine no MESMO banco relê config e estado.
        let reopened = AlertEngine(database: db)
        config = await reopened.config
        #expect(config.enabled)
        #expect(config.thresholds == [30, 80])
        #expect(config.resetReminderMinutes == 20)
    }

    @Test("config corrompida em settings → default por campo, sem crash")
    func corruptedConfigFallsBackToDefaults() async throws {
        let db = try makeDatabase()
        try db.setSetting("{\"jit\":", forKey: AlertEngine.configThresholdsKey)
        try db.setSetting("sim", forKey: AlertEngine.configEnabledKey)
        try db.setSetting("muito", forKey: AlertEngine.configReminderKey)
        let engine = AlertEngine(database: db)
        let config = await engine.config
        #expect(config == .default)

        // Default DESLIGADO: mesmo com fração máxima, nada dispara.
        let hot = snapshot([window(.weekly, 1.0, resetsAt: base + 86_400)], .claude, "local")
        #expect(await engine.evaluate(snapshots: [hot], now: base).isEmpty)
    }

    // MARK: - Persistência do dedupe (restart)

    @Test("estado de dedupe sobrevive restart: nada re-dispara após reabrir o banco")
    func dedupeStateSurvivesRestart() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let hot = snapshot([window(.weekly, 0.96, resetsAt: base + 86_400)], .claude, "local")
        #expect(thresholdsFired(await engine.evaluate(snapshots: [hot], now: base)) == [50, 75, 90, 95])
        #expect(try db.setting(forKey: AlertEngine.stateKey) != nil)

        // "Restart": engine novo no MESMO banco → estado relido, zero re-alerta.
        let restarted = await enabledEngine(db)
        #expect(await restarted.evaluate(snapshots: [hot], now: base + 3_600).isEmpty)

        // Queda abaixo → re-arma no estado persistido; nova subida re-dispara.
        let low = snapshot([window(.weekly, 0.10, resetsAt: base + 86_400)], .claude, "local")
        #expect(await restarted.evaluate(snapshots: [low], now: base + 3_660).isEmpty)
        let highAgain = snapshot([window(.weekly, 0.96, resetsAt: base + 86_400)], .claude, "local")
        #expect(thresholdsFired(await restarted.evaluate(snapshots: [highAgain], now: base + 3_720)) == [50, 75, 90, 95])
    }

    @Test("estado corrompido em settings → tratado como vazio, sem crash")
    func corruptedStateFallsBackToEmpty() async throws {
        let db = try makeDatabase()
        try db.setSetting("não-sou-json", forKey: AlertEngine.stateKey)
        let engine = await enabledEngine(db)
        let hot = snapshot([window(.weekly, 0.96, resetsAt: base + 86_400)], .claude, "local")
        // Pode re-alertar uma vez (degradação honesta); nunca crash.
        #expect(thresholdsFired(await engine.evaluate(snapshots: [hot], now: base)) == [50, 75, 90, 95])
    }

    @Test("lembrete disparado sobrevive a restart (1× por janela MESMO reabrindo)")
    func reminderStateSurvivesRestart() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db, reminder: 15)
        let due = snapshot([window(.weekly, 0.10, resetsAt: base + 600)], .claude, "local")
        #expect((await engine.evaluate(snapshots: [due], now: base)).count == 1)

        let restarted = await enabledEngine(db, reminder: 15)
        #expect(await restarted.evaluate(snapshots: [due], now: base + 60).isEmpty)
    }

    @Test("ordem dos eventos é determinística (provider, conta, janela, threshold)")
    func eventsAreDeterministicallyOrdered() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)
        let zai = snapshot([window(.session, 0.99, resetsAt: base + 3_600)], .zai, "local")
        let claude = snapshot([window(.weekly, 0.99, resetsAt: base + 86_400)], .claude, "work")
        let events = await engine.evaluate(snapshots: [zai, claude], now: base)
        let ids = events.map { "\($0.provider.rawValue)-\($0.account.key)-\($0.windowKind.rawValue)-\($0.thresholdPct ?? -1)" }
        #expect(ids == [
            "claude-work-weekly-50", "claude-work-weekly-75",
            "claude-work-weekly-90", "claude-work-weekly-95",
            "zai-local-session-50", "zai-local-session-75",
            "zai-local-session-90", "zai-local-session-95",
        ])
    }

    @Test("sem DB: dedupe funciona em memória (sessão), persistência é aditiva")
    func withoutDatabaseDedupeStillWorksInMemory() async throws {
        let memoryEngine = AlertEngine(database: nil)
        await memoryEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50], resetReminderMinutes: nil))
        let hot = snapshot([window(.weekly, 0.60, resetsAt: base + 86_400)], .claude, "local")
        #expect(await memoryEngine.evaluate(snapshots: [hot], now: base).count == 1)
        #expect(await memoryEngine.evaluate(snapshots: [hot], now: base + 60).isEmpty)
    }

    // MARK: - Orçamento (F7 Spend control)

    /// Calendar UTC fixo: a projeção depende do DIA do mês, então o teste não
    /// pode depender do fuso da máquina.
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// base = 2023-11-14T22:13:20Z → novembro/2023 (30 dias), dia 14.
    func november2023() -> AppDatabase.MonthWindow {
        AppDatabase.MonthWindow(
            start: utc.date(from: DateComponents(year: 2023, month: 11, day: 1))!,
            next: utc.date(from: DateComponents(year: 2023, month: 12, day: 1))!)
    }

    func december2023() -> AppDatabase.MonthWindow {
        AppDatabase.MonthWindow(
            start: utc.date(from: DateComponents(year: 2023, month: 12, day: 1))!,
            next: utc.date(from: DateComponents(year: 2024, month: 1, day: 1))!)
    }

    @Test("orçamento: dispara nos dois tipos (gasto e projeção), deduplica e re-arma")
    func budgetFiresForSpendAndProjection() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [10, 50, 90], resetReminderMinutes: nil))
        let month = november2023()
        let budget = BudgetConfig(monthlyUSD: 100, perProvider: [:])

        // $12 de $100 no dia 14: gasto cruza 10%; projeção (12/14×30 = $25.71)
        // também cruza 10% — dois eventos, tipos distintos.
        let first = await engine.evaluateBudgets(
            spend: [.claude: 12], budget: budget, month: month, now: base, calendar: utc)
        #expect(first.filter { $0.kind == .budget }.compactMap(\.thresholdPct) == [10])
        #expect(first.filter { $0.kind == .budgetProjection }.compactMap(\.thresholdPct) == [10])
        // Forma do evento: janela mensal, conta agregada e reset na virada do mês.
        #expect(first.allSatisfy { $0.windowKind == .monthly })
        #expect(first.allSatisfy { $0.account.key == AccountID.allAccountsKey })
        #expect(first.allSatisfy { $0.resetsAt == month.next })
        #expect(first.allSatisfy { $0.provider == .claude })

        // Mesmo gasto de novo: nada (dedupe 1× por threshold e por tipo).
        #expect(await engine.evaluateBudgets(
            spend: [.claude: 12], budget: budget, month: month,
            now: base + 3_600, calendar: utc).isEmpty)

        // $60: gasto cruza 50%; projeção (60/14×30 = $128.57) cruza 50% e 90%.
        let higher = await engine.evaluateBudgets(
            spend: [.claude: 60], budget: budget, month: month,
            now: base + 7_200, calendar: utc)
        #expect(higher.filter { $0.kind == .budget }.compactMap(\.thresholdPct) == [50])
        #expect(higher.filter { $0.kind == .budgetProjection }.compactMap(\.thresholdPct) == [50, 90])

        // Cai para $2 (gasto 2% e projeção 4,3%, ambos abaixo de 10%) e volta a
        // $12: re-arma o 10% nos DOIS tipos.
        #expect(await engine.evaluateBudgets(
            spend: [.claude: 2], budget: budget, month: month,
            now: base + 10_800, calendar: utc).isEmpty)
        let rearmed = await engine.evaluateBudgets(
            spend: [.claude: 12], budget: budget, month: month,
            now: base + 14_400, calendar: utc)
        #expect(rearmed.filter { $0.kind == .budget }.compactMap(\.thresholdPct) == [10])
        #expect(rearmed.filter { $0.kind == .budgetProjection }.compactMap(\.thresholdPct) == [10])
    }

    @Test("orçamento: sem teto, sem custo computável ou alertas desligados não há evento")
    func budgetRequiresLimitAndComputableCost() async throws {
        let db = try makeDatabase()
        let engine = await enabledEngine(db)  // thresholds [50, 75, 90, 95]
        let month = november2023()

        // Sem orçamento nenhum → nada (e o master switch não é a razão).
        #expect(await engine.evaluateBudgets(
            spend: [.claude: 90], budget: .empty, month: month, now: base, calendar: utc).isEmpty)

        // Custo do mês desconhecido (nil = nenhum evento com preço) → nada: sem
        // base real não há aviso (NULL ≠ 0 — $0 de verdade também não alerta).
        #expect(await engine.evaluateBudgets(
            spend: [.claude: nil], budget: BudgetConfig(monthlyUSD: 10, perProvider: [:]),
            month: month, now: base, calendar: utc).isEmpty)
        #expect(await engine.evaluateBudgets(
            spend: [.claude: 0], budget: BudgetConfig(monthlyUSD: 10, perProvider: [:]),
            month: month, now: base, calendar: utc).isEmpty)

        // Teto do provider vence o global; sem teto próprio cai no global.
        let budget = BudgetConfig(monthlyUSD: 100, perProvider: [.codex: 10])
        let events = await engine.evaluateBudgets(
            spend: [.claude: 400, .codex: 9, .zai: 400], budget: budget,
            month: month, now: base, calendar: utc)
        // claude: 400% do global (todos os thresholds); codex: $9 de um teto de
        // $10 = 90% (cruza 50, 75 e 90 — o teto do provider vence o global);
        // zai: 400% do global.
        #expect(events.filter { $0.provider == .codex }.filter { $0.kind == .budget }
            .compactMap(\.thresholdPct) == [50, 75, 90])
        #expect(events.contains { $0.provider == .claude && $0.kind == .budget })

        // Alertas desligados: o master switch manda, mesmo com teto e gasto.
        let off = AlertEngine(database: db)
        await off.apply(config: AlertConfig(
            enabled: false, thresholds: [50], resetReminderMinutes: nil))
        #expect(await off.evaluateBudgets(
            spend: [.claude: 400], budget: BudgetConfig(monthlyUSD: 10, perProvider: [:]),
            month: month, now: base, calendar: utc).isEmpty)
    }

    @Test("orçamento: dedupe sobrevive ao restart e re-arma quando o mês vira")
    func budgetStateSurvivesRestartAndNewMonth() async throws {
        let db = try makeDatabase()
        let budget = BudgetConfig(monthlyUSD: 100, perProvider: [:])
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [10], resetReminderMinutes: nil))
        let november = november2023()
        #expect(await engine.evaluateBudgets(
            spend: [.claude: 12], budget: budget, month: november,
            now: base, calendar: utc).isEmpty == false)

        // Restart: MESMO mês → estado persistido impede re-disparo.
        let restarted = AlertEngine(database: db)
        #expect(await restarted.evaluateBudgets(
            spend: [.claude: 12], budget: budget, month: november,
            now: base + 60, calendar: utc).isEmpty)

        // Mês NOVO: a chave do mês anterior é podada e o cruzamento dispara de novo.
        let december = december2023()
        let newMonth = await restarted.evaluateBudgets(
            spend: [.claude: 12], budget: budget, month: december,
            now: utc.date(from: DateComponents(year: 2023, month: 12, day: 14))!,
            calendar: utc)
        #expect(newMonth.contains { $0.kind == .budget && $0.thresholdPct == 10 })
        #expect(newMonth.allSatisfy { $0.resetsAt == december.next })
    }
}
