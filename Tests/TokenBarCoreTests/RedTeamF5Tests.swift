import Foundation
import Testing
@testable import TokenBarCore

/// Red Team F5 (Task 7) — Core: alert storm por oscilação de fração (94↔96 no
/// threshold 95), flip `resetsAt` nil↔data, settings/config corrompidas e
/// frota de 50 contas no engine e no registry. Fixtures 100% sintéticas.
///
/// Contratos PINADOS aqui (doc `docs/qa/f5-redteam-report.md`):
/// - SEM histerese é o CONTRATO (spec §8: dispara 1× por cruzamento até cair
///   abaixo ou renovar) — oscilação em torno do threshold re-dispara a cada
///   cruzamento pra cima, 1 evento por cruzamento, nunca mais de 1 por
///   avaliação por (conta, janela, threshold);
/// - flip nil↔data em `resetsAt` re-arma (renovação por definição) — custo
///   máximo: 1 notificação por flip, mesma substituição de banner (identifier);
/// - settings/config corrompidas → defaults campo a campo (nunca crash, nunca
///   valor intermediário inventado).
@Suite
final class RedTeamF5AlertTests {
    let dir: URL
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-rt5-\(UUID().uuidString)", isDirectory: true)
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

    private func account(_ key: String) -> AccountID {
        AccountID(provider: .claude, key: key)
    }

    private func window(fraction: Double?, resetsAt: Date?) -> UsageWindow {
        UsageWindow(kind: .weekly, usedFraction: fraction, resetsAt: resetsAt, label: "Semanal")
    }

    // MARK: - Alert storm (94 ↔ 96 no 95)

