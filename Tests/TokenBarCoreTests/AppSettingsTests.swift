import Foundation
import Testing
@testable import TokenBarCore

/// F5 Task 3 — AppSettingsStore: roundtrip na tabela `settings`, faixas da
/// UI aplicadas na escrita, valores corrompidos/fora de faixa → DEFAULT
/// (padrão Red Team) e degradação sem DB (leitura default, escrita no-op).
/// Inclui o caminho que a janela de Settings usa para ler a config de
/// alertas (`AlertEngine.readConfig`) e os setters vivos do scheduler.
@Suite
final class AppSettingsTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-settings-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Intervalos

    @Test("intervalos: default da spec §7 quando nunca salvos")
    func defaultsWhenNothingSaved() throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        #expect(store.loadMenuIntervalSeconds() == 60)
        #expect(store.loadIdleIntervalSeconds() == 300)
    }

    @Test("intervalos: roundtrip na tabela settings")
    func intervalRoundtrip() throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        store.saveMenuIntervalSeconds(120)
        store.saveIdleIntervalSeconds(900)
        #expect(store.loadMenuIntervalSeconds() == 120)
        #expect(store.loadIdleIntervalSeconds() == 900)
        // Nova instância sobre o MESMO banco (restart do app) lê o mesmo.
        #expect(AppSettingsStore(database: db).loadMenuIntervalSeconds() == 120)
        #expect(AppSettingsStore(database: db).loadIdleIntervalSeconds() == 900)
    }

    @Test("intervalos: escrita fora da faixa da UI é recusada (valor anterior intacto)")
    func outOfRangeSaveIsRejected() throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        store.saveMenuIntervalSeconds(90)
        store.saveMenuIntervalSeconds(10)   // < 30 (mínimo da UI)
        store.saveMenuIntervalSeconds(999)  // > 300 (teto da UI)
        #expect(store.loadMenuIntervalSeconds() == 90)
        store.saveIdleIntervalSeconds(30)    // < 60
        store.saveIdleIntervalSeconds(10_000)  // > 1800
        #expect(store.loadIdleIntervalSeconds() == 300)  // default intacto
    }

    @Test("intervalos: valor corrompido ou fora de faixa no banco → default")
    func corruptedIntervalsFallBackToDefaults() throws {
        let db = try makeDatabase()
        try db.setSetting("{\"jit\":", forKey: AppSettingsStore.menuIntervalKey)
        try db.setSetting("30000", forKey: AppSettingsStore.idleIntervalKey)  // JSON string, não Int
        let store = AppSettingsStore(database: db)
        #expect(store.loadMenuIntervalSeconds() == 60)
        #expect(store.loadIdleIntervalSeconds() == 300)
        // Número válido porém FORA da faixa → default também (banco velho/tamper).
        let encoder = JSONEncoder()
        try db.setSetting(
            String(decoding: encoder.encode(5), as: UTF8.self),
            forKey: AppSettingsStore.idleIntervalKey)
        #expect(store.loadIdleIntervalSeconds() == 300)
    }

    // MARK: - Visibilidade do menu bar

    @Test("visibilidade: default = todos; roundtrip preserva o conjunto salvo")
    func visibilityRoundtrip() throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        #expect(store.loadVisibleProviders() == Set(ProviderID.allCases))

        var visible = Set(ProviderID.allCases)
        visible.remove(.gemini)
        visible.remove(.zai)
        store.saveVisibleProviders(visible)
        #expect(store.loadVisibleProviders() == visible)
        #expect(AppSettingsStore(database: db).loadVisibleProviders() == visible)
    }

    @Test("visibilidade: conjunto vazio é escolha válida (menu vira 'TB'); ids desconhecidos não contam")
    func emptyAndUnknownVisibility() throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        store.saveVisibleProviders([])
        #expect(store.loadVisibleProviders() == [])

        // JSON de versão futura com id desconhecido → carrega o que der (a
        // flag touched existe porque o save acima a gravou).
        try db.setSetting(
            String(decoding: JSONEncoder().encode(["claude", "warp"]), as: UTF8.self),
            forKey: AppSettingsStore.menuBarVisibleKey)
        #expect(store.loadVisibleProviders() == [.claude])
    }

    // MARK: - Migração visibleProvidersTouched (F5 T7, carry-forward T4/T5)

    @Test("migração: banco F4 legado (lista SEM flag touched) → novos providers ficam VISÍVEIS")
    func legacyListWithoutTouchedFlagShowsNewProviders() throws {
        let db = try makeDatabase()
        // Exatamente o que um F4 gravava: o conjunto COMPLETO da época
        // (claude/codex/gemini/zai), sem flag — os 6 F5 não existiam lá.
        try db.setSetting(
            String(decoding: JSONEncoder().encode(
                ["claude", "codex", "gemini", "zai"]), as: UTF8.self),
            forKey: AppSettingsStore.menuBarVisibleKey)
        let store = AppSettingsStore(database: db)
        #expect(store.loadVisibleProviders() == Set(ProviderID.allCases))
        #expect(store.loadVisibleProviders().isSuperset(of: [.cursor, .openrouter, .alibaba, .antigravity, .deepseek, .grok]))
    }

    @Test("migração: após o 1º save a flag existe — lista persistida manda (novos nascem escondidos)")
    func touchedFlagMakesPersistedListAuthoritative() throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        store.saveVisibleProviders([.claude, .codex])
        // "Novo provider" surgindo depois do usuário editar uma vez:
        try db.setSetting("false", forKey: AppSettingsStore.visibleTouchedKey)  // flag presente
        try db.setSetting(
            String(decoding: JSONEncoder().encode(["claude"]), as: UTF8.self),
            forKey: AppSettingsStore.menuBarVisibleKey)
        #expect(store.loadVisibleProviders() == [.claude])
        // Flag removida (rollback/repair manual) → default de novo.
        try db.setSetting(nil, forKey: AppSettingsStore.visibleTouchedKey)
        #expect(store.loadVisibleProviders() == Set(ProviderID.allCases))
    }

    // MARK: - Sem DB (degradação)

    @Test("sem DB: leitura dá default e escrita é no-op (nunca crash)")
    func nilDatabaseDegrades() {
        let store = AppSettingsStore(database: nil)
        #expect(store.loadMenuIntervalSeconds() == 60)
        #expect(store.loadIdleIntervalSeconds() == 300)
        #expect(store.loadVisibleProviders() == Set(ProviderID.allCases))
        store.saveMenuIntervalSeconds(120)
        store.saveIdleIntervalSeconds(120)
        store.saveVisibleProviders([.claude])
        #expect(store.loadMenuIntervalSeconds() == 60)
        #expect(store.loadIdleIntervalSeconds() == 300)
        #expect(store.loadVisibleProviders() == Set(ProviderID.allCases))
    }

    // MARK: - Config de alertas pela MESMA janela (leitura única)

    @Test("AlertEngine.readConfig: janela de Settings lê o que o engine aplicou")
    func readConfigMatchesAppliedEngineConfig() async throws {
        let db = try makeDatabase()
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [40, 70, 95], resetReminderMinutes: 15))
        let read = AlertEngine.readConfig(database: db)
        #expect(read.enabled)
        #expect(read.thresholds == [40, 70, 95])
        #expect(read.resetReminderMinutes == 15)
        // Sem DB → defaults (nada inventado).
        #expect(AlertEngine.readConfig(database: nil) == .default)
    }
}
