import Foundation
import Testing
@testable import TokenBarCore

/// F7 Spend control — projeção de fechamento do mês e orçamento. Tudo puro:
/// calendário injetado, nada de relógio real.
@Suite
final class SpendProjectionTests {
    /// Calendar UTC FIXO (mesma convenção dos outros testes do core).
    let utc: Calendar

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        utc = calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("project: sem custo computável (nil) ou valor corrompido não inventa projeção")
    func projectRefusesAbsentOrCorruptCost() {
        #expect(SpendProjection.project(monthToDate: nil, now: date(2026, 8, 30), calendar: utc) == nil)
        #expect(SpendProjection.project(monthToDate: -1, now: date(2026, 8, 30), calendar: utc) == nil)
        #expect(SpendProjection.project(monthToDate: .nan, now: date(2026, 8, 30), calendar: utc) == nil)
        #expect(SpendProjection.project(monthToDate: .infinity, now: date(2026, 8, 30), calendar: utc) == nil)
    }

    @Test("project: taxa diária e fechamento pelo tamanho REAL do mês (28/29/31)")
    func projectUsesRealMonthLength() throws {
        // Dia 30 de agosto (31 dias) com $300 no mês → $10/dia → $310 no fechamento.
        let august = try #require(SpendProjection.project(monthToDate: 300, now: date(2026, 8, 30), calendar: utc))
        #expect(august.elapsedDays == 30)
        #expect(august.daysInMonth == 31)
        #expect(august.dailyRate == 10)
        #expect(august.projected == 310)
        #expect(august.monthToDate == 300)

        // Dia 1 projeta o PRÓPRIO dia (nada de "sem dado" no começo do mês).
        let firstDay = try #require(SpendProjection.project(monthToDate: 5, now: date(2026, 8, 1), calendar: utc))
        #expect(firstDay.elapsedDays == 1)
        #expect(firstDay.projected == 155)  // 5 × 31

        // Fevereiro de 2026 tem 28 dias; 2028 é bissexto (29).
        let february = try #require(SpendProjection.project(monthToDate: 100, now: date(2026, 2, 10), calendar: utc))
        #expect(february.daysInMonth == 28)
        #expect(february.projected == 280)
        let leap = try #require(SpendProjection.project(monthToDate: 100, now: date(2028, 2, 10), calendar: utc))
        #expect(leap.daysInMonth == 29)
        #expect(leap.projected == 290)

        // Custo ZERO real é custo: projeta zero (≠ nil, que é "sem preço").
        let zero = try #require(SpendProjection.project(monthToDate: 0, now: date(2026, 8, 10), calendar: utc))
        #expect(zero.projected == 0)
    }

    @Test("project: satura em valor absurdo (padrão Red Team) em vez de virar inf")
    func projectSaturatesAbsurdValues() throws {
        let huge = try #require(SpendProjection.project(monthToDate: 1e300, now: date(2026, 8, 2), calendar: utc))
        #expect(huge.projected == SpendProjection.maxProjected)
        #expect(huge.projected.isFinite)
    }

    @Test("fração do orçamento: consumida e PROJETADA (o número do alerta)")
    func budgetFractions() throws {
        let projection = try #require(SpendProjection.project(monthToDate: 60, now: date(2026, 9, 15), calendar: utc))
        #expect(projection.dailyRate == 4)
        #expect(projection.projected == 120)  // 4 × 30
        #expect(projection.fraction(ofBudget: 100) == 0.6)
        #expect(projection.projectedFraction(ofBudget: 100) == 1.2)

        // Sem orçamento válido não há fração.
        #expect(projection.fraction(ofBudget: nil) == nil)
        #expect(projection.fraction(ofBudget: 0) == nil)
        #expect(projection.projectedFraction(ofBudget: -5) == nil)
    }

    @Test("BudgetConfig: sanitização, teto efetivo (provider vence o global) e vazio")
    func budgetConfigSanitizesAndResolves() {
        #expect(BudgetConfig.sanitize(nil) == nil)
        #expect(BudgetConfig.sanitize(0) == nil)
        #expect(BudgetConfig.sanitize(-1) == nil)
        #expect(BudgetConfig.sanitize(.nan) == nil)
        #expect(BudgetConfig.sanitize(.infinity) == nil)
        #expect(BudgetConfig.sanitize(BudgetConfig.maxBudget + 1) == nil)
        #expect(BudgetConfig.sanitize(250) == 250)

        let config = BudgetConfig(
            monthlyUSD: 100,
            perProvider: [.claude: 400, .codex: 0, .zai: .nan])
        #expect(config.monthlyUSD == 100)
        #expect(config.perProvider == [.claude: 400])  // 0 e NaN caem fora
        #expect(config.budget(for: .claude) == 400)  // teto próprio vence
        #expect(config.budget(for: .codex) == 100)  // sem teto válido → global
        #expect(config.budget(for: .cursor) == 100)
        #expect(!config.isEmpty)

        let global = BudgetConfig(monthlyUSD: 100, perProvider: [:])
        #expect(global.budget(for: .claude) == 100)
        #expect(BudgetConfig.empty.isEmpty)
        #expect(BudgetConfig(monthlyUSD: nil, perProvider: [:]).budget(for: .claude) == nil)
        #expect(BudgetConfig(monthlyUSD: -1, perProvider: [.claude: -2]).isEmpty)
    }
}
