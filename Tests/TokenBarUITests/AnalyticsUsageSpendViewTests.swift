import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// Usage & Spend — lógica PURA da view (o que o PNG de evidência não prova
/// sozinho): posição do dia na grade semanal e o "—" da coluna de custo.
/// O desenho tem evidência própria via `panelrender --analytics`
/// (docs/qa/evidence/usage-spend-30d.png).
@Suite
final class AnalyticsUsageSpendViewTests {
    private func cell(_ day: String, weekday: Int) -> AnalyticsModel.HeatmapCell {
        AnalyticsModel.HeatmapCell(
            day: day, date: Date(timeIntervalSince1970: 0), weekday: weekday,
            tokens: 1, costUSD: 1, intensity: 0.5)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func dayString(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `count` dias consecutivos a partir de `start` ("yyyy-MM-dd"), com a
    /// coluna da semana CALCULADA no calendar UTC — o fixture não inventa
    /// weekday (2026-08-01 é sábado, não sexta).
    private func days(from start: String, count: Int) -> [AnalyticsModel.HeatmapCell] {
        let parts = start.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let base = Self.utc.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return [] }
        return (0..<count).compactMap { offset in
            guard let date = Self.utc.date(byAdding: .day, value: offset, to: base) else { return nil }
            let raw = Self.utc.component(.weekday, from: date)
            return cell(Self.dayString(date), weekday: ((raw + 5) % 7) + 1)
        }
    }

    @Test("weeks: grade Mon..Sun alinhada pela coluna; 1ª semana abre com o resto da anterior")
    func weeksAlignByWeekday() {
        let fixture = days(from: "2026-08-28", count: 10)  // 28/08 é sexta (weekday 5)
        #expect(fixture.first?.weekday == 5)
        let grid = AnalyticsContent.weeks(of: fixture)
        #expect(grid.count == 2)  // 3 dias (sex..dom) + 7 dias
        #expect(grid.map { $0.compactMap { $0 }.count } == [3, 7])
        #expect(grid[0].prefix(4).allSatisfy { $0 == nil })  // seg..qui não existem na janela
        #expect(grid[0][4]?.day == "2026-08-28")  // sexta
        #expect(grid[0][6]?.day == "2026-08-30")  // domingo fecha a semana
        #expect(grid[1][0]?.day == "2026-08-31")  // segunda seguinte
    }

    @Test("weeks: lacuna no meio da semana deixa a coluna vazia, sem deslocar o resto")
    func weeksWithMidWeekHoleKeepsColumns() {
        let week = days(from: "2026-08-31", count: 5)  // seg..sex
        let withHole = [week[0], week[1], week[3], week[4]]  // sem a quarta (02/09)
        let grid = AnalyticsContent.weeks(of: withHole)
        #expect(grid.count == 1)
        #expect(grid[0][2] == nil)  // quarta: buraco, não deslocamento
        #expect(grid[0][3]?.day == "2026-09-03")  // quinta na coluna dela
        #expect(grid[0][4]?.day == "2026-09-04")
    }

    @Test("weeks: lacuna que cruza o domingo abre semana nova")
    func weeksWithHoleAcrossWeekBoundary() {
        let fixture = days(from: "2026-08-28", count: 5)  // sex..ter
        let withHole = [fixture[0], fixture[1], fixture[3], fixture[4]]  // sem o domingo
        let grid = AnalyticsContent.weeks(of: withHole)
        #expect(grid.count == 2)
        #expect(grid[0].compactMap { $0 }.map(\.day) == ["2026-08-28", "2026-08-29"])
        #expect(grid[0][6] == nil)  // domingo faltando: coluna vazia
        #expect(grid[1].compactMap { $0 }.map(\.day) == ["2026-08-31", "2026-09-01"])
    }

    @Test("weeks: janela de 1 dia (24h) e janela vazia")
    func weeksSingleDayAndEmpty() {
        let single = AnalyticsContent.weeks(of: [cell("2026-08-30", weekday: 7)])
        #expect(single.count == 1)
        #expect(single[0].compactMap { $0 }.map(\.day) == ["2026-08-30"])
        #expect(single[0][6]?.day == "2026-08-30")  // coluna do domingo
        #expect(AnalyticsContent.weeks(of: []).isEmpty)
    }

    @Test("ledger: custo nil vira travessão, nunca \"~$0.00\"; zero real mantém o valor")
    func ledgerCostPlaceholder() {
        #expect(AnalyticsContent.ledgerCostText(nil) == "\u{2014}")
        // O requisito é a DISTINÇÃO: "—" (preço desconhecido) ≠ "~$0.00" (custou zero).
        #expect(AnalyticsContent.ledgerCostText(nil) != formatEstimatedUSD(0))
        #expect(AnalyticsContent.ledgerCostText(0) == formatEstimatedUSD(0))
        #expect(AnalyticsContent.ledgerCostText(0.5) == formatEstimatedUSD(0.5))
    }
}
