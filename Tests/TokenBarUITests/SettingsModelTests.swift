import Foundation
import Observation
import os
import Testing
import TokenBarCore
@testable import TokenBarUI

/// Fake do SMAppService (F5 Task 3): NUNCA tocamos no serviço real em teste.
/// Registra as chamadas e permite injetar falha de register/unregister.
/// Lock com escopo síncrono (OSAllocatedUnfairLock — NSLock é proibido em
/// contexto async, padrão do repo).
final class FakeLoginService: LoginServiceManaging, @unchecked Sendable {
    private struct State {
        var status: LoginItemStatus
        var registerCalls = 0
        var unregisterCalls = 0
    }
    /// Quando não-nil, register/unregister falham com este erro (o estado do
    /// serviço NÃO muda — igual ao sistema real).
    var failure: (any Error)?

    private let lock = OSAllocatedUnfairLock<State>(
        initialState: State(status: .notRegistered))

    init(status: LoginItemStatus = .notRegistered) {
        lock.withLock { $0.status = status }
    }

    func status() -> LoginItemStatus {
        lock.withLock { $0.status }
    }

    var registerCalls: Int { lock.withLock { $0.registerCalls } }
    var unregisterCalls: Int { lock.withLock { $0.unregisterCalls } }

    func register() throws {
        try lock.withLock { state in
            state.registerCalls += 1
            if let failure { throw failure }
            state.status = .enabled
        }
    }

    func unregister() throws {
        try lock.withLock { state in
            state.unregisterCalls += 1
            if let failure { throw failure }
            state.status = .notRegistered
        }
    }
}

/// Fake capturável do gateway de notificações — conta requestAuthorization
/// (ruling F5-NOTIF: SÓ o toggle de alertas da Settings pode chamá-lo).
final class CountingNotificationGateway: NotificationSending, @unchecked Sendable {
    private struct State {
        var requestCalls = 0
        var authorizationState: NotificationAuthorizationState
    }

    /// Resposta do pedido de permissão (true = concedida).
    var requestResult: Bool

    private let lock: OSAllocatedUnfairLock<State>

    init(requestResult: Bool = true, state: NotificationAuthorizationState = .notDetermined) {
        self.requestResult = requestResult
        self.lock = OSAllocatedUnfairLock(
            initialState: State(requestCalls: 0, authorizationState: state))
    }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            $0.requestCalls += 1
            $0.authorizationState = requestResult ? .granted : .denied
        }
        return requestResult
    }

    func authorizationState() async -> NotificationAuthorizationState {
        lock.withLock { $0.authorizationState }
    }

    var requestCalls: Int { lock.withLock { $0.requestCalls } }

    func deliver(_ event: AlertEvent) async {}
}

