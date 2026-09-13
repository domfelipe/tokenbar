import Foundation
import Observation
import TokenBarCore

/// View-model do Analytics (F3 Task 3) — TODO o trabalho de dados da janela,
/// sem SwiftUI/Charts (o `AnalyticsView` — em TokenBarUI — só desenha). Testável
/// headless; a renderização visual fica para o QA manual da Task 5.
///
/// Orçamento de RAM: o modelo nasce com a janela e morre com ela — `clear()`
/// esvazia os arrays no onDisappear, e nenhuma view segura referência depois
/// do fechamento (o AppState derruba a `NSWindow` no `windowWillClose`).
/// Queries do banco rodam FORA da MainActor (`Task.detached`) e chegam via
/// await — padrão do projeto; o render gate da F1 não é tocado.
@MainActor
@Observable
public final class AnalyticsModel {
    /// Períodos do seletor: 24h/7d/30d. Buckets são DIAS do calendário (a
    /// persistência é diária — daily_agg), então "24h" = hoje (dia corrente).
    public enum Period: String, CaseIterable, Sendable, Identifiable {
        case day24h
        case days7
        case days30

        public var id: String { rawValue }

        /// Janela em dias corridos (incluindo hoje).
        public var days: Int {
            switch self {
            case .day24h: 1
            case .days7: 7
            case .days30: 30
            }
        }

        public var label: String {
            switch self {
            case .day24h: "24h"
            case .days7: "7d"
            case .days30: "30d"
            }
        }
    }

    /// Ponto (provider, dia) — barra empilhada de tokens/dia.
    public struct ProviderDay: Identifiable, Equatable, Sendable {
        public var provider: String
        public var day: String
        public var tokens: Int64
        public var costUSD: Double?
        public var id: String { "\(provider)|\(day)" }
    }

    /// Custo de um dia (só dias com algum custo computável aparecem no chart
    /// de custo; dia 100% NULL não vira barra zero — NULL ≠ 0).
    public struct DayCost: Identifiable, Equatable, Sendable {
        public var day: String
        public var costUSD: Double
        public var id: String { day }
    }

    public struct ProviderTotal: Identifiable, Equatable, Sendable {
        public var provider: String
        public var tokens: Int64
        public var costUSD: Double?
        public var id: String { provider }
    }

    public struct ModelSlice: Identifiable, Equatable, Sendable {
        public var model: String
        public var tokens: Int64
        public var costUSD: Double?
        public var id: String { model }
    }

    /// Linha do Ledger diário (Usage & Spend): agregação por dia, ordem desc.
    /// Semântica NULL ≠ 0: custo nil = sem custo computável (exibe "—").
    public struct LedgerRow: Identifiable, Equatable, Sendable {
        public var day: String
        public var tokens: Int64
        public var costUSD: Double?
        public var id: String { day }

