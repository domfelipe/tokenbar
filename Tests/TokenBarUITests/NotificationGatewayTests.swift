import Foundation
import Testing
import TokenBarCore
import os
@testable import TokenBarUI

/// F5 T2 — NotificationGateway: renderização EN dos eventos, fake capturável
/// (NUNCA UNUserNotificationCenter real em teste) e wiring do coordinator
/// (dispatch pós-ciclo + estado honesto no painel).
final class FakeNotificationGateway: NotificationSending, @unchecked Sendable {
    /// `deliver` é async — NSLock é proibido em contexto async; unfair lock
    /// com escopo síncrono é o padrão do repo (BundledPricingBox).
    private let captured = OSAllocatedUnfairLock<[AlertEvent]>(initialState: [])
    /// Respostas injetadas pelos testes.
    var authorizationResult: Bool
    var state: NotificationAuthorizationState
    /// `deliver` falha quando false (simula sistema recusando entrega).
    var deliverEnabled: Bool

    init(
        authorizationResult: Bool = true,
        state: NotificationAuthorizationState = .granted,
        deliverEnabled: Bool = true
    ) {
        self.authorizationResult = authorizationResult
        self.state = state
        self.deliverEnabled = deliverEnabled
    }

    func requestAuthorization() async -> Bool {
        state = authorizationResult ? .granted : .denied
        return authorizationResult
    }

    func authorizationState() async -> NotificationAuthorizationState { state }

    func deliver(_ event: AlertEvent) async {
        guard deliverEnabled else { return }
        captured.withLock { $0.append(event) }
    }

    var delivered: [AlertEvent] {
        captured.withLock { $0 }
    }
}

@Suite
struct NotificationGatewayTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func event(
        kind: AlertEvent.Kind = .threshold, threshold: Int? = 90,
        resetsAt: Date? = nil, provider: ProviderID = .claude
    ) -> AlertEvent {
        AlertEvent(
            kind: kind, provider: provider,
            account: AccountID(provider: provider, key: "local"),
            windowKind: .weekly, thresholdPct: threshold, usedFraction: 0.9,
            resetsAt: resetsAt, firedAt: base)
    }

    @Test("render threshold: título e body com countdown do reset")
    func rendersThresholdNotification() {
        let rendered = UserNotificationGateway.render(
            event(resetsAt: base + 60 * 135))  // 2h15m
        #expect(rendered.title == "Claude · 90% of weekly window used")
        #expect(rendered.body == "Resets in 2h 15m")
    }

    @Test("render sem resetsAt ou já vencido → 'Reset time unknown' (nada inventado)")
    func rendersUnknownResetHonestly() {
        #expect(UserNotificationGateway.render(event(resetsAt: nil)).body == "Reset time unknown")
        #expect(UserNotificationGateway.render(event(resetsAt: base - 60)).body == "Reset time unknown")
    }

    @Test("render lembrete: título de renovação com countdown")
    func rendersResetReminder() {
        let rendered = UserNotificationGateway.render(
            event(kind: .resetReminder, threshold: nil, resetsAt: base + 600, provider: .codex))
        #expect(rendered.title == "Codex · weekly window resets soon")
        #expect(rendered.body == "Resets in 10m")
    }

    @Test("identificador de entrega é estável por causa (substitui, não empilha)")
    func deliveryIdentifierIsStable() {
        let threshold = UserNotificationGateway.identifier(for: event(threshold: 90))
        #expect(threshold == UserNotificationGateway.identifier(for: event(threshold: 90)))
        #expect(threshold != UserNotificationGateway.identifier(for: event(threshold: 75)))
        #expect(UserNotificationGateway.identifier(
            for: event(kind: .resetReminder, threshold: nil, resetsAt: base + 60))
            != threshold)
    }

    @Test("nomes de provider (D5) cobrem todos os ProviderID")
    func providerNamesCoverAllProviders() {
        for id in ProviderID.allCases {
            #expect(!UserNotificationGateway.providerName(id).isEmpty)
        }
        #expect(UserNotificationGateway.providerName(.zai) == "Z.ai")
    }

    @Test("fake captura eventos; requestAuthorization reflete o injetado")
    func fakeCapturesAndAuthorizes() async {
        let fake = FakeNotificationGateway(authorizationResult: false)
        let granted = await fake.requestAuthorization()
        #expect(granted == false)
        #expect(await fake.authorizationState() == .denied)

        await fake.deliver(event(resetsAt: base + 60))
        #expect(fake.delivered.count == 1)
        #expect(fake.delivered.first?.thresholdPct == 90)
    }

    @Test("texto do painel: só o estado OK fica em silêncio (honesto)")
    func panelStatusTextIsHonest() {
        #expect(ProviderPanelModel.alertsStatusText(.enabled) == nil)
        #expect(ProviderPanelModel.alertsStatusText(.disabled) != nil)
        #expect(ProviderPanelModel.alertsStatusText(.notConfigured) != nil)
        #expect(ProviderPanelModel.alertsStatusText(.blocked) != nil)
    }
}