/// F5 Task 3 — SettingsModel: carga do banco, roundtrip, fluxo de alertas
/// com permissão EXPLÍCITA (ruling F5-NOTIF), edição de thresholds com
/// ordem crescente, intervalos aplicados no scheduler vivo e launch at
/// login com serviço FAKE (registro/erro honesto).
@MainActor
@Suite
final class SettingsModelTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-settings-model-\(UUID().uuidString)", isDirectory: true)
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

    func makeModel(
        database: AppDatabase?,
        gateway: CountingNotificationGateway = CountingNotificationGateway(),
        login: FakeLoginService = FakeLoginService(),
        scheduler: AdaptiveScheduler? = nil,
        onVisibility: (@MainActor (Set<ProviderID>) -> Void)? = nil
    ) -> SettingsModel {
        SettingsModel(
            database: database,
            alerts: database.map { AlertEngine(database: $0) },
            scheduler: scheduler,
            notifications: gateway,
            login: login,
            republishVisibility: onVisibility)
    }

    // MARK: - Orçamento mensal (F7 Spend control)

    @Test("orçamento: setter publica e persiste; provider vence o global; inválido não apaga")
    @MainActor
    func budgetSettersPublishAndPersist() async throws {
        let db = try makeDatabase()
        let model = makeModel(database: db)
        #expect(model.budget == .empty)

        await model.setMonthlyBudget(150)
        #expect(model.budget.monthlyUSD == 150)
        #expect(AppSettingsStore(database: db).loadBudget().monthlyUSD == 150)

        await model.setProviderBudget(400, for: .claude)
        #expect(model.budget.budget(for: .claude) == 400)
        #expect(model.budget.budget(for: .codex) == 150)
        #expect(AppSettingsStore(database: db).loadBudget().perProvider == [.claude: 400])

        // Inválido não vira orçamento nem derruba o que já existe.
        await model.setProviderBudget(-1, for: .zai)
        #expect(model.budget.perProvider[.zai] == nil)
        #expect(model.budget.budget(for: .zai) == 150)

        // Sem DB: publica em memória, não persiste, não crasha.
        let detached = makeModel(database: nil)
        await detached.setMonthlyBudget(99)
        #expect(detached.budget.monthlyUSD == 99)
    }

    @Test("orçamento: a janela carrega o que está persistido")
    @MainActor
    func budgetLoadsPersistedState() async throws {
        let db = try makeDatabase()
        AppSettingsStore(database: db).saveBudget(
            BudgetConfig(monthlyUSD: 500, perProvider: [.cursor: 50]))
        let model = makeModel(database: db)
        #expect(model.budget.monthlyUSD == 500)
        #expect(model.budget.perProvider == [.cursor: 50])
    }

    // MARK: - Carga e roundtrip

    @Test("janela carrega o que está persistido (intervalos, visibilidade, alertas)")
    func loadsPersistedState() async throws {
        let db = try makeDatabase()
        let store = AppSettingsStore(database: db)
        store.saveMenuIntervalSeconds(90)
        store.saveIdleIntervalSeconds(1_200)
        store.saveVisibleProviders([.claude, .zai])
        let engine = AlertEngine(database: db)
        await engine.apply(config: AlertConfig(
            enabled: true, thresholds: [40, 70, 95], resetReminderMinutes: 15))

        let model = makeModel(database: db, gateway: CountingNotificationGateway())
        #expect(model.foregroundRefreshSeconds == 90)
        #expect(model.idleRefreshSeconds == 1_200)
        #expect(model.visibleProviders == [.claude, .zai])
        #expect(model.thresholds == [40, 70, 95])
        #expect(model.resetReminderMinutes == 15)
        #expect(model.alertsEnabled == true)
        // Launch at login: estado vem do SERVIÇO, não do banco.
        #expect(model.launchAtLogin == false)
    }

    @Test("roundtrip completo: edições do modelo sobrevivem a um 'restart'")
    func roundtripSurvivesRestart() async throws {
        let db = try makeDatabase()
        let model = makeModel(database: db)
        await model.setForegroundRefresh(seconds: 120)
        await model.setIdleRefresh(seconds: 1_800)
        await model.setProviderVisible(.gemini, false)
        await model.updateThreshold(at: 0, value: 30)
        await model.setResetReminder(minutes: 30)

        // Restart: nova instância sobre o MESMO banco lê tudo.
        let reopened = makeModel(database: db)
        #expect(reopened.foregroundRefreshSeconds == 120)
        #expect(reopened.idleRefreshSeconds == 1_800)
        #expect(reopened.visibleProviders == Set(ProviderID.allCases).subtracting([.gemini]))
        #expect(reopened.thresholds == [30, 75, 90, 95])
        #expect(reopened.resetReminderMinutes == 30)
    }

    // MARK: - Alertas (ruling F5-NOTIF)

    @Test("ligar alerts pede permissão UMA vez; concedida → engine ligado")
    func enablingAlertsRequestsAuthorizationOnce() async throws {
        let db = try makeDatabase()
        let gateway = CountingNotificationGateway(requestResult: true, state: .notDetermined)
        let model = makeModel(database: db, gateway: gateway)
        #expect(model.alertsEnabled == false)  // default DESLIGADO

        await model.setAlertsEnabled(true)
        #expect(gateway.requestCalls == 1)
        #expect(model.alertsEnabled == true)
        #expect(model.notificationStatus == .granted)
        #expect(model.alertsNotice == nil)
        let engine = AlertEngine(database: db)
        #expect(await engine.config.enabled == true)
    }

    @Test("permissão NEGADA → alerts ficam DESLIGADOS com aviso honesto na janela")
    func deniedAuthorizationDisablesAlertsWithNotice() async throws {
        let db = try makeDatabase()
        let gateway = CountingNotificationGateway(requestResult: false, state: .notDetermined)
        let model = makeModel(database: db, gateway: gateway)

        await model.setAlertsEnabled(true)
        #expect(gateway.requestCalls == 1)
        #expect(model.alertsEnabled == false, "negado não liga — honesto")
        #expect(model.notificationStatus == .denied)
        #expect(model.alertsNotice?.contains("System Settings") == true)
        let engine = AlertEngine(database: db)
        #expect(await engine.config.enabled == false)
    }

    @Test("desligar alerts NÃO pede permissão (nunca prompt escondido)")
    func disablingAlertsNeverRequestsAuthorization() async throws {
        let db = try makeDatabase()
        let gateway = CountingNotificationGateway()
        let model = makeModel(database: db, gateway: gateway)
        await model.setAlertsEnabled(false)
        #expect(gateway.requestCalls == 0)
        #expect(model.alertsEnabled == false)
    }

    @Test("thresholds editados chegam ao AlertEngine (e ao banco)")
    func editedThresholdsReachAlertEngine() async throws {
        let db = try makeDatabase()
        let model = makeModel(database: db)
        await model.setAlertsEnabled(true)
        await model.updateThreshold(at: 0, value: 20)
        await model.addThreshold()  // 95 + 5 = 100

        let engine = AlertEngine(database: db)
        let config = await engine.config
        #expect(config.thresholds == [20, 75, 90, 95, 100])
        #expect(config.enabled)

        // Persistido: restart lê os thresholds editados (e não os defaults).
        #expect(AlertEngine.readConfig(database: db).thresholds == [20, 75, 90, 95, 100])
    }

    @Test("edição de thresholds mantém ordem CRESCENTE e faixa 10...100")
    func thresholdEditingKeepsAscendingOrder() async throws {
        let db = try makeDatabase()
        let model = makeModel(database: db)  // [50, 75, 90, 95]

        // Tentativa de cruzar o vizinho: preso em prev+1..next−1.
        await model.updateThreshold(at: 1, value: 10)
        #expect(model.thresholds == [50, 51, 90, 95], "abaixo do antecessor → clamp em 51")

        // Teto do último: 100; piso do primeiro: 10.
        await model.updateThreshold(at: 3, value: 100)
        #expect(model.thresholds[3] == 100)
        await model.updateThreshold(at: 0, value: 3)
        #expect(model.thresholds[0] == 10)

        // Remoção respeita o mínimo de 1; adição vai acima do último.
        await model.removeThreshold(at: 0)
        #expect(model.thresholds == [51, 90, 100])
        await model.updateThreshold(at: 2, value: 100)  // sem-op no teto
        await model.addThreshold()
        #expect(model.thresholds.count == 3, "último == 100 → nada a acrescentar")
        await model.removeThreshold(at: 0)
        await model.removeThreshold(at: 0)
        await model.removeThreshold(at: 0)
        #expect(model.thresholds.count == 1, "nunca fica sem threshold")
        await model.removeThreshold(at: 0)
        #expect(model.thresholds.count == 1)
    }

    @Test("lembrete de reset: off/5/15/30 chegam ao engine; nil desliga")
    func resetReminderRoundtrip() async throws {
        let db = try makeDatabase()
        let model = makeModel(database: db)
        await model.setResetReminder(minutes: 5)
        #expect(await AlertEngine(database: db).config.resetReminderMinutes == 5)
        await model.setResetReminder(minutes: nil)
        #expect(await AlertEngine(database: db).config.resetReminderMinutes == nil)
    }

    // MARK: - Intervalos vivos (scheduler)

    @Test("intervalos: clamp nas faixas da UI e aplicação VIVA no scheduler")
    func intervalsClampAndApplyToScheduler() async throws {
        let db = try makeDatabase()
        let scheduler = AdaptiveScheduler(clock: ContinuousClock())
        let model = makeModel(database: db, scheduler: scheduler)

        await model.setForegroundRefresh(seconds: 9_999)
        await model.setIdleRefresh(seconds: 5)
        #expect(model.foregroundRefreshSeconds == 300, "teto do foreground")
        #expect(model.idleRefreshSeconds == 60, "piso do background")

        await model.setForegroundRefresh(seconds: 45)
        await model.setIdleRefresh(seconds: 600)
        #expect(model.foregroundRefreshSeconds == 45)
        #expect(model.idleRefreshSeconds == 600)
        // Sem restart: o scheduler VIVO reflete os novos intervalos.
        #expect(await scheduler.menuInterval == .seconds(45))
        #expect(await scheduler.idleInterval == .seconds(600))
    }

    // MARK: - Visibilidade do menu bar (republish no coordinator)

    @Test("visibilidade: persiste e republisha o conjunto atualizado")
    func visibilityPersistsAndRepublishes() async throws {
        let db = try makeDatabase()
        final class Box: @unchecked Sendable { var value: Set<ProviderID>? }
        let box = Box()
        let model = makeModel(database: db, onVisibility: { box.value = $0 })

        await model.setProviderVisible(.codex, false)
        #expect(box.value == Set(ProviderID.allCases).subtracting([.codex]))
        #expect(AppSettingsStore(database: db).loadVisibleProviders() == box.value)

        await model.setProviderVisible(.codex, true)
        #expect(box.value == Set(ProviderID.allCases))
    }

    // MARK: - Launch at login (SMAppService FAKE)

    @Test("launch at login: toggle liga → register; desliga → unregister; estado reflete o serviço")
    func launchAtLoginRegisterUnregister() {
        let login = FakeLoginService(status: .notRegistered)
        let model = makeModel(database: nil, login: login)
        #expect(model.launchAtLogin == false)

        model.setLaunchAtLogin(true)
        #expect(login.registerCalls == 1)
        #expect(model.launchAtLogin == true)
        #expect(model.launchNotice == nil)

        model.setLaunchAtLogin(false)
        #expect(login.unregisterCalls == 1)
        #expect(model.launchAtLogin == false)
    }

    @Test("launch at login: erro de registro é HONESTO (aviso na janela, estado do serviço)")
    func launchAtLoginErrorShowsHonestNotice() {
        struct Denied: LocalizedError {
            var errorDescription: String? { "operation not permitted" }
        }
        let login = FakeLoginService(status: .notRegistered)
        login.failure = Denied()
        let model = makeModel(database: nil, login: login)

        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin == false, "falhou → estado real segue desligado")
        #expect(model.launchNotice?.contains("Couldn't enable") == true)
        #expect(model.launchNotice?.contains("operation not permitted") == true)

        // Erro também ao desligar.
        model.setLaunchAtLogin(false)
        #expect(model.launchNotice?.contains("Couldn't disable") == true)
    }

    @Test("launch at login: requiresApproval é honesto — NÃO conta como ligado")
    func requiresApprovalIsNotEnabled() throws {
        let login = FakeLoginService(status: .requiresApproval)
        let model = makeModel(database: nil, login: login)
        #expect(model.launchAtLogin == false)
        #expect(model.launchNotice?.contains("waiting for approval") == true)
    }
}
