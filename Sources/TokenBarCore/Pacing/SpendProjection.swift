import Foundation

/// Orçamento mensal (F7 Spend control): teto GLOBAL opcional em USD e tetos
/// por provider. Fonte da verdade é a tabela `settings` (chaves `budget:*`, ver
/// `AppSettingsStore`); este tipo é o valor já sanitizado que circula no app.
public struct BudgetConfig: Sendable, Equatable {
    /// Teto do mês somando TODOS os providers.
    public var monthlyUSD: Double?
    /// Teto do mês por provider (vence o global quando existe).
    public var perProvider: [ProviderID: Double]

    public static let empty = BudgetConfig(monthlyUSD: nil, perProvider: [:])

    /// Teto de sanidade: US$ 100 milhões/mês (acima disso é dado corrompido).
    public static let maxBudget = 1e8

    public init(monthlyUSD: Double?, perProvider: [ProviderID: Double]) {
        self.monthlyUSD = Self.sanitize(monthlyUSD)
        self.perProvider = perProvider.compactMapValues { Self.sanitize($0) }
    }

    /// Teto EFETIVO de um provider: o dele quando existe, senão o global.
    /// Sem nenhum dos dois → sem orçamento (nenhum alerta, nenhuma linha).
    public func budget(for provider: ProviderID) -> Double? {
        perProvider[provider] ?? monthlyUSD
    }

    public var isEmpty: Bool { monthlyUSD == nil && perProvider.isEmpty }

    /// Sanitização (padrão do projeto): não-finito, ≤ 0 ou absurdo → AUSENTE.
    /// Nunca crash, nunca chute intermediário.
    public static func sanitize(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= maxBudget else { return nil }
        return value
    }
}

/// Projeção de gasto do MÊS (F7 Spend control): o que já foi gasto + a taxa
/// diária observada → estimativa de fechamento. É o número do aviso
/// "você vai estourar o orçamento antes do fim do mês".
///
/// SEMÂNTICA (contrato do orçamento, F7):
/// - `monthToDate` só existe com custo COMPUTÁVEL (NULL ≠ 0): nenhum evento do
///   mês com preço na `PricingTable` → `project` devolve `nil` e a UI mostra
///   "—" (nunca "~$0.00" nem projeção inventada).
/// - `elapsedDays` = dias corridos do mês ATÉ HOJE, com o dia corrente contando
///   como COMPLETO — é o dado que existe (o ledger já fechou o dia até agora).
/// - `daysInMonth` vem do `range(of: .day, in: .month)` do calendário do BANCO
///   (fevereiro = 28/29; nada de 30 fixo, nada de soma de segundos — DST-safe).
/// - `projected` = `monthToDate / elapsedDays × daysInMonth`, saturado em
///   `maxProjected` (padrão Red Team: valor absurdo satura, nunca vira inf).
public struct SpendProjection: Sendable, Equatable {
    public let monthToDate: Double
    public let dailyRate: Double
    public let projected: Double
    public let elapsedDays: Int
    public let daysInMonth: Int

    /// Teto de sanidade da projeção (US$ 1 bilhão/mês).
    public static let maxProjected = 1e9

    public init(
        monthToDate: Double, dailyRate: Double, projected: Double,
        elapsedDays: Int, daysInMonth: Int
    ) {
        self.monthToDate = monthToDate
        self.dailyRate = dailyRate
        self.projected = projected
        self.elapsedDays = elapsedDays
        self.daysInMonth = daysInMonth
    }

    /// Projeta o fechamento do mês. `nil` quando não há custo computável,
    /// quando o valor é negativo/não-finito (dado corrompido) ou quando o
    /// calendário não resolve o mês — nunca uma projeção inventada.
    public static func project(
        monthToDate cost: Double?, now: Date, calendar: Calendar
    ) -> SpendProjection? {
        guard let cost, cost.isFinite, cost >= 0 else { return nil }
        let components = calendar.dateComponents([.day], from: now)
        guard let day = components.day, day >= 1,
              let range = calendar.range(of: .day, in: .month, for: now),
              range.count >= day
        else { return nil }
        let daysInMonth = range.count
        let dailyRate = cost / Double(day)
        let projected = min(dailyRate * Double(daysInMonth), maxProjected)
        return SpendProjection(
            monthToDate: cost, dailyRate: dailyRate, projected: projected,
            elapsedDays: day, daysInMonth: daysInMonth)
    }

    /// Fração do orçamento JÁ consumida (honesta: 1.2 = 120%). Sem orçamento
    /// válido → `nil`.
    public func fraction(ofBudget budget: Double?) -> Double? {
        guard let budget = BudgetConfig.sanitize(budget) else { return nil }
        return monthToDate / budget
    }

    /// Fração PROJETADA ao fim do mês — é este número que decide o alerta
    /// "vai estourar" (o de cima só diz o que já aconteceu).
    public func projectedFraction(ofBudget budget: Double?) -> Double? {
        guard let budget = BudgetConfig.sanitize(budget) else { return nil }
        return projected / budget
    }
}
