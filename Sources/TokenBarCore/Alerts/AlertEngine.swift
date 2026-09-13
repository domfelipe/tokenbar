import Foundation

/// Configuração dos alertas (F5 T2, spec §8) — fonte da verdade é a tabela
/// `settings` (chaves `alerts:enabled`, `alerts:thresholds`,
/// `alerts:resetReminderMinutes`); a Task 3 (janela de Settings) escreve
/// aqui via `AlertEngine.apply(config:)`.
///
/// Defaults: DESLIGADO (ruling F5-NOTIF: permissão de notificação é pedida
/// só na ativação explícita — nada de prompt no launch), thresholds
/// [50, 75, 90, 95]% e lembrete de reset OFF.
public struct AlertConfig: Sendable, Equatable {
    public var enabled: Bool
    /// Percentuais (1...100) que disparam alerta ao serem CRUZADOS para cima.
    public var thresholds: [Int]
    /// Lembrete N minutos antes de `resetsAt`; `nil` = desligado.
    public var resetReminderMinutes: Int?

    public static let `default` = AlertConfig(
        enabled: false, thresholds: [50, 75, 90, 95], resetReminderMinutes: nil)

    public init(enabled: Bool, thresholds: [Int], resetReminderMinutes: Int?) {
        // Sanitização (padrão Red Team): thresholds ordenados, sem duplicata,
        // clamp 1...100; lembrete clamp 1...7 dias; valores inválidos fora.
        self.thresholds = Array(
            Set(thresholds.filter { $0 >= 1 && $0 <= 100 }).sorted())
        self.enabled = enabled
        self.resetReminderMinutes = resetReminderMinutes.flatMap { minutes in
            (1...10_080).contains(minutes) ? minutes : nil
        }
    }
}

/// Um alerta produzido pelo `AlertEngine` — semântico, sem strings de UI
/// (a renderização EN vive no gateway, TokenBarUI). `thresholdPct == nil`
/// no lembrete de reset.
public struct AlertEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case threshold, resetReminder
        /// Orçamento do mês (F7): o gasto JÁ feito cruzou um threshold do teto.
        case budget
        /// Projeção do mês (F7): no ritmo atual o fechamento cruza o threshold —
        /// é o aviso de estouro ANTES de acontecer.
        case budgetProjection
    }

    public let kind: Kind
    public let provider: ProviderID
    public let account: AccountID
    public let windowKind: WindowKind
    public let thresholdPct: Int?
    public let usedFraction: Double?
    public let resetsAt: Date?
    public let firedAt: Date

    public init(
        kind: Kind, provider: ProviderID, account: AccountID, windowKind: WindowKind,
        thresholdPct: Int?, usedFraction: Double?, resetsAt: Date?, firedAt: Date
    ) {
        self.kind = kind
        self.provider = provider
        self.account = account
        self.windowKind = windowKind
        self.thresholdPct = thresholdPct
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.firedAt = firedAt
    }
}