    @Test("alert storm: oscilação 0.94↔0.96 no threshold 95 re-dispara a cada cruzamento (1 evento por cruzamento — contrato sem histerese)")
    func oscillationAroundThresholdRefiresPerCrossing() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(enabled: true, thresholds: [95], resetReminderMinutes: nil))

        func evaluate(_ fraction: Double, _ tick: Int) async -> [AlertEvent] {
            await engine.evaluate(
                snapshots: [(provider: ProviderID.claude, account: account("local"),
                             windows: [window(fraction: fraction, resetsAt: base.addingTimeInterval(86_400))])],
                now: base.addingTimeInterval(Double(tick) * 60))
        }

        // 0.94 abaixo → nada; 0.96 cruza → dispara; 0.94 re-arma em silêncio;
        // 0.96 cruza de novo → dispara DE NOVO (é o contrato — sem histerese).
        let first = await evaluate(0.94, 0)
        #expect(first.isEmpty)
        let second = await evaluate(0.96, 1)
        #expect(second.count == 1)
        #expect(second[0].thresholdPct == 95)
        let third = await evaluate(0.94, 2)
        #expect(third.isEmpty, "cair abaixo não dispara; só re-arma")
        let fourth = await evaluate(0.96, 3)
        #expect(fourth.count == 1, "re-cruzamento dispara de novo (1× por cruzamento)")

        // Oscilação longa: N cruzamentos → N disparos, nunca 2 por avaliação.
        var total = 2  // os dois disparos acima
        var tick = 4
        for _ in 0..<20 {
            let down = await evaluate(0.94, tick); tick += 1
            let up = await evaluate(0.96, tick); tick += 1
            #expect(down.isEmpty)
            #expect(up.count == 1)
            total += up.count
        }
        #expect(total == 22, "1 notificação por cruzamento: 2 + 20 (rate máximo documentado)")

        // Persistência do estado sobrevive ao restart: novo engine com o MESMO
        // banco NÃO re-dispara com a fração ainda acima (dedupe durável).
        let reborn = AlertEngine(database: db)
        let again = await reborn.evaluate(
            snapshots: [(provider: ProviderID.claude, account: account("local"),
                         windows: [window(fraction: 0.96, resetsAt: base.addingTimeInterval(86_400))])],
            now: base.addingTimeInterval(Double(tick) * 60))
        #expect(again.isEmpty, "último estado (0.96 acima) foi persistido — restart não re-dispara")
    }

    // MARK: - Flip resetsAt nil ↔ data

    @Test("flip resetsAt nil↔data: re-arma por renovação (1 disparo por flip, fração constante)")
    func resetsAtFlipRefiresOncePerFlip() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(enabled: true, thresholds: [95], resetReminderMinutes: nil))
        let renewal = base.addingTimeInterval(86_400)

        func evaluate(_ resetsAt: Date?, _ tick: Int) async -> [AlertEvent] {
            await engine.evaluate(
                snapshots: [(provider: ProviderID.claude, account: account("local"),
                             windows: [window(fraction: 0.96, resetsAt: resetsAt)])],
                now: base.addingTimeInterval(Double(tick) * 60))
        }

        #expect(await evaluate(nil, 0).count == 1, "primeira observação acima dispara")
        #expect(await evaluate(renewal, 1).count == 1, "nil → data é renovação: re-dispara 1×")
        #expect(await evaluate(nil, 2).count == 1, "data → nil é flip de novo: 1×")
        #expect(await evaluate(renewal, 3).count == 1, "nil → data: 1×")
        #expect(await evaluate(renewal, 4).isEmpty, "mesmo resetsAt + fração acima → suprimido")

        // Os disparos carregam o resetsAt DA VEZ (nada de estado velho).
        let events = [await evaluate(base.addingTimeInterval(172_800), 5)].flatMap { $0 }
        #expect(events.count == 1)
        #expect(events.first?.resetsAt == base.addingTimeInterval(172_800))
    }

    // MARK: - 50 contas num evaluate

    @Test("50 contas: um evaluate cobre todas — 50 eventos determinísticos, dedupe no 2º ciclo")
    func fiftyAccountsInOneEvaluation() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(enabled: true, thresholds: [95], resetReminderMinutes: nil))

        let snapshots: [(provider: ProviderID, account: AccountID, windows: [UsageWindow])] = (0..<50).map { i in
            (provider: ProviderID.openrouter,
             account: AccountID(provider: .openrouter, key: "acct-rt-\(i)"),
             windows: [window(fraction: i % 2 == 0 ? 0.96 : 0.50, resetsAt: base.addingTimeInterval(86_400))])
        }
        let first = await engine.evaluate(snapshots: snapshots, now: base)
        #expect(first.count == 25, "só as 25 contas acima de 95 disparam")
        #expect(Set(first.map(\.account.key)).count == 25, "uma conta nunca dispara 2× no mesmo evaluate")
        #expect(first == first.sorted { AlertEngine.ordering($0) < AlertEngine.ordering($1) },
                "ordem determinística (provider, conta, janela, tipo, threshold)")

        let second = await engine.evaluate(snapshots: snapshots, now: base.addingTimeInterval(60))
        #expect(second.isEmpty, "2º ciclo igual → dedupe total")

        // Persistiu; restart não re-dispara.
        let reborn = AlertEngine(database: db)
        #expect(await reborn.evaluate(snapshots: snapshots, now: base.addingTimeInterval(120)).isEmpty)
    }

    @Test("registry com 50 contas OpenRouter: add/activeAccounts/labels ordenados, sem colisão de keys")
    func registryWithFiftyOpenRouterKeys() async throws {
        let db = try makeDatabase()
        let registry = AccountRegistry(database: db)
        var keys = Set<String>()
        for i in 0..<50 {
            let entry = try registry.add(
                provider: .openrouter, label: String(format: "Key %02d", i),
                credentialPath: "/tmp/rt5/fake-key-\(i).txt")
            #expect(keys.insert(entry.accountKey).inserted, "account_key único")
        }
        let active = try registry.activeAccounts(provider: .openrouter)
        #expect(active.count == 50)
        #expect(active.map(\.label) == active.map(\.label).sorted(), "ordem por label (display estável)")
        // Isolamento por provider: nada vaza para outro provider.
        #expect(try registry.activeAccounts(provider: .claude).isEmpty)
        // Toggle batch: 50 off → discovery vazia (o ciclo para de cobrir).
        for entry in active {
            try registry.setActive(false, provider: .openrouter, accountKey: entry.accountKey)
        }
        #expect(try registry.activeAccounts(provider: .openrouter).isEmpty)
        #expect(try registry.accounts(provider: .openrouter).count == 50, "registros permanecem p/ reativação")
    }
}