        public init(day: String, tokens: Int64, costUSD: Double?) {
            self.day = day
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    /// Célula do Heatmap diário: intensidade relativa de custo no período (0.0 a 1.0).
    public struct HeatmapCell: Identifiable, Equatable, Sendable {
        public var day: String
        public var date: Date
        /// 1 = segunda … 7 = domingo, no calendar do banco (coluna da grade).
        public var weekday: Int
        public var tokens: Int64
        public var costUSD: Double?
        /// Custo relativo ao maior do período (0…1); 0 = célula vazia.
        public var intensity: Double
        public var id: String { day }

        public init(
            day: String, date: Date, weekday: Int, tokens: Int64,
            costUSD: Double?, intensity: Double
        ) {
            self.day = day
            self.date = date
            self.weekday = weekday
            self.tokens = tokens
            self.costUSD = costUSD
            self.intensity = intensity
        }
    }

    /// Uma linha do resumo de orçamento (F7): global (provider `nil`) ou de um
    /// provider. `spentUSD` `nil` = mês sem custo computável (NULL ≠ 0 → a UI
    /// mostra "—", nunca "$0.00"); `projectedUSD` `nil` = sem base para projetar.
    public struct BudgetRow: Identifiable, Equatable, Sendable {
        /// `nil` = linha GLOBAL (todos os providers somados).
        public var provider: ProviderID?
        public var spentUSD: Double?
        public var budgetUSD: Double
        public var projectedUSD: Double?
        public var id: String { provider?.rawValue ?? "all" }

        public init(
            provider: ProviderID?, spentUSD: Double?, budgetUSD: Double,
            projectedUSD: Double?
        ) {
            self.provider = provider
            self.spentUSD = spentUSD
            self.budgetUSD = budgetUSD
            self.projectedUSD = projectedUSD
        }
    }

    /// Quantos modelos o breakdown exibe (spec: top 5).
    public static let topModelsLimit = 5

    private let database: AppDatabase?
    /// Período vigente; a view troca e chama `reload()`.
    public private(set) var period: Period = .days7
    public private(set) var providerSeries: [ProviderDay] = []
    public private(set) var dayCosts: [DayCost] = []
    public private(set) var totals: [ProviderTotal] = []
    public private(set) var topModels: [ModelSlice] = []
    /// Ledger diário (Usage & Spend): só dias COM evento, do mais recente ao
    /// mais antigo; `costUSD` nil = sem custo computável (a tabela mostra "—").
    public private(set) var ledgerRows: [LedgerRow] = []
    /// Heatmap diário: TODOS os dias do período (inclusive sem evento).
    public private(set) var heatmapCells: [HeatmapCell] = []
    /// Resumo de ORÇAMENTO do mês (F7 Spend control): linha GLOBAL (quando há
    /// teto global) + uma por provider com teto próprio. Vazio = sem orçamento
    /// configurado (a seção mostra o caminho das Settings, nada inventado).
    /// Não depende do período do seletor: orçamento é sempre o MÊS-corrente.
    public private(set) var budgetRows: [BudgetRow] = []
    public private(set) var isLoading = false

    public init(database: AppDatabase?) {
        self.database = database
    }

    /// Sem banco (degradação F2): janela abre vazia — nada a inventar.
    public var hasDatabase: Bool { database != nil }

    /// Troca o período; a view (ou o teste) dispara `reload()` em seguida.
    public func setPeriod(_ newPeriod: Period) {
        period = newPeriod
    }

    /// Recarrega os 4 conjuntos de dados do período vigente. Proteção contra
    /// corrida de troca de período: resultado de recarga obsoleta é descartado.
    /// `now` injetável p/ testes (produção usa o relógio real).
    public func reload(now: Date = Date()) async {
        guard let database else {
            clear()
            return
        }
        let requested = period
        let days = requested.days
        isLoading = true
        defer { isLoading = false }

        let snapshot = await Task.detached(priority: .utility) { () -> Snapshot in
            let series = (try? database.dailySeries(days: days, now: now)) ?? []
            let totals = (try? database.totals(days: days, now: now)) ?? []
            let breakdown = (try? database.modelBreakdown(days: days, now: now)) ?? []
            let window = database.windowDays(days: days, now: now)
            // Orçamento (F7): tetos da tabela `settings` + gasto do MÊS-corrente
            // + projeção, tudo no calendar do banco (o mesmo do rollover).
            let monthRows = (try? database.monthSpend(now: now)) ?? []
            let budget = AppSettingsStore(database: database).loadBudget()
            return Snapshot(
                series: series, totals: totals, breakdown: breakdown, window: window,
                budgetRows: Self.budgetRows(
                    budget: budget, monthRows: monthRows, now: now,
                    calendar: database.calendar))
        }.value

        // Período mudou enquanto a query rodava: descarta (a recarga nova
        // aplica o estado certo).
        guard period == requested else { return }
        providerSeries = snapshot.series.map {
            ProviderDay(provider: $0.provider, day: $0.day, tokens: $0.tokens, costUSD: $0.costUSD)
        }
        dayCosts = Self.dayCosts(from: snapshot.series)
        ledgerRows = Self.ledgerRows(from: snapshot.series)
        heatmapCells = Self.heatmapCells(from: snapshot.series, window: snapshot.window)
        totals = snapshot.totals.map {
            ProviderTotal(provider: $0.provider, tokens: $0.tokens, costUSD: $0.costUSD)
        }
        topModels = snapshot.breakdown.prefix(Self.topModelsLimit).map {
            ModelSlice(model: $0.model, tokens: $0.tokens, costUSD: $0.costUSD)
        }
        budgetRows = snapshot.budgetRows
    }

    /// Fecha a janela: solta os dados (orçamento de RAM — nada fica vivo
    /// depois do fechamento).
    public func clear() {
        providerSeries = []
        dayCosts = []
        ledgerRows = []
        heatmapCells = []
        budgetRows = []
        totals = []
        topModels = []
        isLoading = false
    }

    private struct Snapshot: Sendable {
        var series: [AppDatabase.DailySeriesRow]
        var totals: [AppDatabase.ProviderTotalRow]
        var breakdown: [AppDatabase.ModelBreakdownRow]
        /// Grade da janela (dias com data), para o heatmap não recalcular o calendário.
        var window: [AppDatabase.WindowDay]
        /// Resumo do orçamento do mês (F7) — já calculado fora da MainActor.
        var budgetRows: [BudgetRow]
    }

    /// Custo por dia derivado das séries por provider — MESMA semântica do
    /// `SUM(cost_usd)` do SQL, agora entre providers: dia soma os custos
    /// conhecidos; só é `nil` (fora do chart) quando TODOS os providers do
    /// dia estão sem custo computável. Dias sem nenhum evento não entram.
    /// `nonisolated` — função pura, chamável de qualquer contexto.
    ///
    /// Review T3: a guarda de "primeira vista do dia" é o set `seen`,
    /// INDEPENDENTE do custo — usar o dicionário de soma (que só popula com
    /// custo não-nil) duplicava o dia quando o primeiro provider em ordem
    /// tinha custo nil, e id duplicado no Chart = barra sobreposta.
    nonisolated public static func dayCosts(from series: [AppDatabase.DailySeriesRow]) -> [DayCost] {
        var seen: Set<String> = []
        var order: [String] = []
        var knownByDay: [String: Double] = [:]
        var hasAnyByDay: [String: Bool] = [:]
        for row in series {
            if seen.insert(row.day).inserted { order.append(row.day) }
            hasAnyByDay[row.day] = (hasAnyByDay[row.day] ?? false) || (row.costUSD != nil)
            if let cost = row.costUSD {
                knownByDay[row.day] = (knownByDay[row.day] ?? 0) + cost
            }
        }
        return order.sorted().compactMap { day in
            guard hasAnyByDay[day] == true else { return nil }
            return DayCost(day: day, costUSD: knownByDay[day] ?? 0)
        }
    }

    // MARK: - Orçamento do mês (F7 Spend control)

    /// Linhas do resumo de orçamento: a GLOBAL primeiro (quando existe teto
    /// global), depois uma por provider com teto PRÓPRIO, em ordem de rawValue.
    /// Provider com teto próprio mas sem evento no mês entra com `spentUSD` nil
    /// (a UI mostra "—": sem custo computável ≠ gastou zero). Função pura.
    nonisolated public static func budgetRows(
        budget: BudgetConfig, monthRows: [AppDatabase.MonthSpendRow],
        now: Date, calendar: Calendar
    ) -> [BudgetRow] {
        guard !budget.isEmpty else { return [] }
        var spendByProvider: [ProviderID: Double?] = [:]
        for row in monthRows {
            guard let provider = ProviderID(rawValue: row.provider) else { continue }
            spendByProvider[provider] = row.costUSD
        }
        var rows: [BudgetRow] = []
        if let global = budget.monthlyUSD {
            let total = AppDatabase.monthSpendTotal(monthRows).costUSD
            rows.append(BudgetRow(
                provider: nil, spentUSD: total, budgetUSD: global,
                projectedUSD: SpendProjection.project(
                    monthToDate: total, now: now, calendar: calendar)?.projected))
        }
        for provider in budget.perProvider.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let limit = budget.perProvider[provider] else { continue }
            let spent = spendByProvider[provider] ?? nil
            rows.append(BudgetRow(
                provider: provider, spentUSD: spent, budgetUSD: limit,
                projectedUSD: SpendProjection.project(
                    monthToDate: spent, now: now, calendar: calendar)?.projected))
        }
        return rows
    }