/// Motor de alertas de limite (F5 T2, spec §8): avalia os thresholds sobre
/// `UsageWindow.usedFraction` POR provider×conta×janela a cada ciclo.
///
/// SEMÂNTICA DE DEDUPE (contrato do plano):
/// - Por chave (provider, account.key, window.kind, threshold): o alerta
///   dispara 1× e fica SUPRIMIDO enquanto a fração seguir >= threshold.
/// - Re-arma quando a fração CAI ABAIXO do threshold OU a janela renovou
///   (`resetsAt` diferente do carimbado no disparo) — aí cruza de novo e
///   re-dispara.
/// - Primeira observação já acima do threshold (app instalado/reaberto no
///   meio da janela) DISPARA — o estado persistido é que impede re-disparo
///   no restart (dedupe sobrevive ao relaunch via `settings`).
/// - Lembrete de reset (`resetReminderMinutes`): 1 evento POR janela, no
///   intervalo `[resetsAt − N, resetsAt)`; a chave inclui o `resetsAt`, então
///   janela renovada re-arma naturalmente. Passou do `resetsAt` → não dispara
///   (lembrete de janela vencida é mentira).
///
/// HONESTIDADE (mesmo padrão F2/F4): fração `nil` ou não-finita → janela
/// ignorada (nada inventado); fração satura em 0...1; config/settings
/// corrompidas → defaults (T7 Red Team); sem DB → dedupe só em memória
/// (sessão), persistência é aditiva, nunca condição de crash.
///
/// O tempo é INJETADO (`now: Date` por avaliação) — determinístico em teste
/// (Swift Testing), sem `Date()` interno no caminho de decisão.
public actor AlertEngine {
    /// Chaves na tabela `settings` (spec §6).
    static let configEnabledKey = "alerts:enabled"
    static let configThresholdsKey = "alerts:thresholds"
    static let configReminderKey = "alerts:resetReminderMinutes"
    static let stateKey = "alerts:state"

    private let database: AppDatabase?
    private(set) public var config: AlertConfig

    /// Estado de dedupe dos thresholds.
    private var thresholdState: [ThresholdKey: FiredEntry] = [:]
    /// Estado dos lembretes: chave inclui `resetsAt` (renewal re-arma).
    private var reminderState: [ReminderKey: Date] = [:]
    /// Estado do orçamento (F7): chave por provider × tipo × threshold; o
    /// `resetsAt` carimba a VIRADA do mês — é o "renewal" do orçamento.
    private var budgetState: [BudgetKey: FiredEntry] = [:]

    private struct BudgetKey: Hashable {
        let provider: ProviderID
        let kind: String
        let threshold: Int
    }

    private struct ThresholdKey: Hashable {
        let provider: ProviderID
        let account: String
        let window: WindowKind
        let threshold: Int
    }

    private struct FiredEntry: Codable {
        let firedAt: Date
        let resetsAt: Date?
    }

    private struct ReminderKey: Hashable {
        let provider: ProviderID
        let account: String
        let window: WindowKind
        let resetsAt: Date
    }

    // MARK: - Persistência do estado (settings, JSON)

    private struct PersistedState: Codable {
        var thresholds: [PersistedThreshold] = []
        var reminders: [PersistedReminder] = []
        /// Aditivo (F7): estado de orçamento; ausente em JSON de versão anterior.
        var budgets: [PersistedBudget]?
    }

    private struct PersistedThreshold: Codable {
        let provider: String
        let account: String
        let window: String
        let threshold: Int
        let firedAt: Date
        let resetsAt: Date?
    }

    private struct PersistedReminder: Codable {
        let provider: String
        let account: String
        let window: String
        let resetsAt: Date
        let firedAt: Date
    }

    private struct PersistedBudget: Codable {
        let provider: String
        let kind: String
        let threshold: Int
        let firedAt: Date
        let resetsAt: Date
    }

    public init(database: AppDatabase?) {
        self.database = database
        self.config = Self.readConfig(database: database)
        if let database,
           let raw = try? database.setting(forKey: Self.stateKey),
           let state = Self.decodeState(raw)
        {
            for entry in state.thresholds {
                guard let provider = ProviderID(rawValue: entry.provider),
                      let window = WindowKind(rawValue: entry.window)
                else { continue }
                thresholdState[ThresholdKey(
                    provider: provider, account: entry.account, window: window,
                    threshold: entry.threshold)] = FiredEntry(
                    firedAt: entry.firedAt, resetsAt: entry.resetsAt)
            }
            for entry in state.reminders {
                guard let provider = ProviderID(rawValue: entry.provider),
                      let window = WindowKind(rawValue: entry.window)
                else { continue }
                reminderState[ReminderKey(
                    provider: provider, account: entry.account, window: window,
                    resetsAt: entry.resetsAt)] = entry.firedAt
            }
            for entry in state.budgets ?? [] {
                guard let provider = ProviderID(rawValue: entry.provider) else { continue }
                budgetState[BudgetKey(
                    provider: provider, kind: entry.kind, threshold: entry.threshold
                )] = FiredEntry(firedAt: entry.firedAt, resetsAt: entry.resetsAt)
            }
        }
    }

    // MARK: - Config (lida/escrita em settings; T3 consome)

    /// Aplica e persiste nova config (janela de Settings, Task 3). NÃO mexe
    /// no estado de dedupe — ligar/desligar não re-dispara o que já saiu.
    public func apply(config newConfig: AlertConfig) {
        config = newConfig
        persistConfig()
    }

    /// Leitura DA CONFIG persistida (sem tocar no estado de dedupe) —
    /// PÚBLICA para a janela de Settings (F5 Task 3) carregar os valores no
    /// init síncrono do modelo de UI: a decodificação JSON de `alerts:*` tem
    /// UMA fonte só (esta), nunca reimplementada na UI.
    public static func readConfig(database: AppDatabase?) -> AlertConfig {
        guard let database else { return .default }
        let decoder = JSONDecoder()
        var enabled = AlertConfig.default.enabled
        var thresholds = AlertConfig.default.thresholds
        var reminder = AlertConfig.default.resetReminderMinutes
        // Campo corrompido → mantém o default DESSE campo (degradação honesta).
        if let raw = try? database.setting(forKey: configEnabledKey),
           let value = try? decoder.decode(Bool.self, from: Data(raw.utf8))
        {
            enabled = value
        }
        if let raw = try? database.setting(forKey: configThresholdsKey),
           let value = try? decoder.decode([Int].self, from: Data(raw.utf8))
        {
            thresholds = value
        }
        if let raw = try? database.setting(forKey: configReminderKey),
           let value = try? decoder.decode(Int?.self, from: Data(raw.utf8))
        {
            reminder = value
        }
        return AlertConfig(
            enabled: enabled, thresholds: thresholds, resetReminderMinutes: reminder)
    }

    private func persistConfig() {
        guard let database else { return }
        let encoder = JSONEncoder()
        func write(_ value: some Encodable, forKey key: String) {
            guard let data = try? encoder.encode(value) else { return }
            try? database.setSetting(String(decoding: data, as: UTF8.self), forKey: key)
        }
        write(config.enabled, forKey: Self.configEnabledKey)
        write(config.thresholds, forKey: Self.configThresholdsKey)
        write(config.resetReminderMinutes, forKey: Self.configReminderKey)
    }

    // MARK: - Avaliação por ciclo

    /// Entrada do ciclo do coordinator: um item POR conta com as janelas
    /// vindas do snapshot do fetch. Retorna os eventos NOVOS (dedupe já
    /// aplicado) em ordem determinística.
    public func evaluate(
        snapshots: [(provider: ProviderID, account: AccountID, windows: [UsageWindow])],
        now: Date
    ) -> [AlertEvent] {
        guard config.enabled else { return [] }
        var events: [AlertEvent] = []

        for snapshot in snapshots {
            for window in snapshot.windows {
                evaluateThresholds(snapshot: snapshot, window: window, now: now, into: &events)
                evaluateReminder(snapshot: snapshot, window: window, now: now, into: &events)
            }
        }

        pruneStaleState(now: now)
        persistStateIfDirty()
        return events.sorted { Self.ordering($0) < Self.ordering($1) }
    }

    /// Avaliação de ORÇAMENTO (F7 Spend control): gasto do mês por provider
    /// contra o teto configurado, com DOIS tipos de evento — o que já passou
    /// (`.budget`) e o que a projeção indica que vai passar
    /// (`.budgetProjection`).
    ///
    /// CONTRATOS:
    /// - `spend` é o custo COMPUTÁVEL do mês por provider: provider ausente ou
    ///   com custo `nil` NÃO gera evento (sem base real não há aviso, NULL ≠ 0).
    /// - Provider sem teto (nem próprio, nem global) → nenhum evento.
    /// - Dedupe: 1× por (provider, tipo, threshold) POR MÊS; re-arma quando a
    ///   fração cai abaixo do threshold ou quando o mês vira (`month.next`
    ///   diferente do carimbado no disparo).
    /// - Alertas desligados → lista vazia (o master switch manda).
    public func evaluateBudgets(
        spend: [ProviderID: Double?],
        budget: BudgetConfig,
        month: AppDatabase.MonthWindow,
        now: Date,
        calendar: Calendar
    ) -> [AlertEvent] {
        guard config.enabled, !budget.isEmpty else { return [] }
        var events: [AlertEvent] = []
        for provider in spend.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let cost = spend[provider] ?? nil, cost.isFinite, cost >= 0,
                  let limit = budget.budget(for: provider)
            else { continue }
            evaluateBudgetKind(
                kind: .budget, provider: provider, fraction: cost / limit,
                month: month, now: now, into: &events)
            if let projection = SpendProjection.project(
                monthToDate: cost, now: now, calendar: calendar),
               let projected = projection.projectedFraction(ofBudget: limit)
            {
                evaluateBudgetKind(
                    kind: .budgetProjection, provider: provider, fraction: projected,
                    month: month, now: now, into: &events)
            }
        }
        pruneStaleState(now: now)
        persistStateIfDirty()
        return events.sorted { Self.ordering($0) < Self.ordering($1) }
    }

    private func evaluateBudgetKind(
        kind: AlertEvent.Kind, provider: ProviderID, fraction: Double,
        month: AppDatabase.MonthWindow, now: Date, into events: inout [AlertEvent]
    ) {
        guard fraction.isFinite else { return }
        for threshold in config.thresholds {
            let key = BudgetKey(provider: provider, kind: kind.rawValue, threshold: threshold)
            if let fired = budgetState[key] {
                let renewed = fired.resetsAt != month.next
                if !renewed && fraction >= Double(threshold) / 100 {
                    continue  // segue suprimido (1× por threshold até re-armar)
                }
                budgetState[key] = nil
                stateDirty = true
            }
            guard fraction >= Double(threshold) / 100 else { continue }
            budgetState[key] = FiredEntry(firedAt: now, resetsAt: month.next)
            stateDirty = true
            events.append(AlertEvent(
                kind: kind, provider: provider,
                account: AccountID(provider: provider, key: AccountID.allAccountsKey),
                windowKind: .monthly, thresholdPct: threshold, usedFraction: fraction,
                resetsAt: month.next, firedAt: now))
        }
    }

    /// Ordem determinística (provider, conta, janela, tipo, threshold).
    static func ordering(_ event: AlertEvent) -> (String, String, String, String, Int) {
        (
            event.provider.rawValue, event.account.key, event.windowKind.rawValue,
            event.kind.rawValue, event.thresholdPct ?? -1
        )
    }

    private func evaluateThresholds(
        snapshot: (provider: ProviderID, account: AccountID, windows: [UsageWindow]),
        window: UsageWindow,
        now: Date,
        into events: inout [AlertEvent]
    ) {
        guard let raw = window.usedFraction, raw.isFinite else { return }
        let fraction = min(max(raw, 0), 1)
        for threshold in config.thresholds {
            let key = ThresholdKey(
                provider: snapshot.provider, account: snapshot.account.key,
                window: window.kind, threshold: threshold)
            if let fired = thresholdState[key] {
                let renewed = window.resetsAt != fired.resetsAt
                if !renewed && fraction >= Double(threshold) / 100 {
                    continue  // segue suprimido (1× por threshold até re-armar)
                }
                // Re-armado: caiu abaixo OU janela renovou. Se ainda estiver
                // acima (caso renewal), dispara de novo abaixo.
                thresholdState[key] = nil
                stateDirty = true
            }
            guard fraction >= Double(threshold) / 100 else { continue }
            thresholdState[key] = FiredEntry(firedAt: now, resetsAt: window.resetsAt)
            stateDirty = true
            events.append(AlertEvent(
                kind: .threshold, provider: snapshot.provider, account: snapshot.account,
                windowKind: window.kind, thresholdPct: threshold, usedFraction: fraction,
                resetsAt: window.resetsAt, firedAt: now))
        }
    }

    private func evaluateReminder(
        snapshot: (provider: ProviderID, account: AccountID, windows: [UsageWindow]),
        window: UsageWindow,
        now: Date,
        into events: inout [AlertEvent]
    ) {
        guard let minutes = config.resetReminderMinutes, minutes > 0,
              let resetsAt = window.resetsAt
        else { return }
        let dueAt = resetsAt.addingTimeInterval(-Double(minutes) * 60)
        guard now >= dueAt, now < resetsAt else { return }
        let key = ReminderKey(
            provider: snapshot.provider, account: snapshot.account.key,
            window: window.kind, resetsAt: resetsAt)
        guard reminderState[key] == nil else { return }
        reminderState[key] = now
        stateDirty = true
        events.append(AlertEvent(
            kind: .resetReminder, provider: snapshot.provider, account: snapshot.account,
            windowKind: window.kind, thresholdPct: nil, usedFraction: window.usedFraction,
            resetsAt: resetsAt, firedAt: now))
    }

    /// Higiene: entradas de janelas vencidas não voltam a ser úteis (o renewal
    /// re-arma por chave nova) — saem do estado e do JSON.
    private func pruneStaleState(now: Date) {
        let staleReminders = reminderState.filter { $0.key.resetsAt < now }
        let staleThresholds = thresholdState.compactMap { key, entry -> ThresholdKey? in
            if let resetsAt = entry.resetsAt, resetsAt < now { return key }
            return nil
        }
        // Orçamento: o carimbo é a virada do mês — passou dela, o estado não
        // re-arma nada (a chave nova do mês seguinte é que decide).
        let staleBudgets = budgetState.compactMap { key, entry -> BudgetKey? in
            guard let resetsAt = entry.resetsAt, resetsAt < now else { return nil }
            return key
        }
        guard !staleReminders.isEmpty || !staleThresholds.isEmpty || !staleBudgets.isEmpty
        else { return }
        stateDirty = true
        for key in staleReminders.keys { reminderState[key] = nil }
        for key in staleThresholds { thresholdState[key] = nil }
        for key in staleBudgets { budgetState[key] = nil }
    }

    // MARK: - Estado ↔ settings (JSON)

    private var stateDirty = false

    private func persistStateIfDirty() {
        guard stateDirty else { return }
        stateDirty = false
        guard let database else { return }
        var persisted = PersistedState()
        for (key, entry) in thresholdState {
            persisted.thresholds.append(PersistedThreshold(
                provider: key.provider.rawValue, account: key.account,
                window: key.window.rawValue, threshold: key.threshold,
                firedAt: entry.firedAt, resetsAt: entry.resetsAt))
        }
        for (key, firedAt) in reminderState {
            persisted.reminders.append(PersistedReminder(
                provider: key.provider.rawValue, account: key.account,
                window: key.window.rawValue, resetsAt: key.resetsAt, firedAt: firedAt))
        }
        if !budgetState.isEmpty {
            persisted.budgets = budgetState.map { key, entry in
                PersistedBudget(
                    provider: key.provider.rawValue, kind: key.kind,
                    threshold: key.threshold, firedAt: entry.firedAt,
                    resetsAt: entry.resetsAt ?? Date(timeIntervalSince1970: 0))
            }
        }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? database.setSetting(String(decoding: data, as: UTF8.self), forKey: Self.stateKey)
    }

    /// Estado corrompido → vazio (pode re-alertar uma vez; nunca crash).
    private static func decodeState(_ raw: String) -> PersistedState? {
        try? JSONDecoder().decode(PersistedState.self, from: Data(raw.utf8))
    }
}
