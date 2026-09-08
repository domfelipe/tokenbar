import Foundation
import Observation
import TokenBarCore

/// View-model do Analytics (F3 Task 3) — TODO o trabalho de dados da janela,
/// sem SwiftUI/Charts (o `AnalyticsView` do executável só desenha). Testável
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

    /// Quantos modelos o breakdown exibe (spec: top 5).
    public static let topModelsLimit = 5

    private let database: AppDatabase?
    /// Período vigente; a view troca e chama `reload()`.
    public private(set) var period: Period = .days7
    public private(set) var providerSeries: [ProviderDay] = []
    public private(set) var dayCosts: [DayCost] = []
    public private(set) var totals: [ProviderTotal] = []
    public private(set) var topModels: [ModelSlice] = []
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
            return Snapshot(series: series, totals: totals, breakdown: breakdown)
        }.value

        // Período mudou enquanto a query rodava: descarta (a recarga nova
        // aplica o estado certo).
        guard period == requested else { return }
        providerSeries = snapshot.series.map {
            ProviderDay(provider: $0.provider, day: $0.day, tokens: $0.tokens, costUSD: $0.costUSD)
        }
        dayCosts = Self.dayCosts(from: snapshot.series)
        totals = snapshot.totals.map {
            ProviderTotal(provider: $0.provider, tokens: $0.tokens, costUSD: $0.costUSD)
        }
        topModels = snapshot.breakdown.prefix(Self.topModelsLimit).map {
            ModelSlice(model: $0.model, tokens: $0.tokens, costUSD: $0.costUSD)
        }
    }

    /// Fecha a janela: solta os dados (orçamento de RAM — nada fica vivo
    /// depois do fechamento).
    public func clear() {
        providerSeries = []
        dayCosts = []
        totals = []
        topModels = []
        isLoading = false
    }

    private struct Snapshot: Sendable {
        var series: [AppDatabase.DailySeriesRow]
        var totals: [AppDatabase.ProviderTotalRow]
        var breakdown: [AppDatabase.ModelBreakdownRow]
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
}