    // MARK: - Usage & Spend (ledger diário + heatmap)

    /// Linhas do Ledger diário: um dia por linha, tokens SOMADOS entre
    /// providers, ordem DESCENDENTE (mais recente primeiro) e só dias COM
    /// evento. `costUSD` nil = nenhum provider do dia tinha preço computável
    /// (a tabela mostra "—", nunca 0) — mesma semântica do `dayCosts`, aqui
    /// preservando o dia em vez de omiti-lo do chart.
    nonisolated public static func ledgerRows(
        from series: [AppDatabase.DailySeriesRow]
    ) -> [LedgerRow] {
        dayAggregates(from: series)
            .map { day, aggregate in
                LedgerRow(
                    day: day, tokens: aggregate.tokens,
                    costUSD: aggregate.hasComputableCost ? aggregate.knownCost : nil)
            }
            .sorted { $0.day > $1.day }
    }

    /// Células do heatmap diário: um dia por dia da JANELA (inclusive os sem
    /// evento — célula vazia, ≠ zero), na ordem da grade. `intensity` é
    /// relativa ao MAIOR custo computável do PERÍODO (0…1); dia sem custo
    /// computável — ou período sem nenhum custo — fica 0 com `costUSD` nil.
    /// Custo zero REAL pinta igual a vazio mas chega como 0: a cor achata, o
    /// dado não (NULL ≠ 0 preservado para o tooltip).
    nonisolated public static func heatmapCells(
        from series: [AppDatabase.DailySeriesRow], window: [AppDatabase.WindowDay]
    ) -> [HeatmapCell] {
        let aggregates = dayAggregates(from: series)
        var maxCost: Double?
        for day in window {
            guard let aggregate = aggregates[day.day], aggregate.hasComputableCost else { continue }
            maxCost = max(maxCost ?? aggregate.knownCost, aggregate.knownCost)
        }
        return window.map { day in
            let aggregate = aggregates[day.day]
            let cost: Double?
            if let aggregate, aggregate.hasComputableCost {
                cost = aggregate.knownCost
            } else {
                cost = nil
            }
            var intensity = 0.0
            if let cost, let maxCost, maxCost > 0 {
                intensity = cost / maxCost
            }
            return HeatmapCell(
                day: day.day, date: day.date, weekday: day.weekday,
                tokens: aggregate?.tokens ?? 0, costUSD: cost, intensity: intensity)
        }
    }
}

/// Agregação por dia compartilhada pelo ledger e pelo heatmap: tokens somados
/// entre providers e custo com a MESMA regra do `dayCosts` (NULL ≠ 0).
/// Fora da classe: tipo auxiliar não-isolado, usado por funções `nonisolated`.
private struct DayAggregate {
    var tokens: Int64 = 0
    var knownCost: Double = 0
    /// true quando ALGUM provider do dia tinha preço computável — zero real conta.
    var hasComputableCost = false
}

private func dayAggregates(from series: [AppDatabase.DailySeriesRow]) -> [String: DayAggregate] {
    var result: [String: DayAggregate] = [:]
    for row in series {
        var aggregate = result[row.day] ?? DayAggregate()
        aggregate.tokens += row.tokens
        if let cost = row.costUSD {
            aggregate.knownCost += cost
            aggregate.hasComputableCost = true
        }
        result[row.day] = aggregate
    }
    return result
}