/// Wiring coordinator ↔ AlertEngine ↔ gateway: dispatch dos eventos do ciclo,
/// dedupe via engine e estado honesto no SnapshotStore. Fixture igual à dos
/// testes T7 (dirs fake via env, sem tocar no App Support real).
@MainActor
struct CoordinatorAlertsWiringTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func makeFixture() throws -> (root: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-t2alerts-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (root, [
            "TOKENBAR_CLAUDE_DIR": root.appendingPathComponent("claude").path,
            "TOKENBAR_CODEX_DIR": root.appendingPathComponent("codex").path,
            "TOKENBAR_GEMINI_DIR": root.appendingPathComponent("gemini").path,
            "TOKENBAR_ZAI_CONFIG": root.appendingPathComponent("zai-config.json").path,
        ])
    }

    func makeCoordinator(
        _ fixture: (root: URL, environment: [String: String]),
        gateway: any NotificationSending
    ) -> ProviderCoordinator {
        ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: fixture.environment,
            home: fixture.root,
            supportDirectory: fixture.root.appendingPathComponent("support"),
            notificationGateway: gateway))
    }

    func weeklyWindow(_ fraction: Double) -> [UsageWindow] {
        [UsageWindow(
            kind: .weekly, usedFraction: fraction, resetsAt: base + 86_400, label: "weekly")]
    }

    @Test("alerts ligado: ciclo entrega eventos no gateway e publica estado granted")
    func dispatchDeliversEventsAndPublishesStatus() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway()
        let coordinator = makeCoordinator(fixture, gateway: fake)

        // Config pela API pública (a Settings da T3 usa o mesmo caminho).
        await coordinator.alertEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50, 75, 90, 95], resetReminderMinutes: nil))

        let snapshots = [(
            provider: ProviderID.claude,
            account: AccountID(provider: .claude, key: "local"),
            windows: weeklyWindow(0.93)
        )]
        await coordinator.dispatchAlerts(snapshots: snapshots, now: base)
        #expect(fake.delivered.map(\.thresholdPct) == [50, 75, 90])
        #expect(coordinator.store.alertsStatus == .enabled)

        // Mesmo snapshot de novo → dedupe do engine, gateway não re-recebe.
        await coordinator.dispatchAlerts(snapshots: snapshots, now: base + 60)
        #expect(fake.delivered.count == 3)
    }

    @Test("alerts desligado (default): nada toca o gateway e o painel diz off")
    func disabledAlertsNeverTouchGateway() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway()
        let coordinator = makeCoordinator(fixture, gateway: fake)

        let snapshots = [(
            provider: ProviderID.codex,
            account: AccountID(provider: .codex, key: "local"),
            windows: weeklyWindow(0.99)
        )]
        await coordinator.dispatchAlerts(snapshots: snapshots, now: base)
        #expect(fake.delivered.isEmpty)
        #expect(fake.state == .granted)  // nem consulta: status vem do config
        #expect(coordinator.store.alertsStatus == .disabled)
    }

    @Test("permissão negada: deliver no-op e painel mostra blocked (honesto)")
    func deniedPermissionShowsBlocked() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway(state: .denied, deliverEnabled: false)
        let coordinator = makeCoordinator(fixture, gateway: fake)
        await coordinator.alertEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50], resetReminderMinutes: nil))

        let snapshots = [(
            provider: ProviderID.gemini,
            account: AccountID(provider: .gemini, key: "local"),
            windows: weeklyWindow(0.60)
        )]
        await coordinator.dispatchAlerts(snapshots: snapshots, now: base)
        #expect(coordinator.store.alertsStatus == .blocked)
    }

    @Test("permissão não determinada: painel mostra notConfigured")
    func notDeterminedShowsNotConfigured() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway(state: .notDetermined, deliverEnabled: false)
        let coordinator = makeCoordinator(fixture, gateway: fake)
        await coordinator.alertEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50], resetReminderMinutes: nil))

        let snapshots = [(
            provider: ProviderID.zai,
            account: AccountID(provider: .zai, key: "local"),
            windows: weeklyWindow(0.60)
        )]
        await coordinator.dispatchAlerts(snapshots: snapshots, now: base)
        #expect(coordinator.store.alertsStatus == .notConfigured)
    }

    @Test("ciclo completo com alerts ligado: janelas sem fração (local) não geram evento")
    func fullCycleWithLocalWindowsProducesNoEvents() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway()
        let coordinator = makeCoordinator(fixture, gateway: fake)
        await coordinator.alertEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50, 75, 90, 95], resetReminderMinutes: nil))

        // Um ciclo real de cada provider: modo local, frações desconhecidas →
        // engine não inventa evento; wiring não crasa e publica o estado.
        await coordinator.refreshAllNow()
        #expect(fake.delivered.isEmpty)
        #expect(coordinator.store.alertsStatus == .enabled)
    }

    // MARK: - Orçamento (F7 Spend control)

    /// Evento precificado no banco do PRÓPRIO coordinator: o coordinator abre o
    /// banco com a tabela de preços EMBUTIDA, então o teste escolhe um modelo
    /// que existe nela (e falha alto se a tabela mudar de nome).
    func seedPricedEvent(_ database: AppDatabase, tokens: Int64, now: Date) throws {
        let model = "claude-sonnet-4-6"
        let pricing = try #require(PricingTable.bundled())
        _ = try #require(
            pricing.price(forModel: model)?.input,
            "tabela de preços embutida sem preço de input para \(model)")
        try database.persistBatch(
            provider: .claude, path: "/fixture/claude.jsonl",
            events: [UsageEvent(
                ts: now, provider: .claude,
                account: AccountID(provider: .claude, key: "local"),
                model: model, inputTokens: tokens, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)],
            endOffset: 1_000, resetToZero: false)
    }

    @Test("orçamento: ciclo entrega o alerta de gasto e de PROJEÇÃO pelo gateway")
    func dispatchDeliversBudgetAlerts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway()
        let coordinator = makeCoordinator(fixture, gateway: fake)
        await coordinator.alertEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50], resetReminderMinutes: nil))

        let database = try #require(coordinator.historyDatabase)
        // 1M tokens de input num modelo com preço real de input → o mês tem
        // custo computável; teto de $1 → a fração estoura o teto.
        try seedPricedEvent(database, tokens: 1_000_000, now: base)
        AppSettingsStore(database: database).saveBudget(
            BudgetConfig(monthlyUSD: 1, perProvider: [:]))

        await coordinator.dispatchAlerts(snapshots: [], now: base)
        let budgetAlerts = fake.delivered.filter { $0.kind == .budget }
        #expect(!budgetAlerts.isEmpty)
        #expect(budgetAlerts.allSatisfy { $0.windowKind == .monthly })
        #expect(budgetAlerts.allSatisfy { $0.account.key == AccountID.allAccountsKey })
        #expect(budgetAlerts.allSatisfy { $0.provider == .claude })
        // Projeção do mês no ritmo do dia (também acima de 50% do teto).
        #expect(fake.delivered.contains { $0.kind == .budgetProjection })

        // Mesmo ciclo de novo → dedupe do engine, gateway não re-recebe.
        let delivered = fake.delivered.count
        await coordinator.dispatchAlerts(snapshots: [], now: base + 60)
        #expect(fake.delivered.count == delivered)
    }

    @Test("orçamento: sem teto ou sem custo computável o gateway fica intocado")
    func budgetWithoutLimitOrComputableCostStaysQuiet() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = FakeNotificationGateway()
        let coordinator = makeCoordinator(fixture, gateway: fake)
        await coordinator.alertEngine.apply(config: AlertConfig(
            enabled: true, thresholds: [50], resetReminderMinutes: nil))
        let database = try #require(coordinator.historyDatabase)

        // Gasto no mês SEM preço computável (modelo fora da tabela → cost NULL):
        // com teto configurado continua sem evento (NULL ≠ 0).
        try database.persistBatch(
            provider: .claude, path: "/fixture/claude.jsonl",
            events: [UsageEvent(
                ts: base, provider: .claude,
                account: AccountID(provider: .claude, key: "local"),
                model: "modelo-sem-preco", inputTokens: 1_000_000, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)],
            endOffset: 1_000, resetToZero: false)
        AppSettingsStore(database: database).saveBudget(
            BudgetConfig(monthlyUSD: 1, perProvider: [:]))
        await coordinator.dispatchAlerts(snapshots: [], now: base)
        #expect(fake.delivered.isEmpty)

        // E sem teto nenhum, mesmo com gasto precificado, também nada.
        AppSettingsStore(database: database).saveBudget(.empty)
        try seedPricedEvent(database, tokens: 5_000_000, now: base)
        await coordinator.dispatchAlerts(snapshots: [], now: base + 60)
        #expect(fake.delivered.isEmpty)
    }
}