/// Red Team F5 — settings/config corrompidas (banco tamperado): thresholds fora
/// de ordem [95,50], JSON lixo, valores fora de faixa → defaults campo a campo
/// (honestidade AlertEngine/AppSettingsStore), nunca crash.
@Suite
final class RedTeamF5SettingsTamperTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-rt5cfg-\(UUID().uuidString)", isDirectory: true)
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

    @Test("thresholds tamperados [95,50] → sanitizados para [50,95] no apply E no readConfig")
    func outOfOrderThresholdsAreSanitized() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        let sanitized = AlertConfig(enabled: true, thresholds: [95, 50], resetReminderMinutes: nil)
        #expect(sanitized.thresholds == [50, 95], "init satura, remove duplicata e ordena")
        await engine.apply(config: sanitized)

        let read = AlertEngine.readConfig(database: db)
        #expect(read.thresholds == [50, 95], "o que ficou no banco é a versão ordenada")
        // Config duplicada/limites: [95,95,0,101,50] → [50,95] (fora de 1...100 fora).
        let wild = AlertConfig(enabled: true, thresholds: [95, 95, 0, 101, 50], resetReminderMinutes: nil)
        #expect(wild.thresholds == [50, 95])
    }

    @Test("JSON lixo em alerts:* → defaults campo a campo; estado corrompido → vazio sem crash")
    func garbageAlertSettingsFallBackToDefaults() async throws {
        let db = try makeDatabase()
        try db.setSetting(#"{"hackedi": true}"#, forKey: "alerts:enabled")
        try db.setSetting("not-json[", forKey: "alerts:thresholds")
        try db.setSetting("\"trinta\"", forKey: "alerts:resetReminderMinutes")
        try db.setSetting("}{", forKey: "alerts:state")

        let config = AlertEngine.readConfig(database: db)
        #expect(config.enabled == false, "enabled inválido → default OFF")
        #expect(config.thresholds == [50, 75, 90, 95], "thresholds inválidos → default")
        #expect(config.resetReminderMinutes == nil, "reminder inválido → default OFF")

        // O engine nasce saudável e avalia normalmente por cima do lixo
        // (apply de config LIGADA — o toggle do usuário; default desligado é
        // só o estado de quem nunca mexeu).
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [50, 75, 90, 95], resetReminderMinutes: nil))
        let events = await engine.evaluate(
            snapshots: [(provider: ProviderID.claude,
                         account: AccountID(provider: .claude, key: "local"),
                         windows: [UsageWindow(kind: .weekly, usedFraction: 0.97, resetsAt: nil, label: "Semanal")])],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(events.count == 4, "defaults [50,75,90,95]: primeira observação 97% dispara os 4")
    }

    @Test("intervalos/visibilidade tamperados → defaults do campo (AppSettingsStore)")
    func garbageAppSettingsFallBackToDefaults() throws {
        let db = try makeDatabase()
        try db.setSetting("6000", forKey: AppSettingsStore.menuIntervalKey)   // fora da faixa
        try db.setSetting("cinco", forKey: AppSettingsStore.idleIntervalKey)  // tipo errado
        try db.setSetting("true", forKey: AppSettingsStore.visibleTouchedKey)
        try db.setSetting("{{{", forKey: AppSettingsStore.menuBarVisibleKey)

        let store = AppSettingsStore(database: db)
        #expect(store.loadMenuIntervalSeconds() == 60)
        #expect(store.loadIdleIntervalSeconds() == 300)
        #expect(store.loadVisibleProviders() == Set(ProviderID.allCases), "lixo + touched → default (todos)")
    }
}
