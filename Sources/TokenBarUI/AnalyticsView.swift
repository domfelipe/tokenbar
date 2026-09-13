import Charts
import SwiftUI
import TokenBarCore

/// Janela de Analytics (F3 Task 3, spec §8): seletor 24h/7d/30d, barras
/// tokens/dia empilhadas por provider, custo estimado/dia, top 5 modelos — e
/// o Usage & Spend (ledger diário + heatmap de custo). Só existe enquanto a
/// janela está aberta (o AppState cria a NSWindow sob demanda e a descarta no
/// fechamento — orçamento de RAM ≤40MB). Os dados vêm do `AnalyticsModel`
/// (testável headless); aqui é só desenho.
///
/// Mora no módulo de UI (e não no executável) porque o harness de QA
/// (`panelrender --analytics`) renderiza as views REAIS em PNG de evidência:
/// `AnalyticsContent` é o miolo SEM ScrollView (o ImageRenderer não compõe
/// ScrollView — limitação conhecida desde o QA F4) e `AnalyticsView` é a
/// janela com o chrome.
public struct AnalyticsView: View {
    let model: AnalyticsModel

    public init(model: AnalyticsModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            AnalyticsContent(model: model)
                .padding(16)
        }
        .frame(minWidth: 640, minHeight: 460)
        .task { await model.reload() }
        .onDisappear { model.clear() }
    }
}

/// Miolo da janela (mesmo VStack do corpo, sem o ScrollView): é o que o
/// harness renderiza.
public struct AnalyticsContent: View {
    let model: AnalyticsModel

    /// Lado da célula do heatmap (quadrado) — grade Mon..Sun.
    private static let cellSide: CGFloat = 22
    private static let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    /// Último degrau de intensidade da rampa do heatmap.
    private static let maxIntensityOpacity = 0.9

    public init(model: AnalyticsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Period", selection: periodBinding) {
                ForEach(AnalyticsModel.Period.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("analytics-period-picker")

            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            section("Tokens per day") {
                if model.providerSeries.isEmpty {
                    emptyState
                } else {
                    Chart(model.providerSeries) { point in
                        BarMark(
                            x: .value("Day", point.day),
                            y: .value("Tokens", point.tokens)
                        )
                        .foregroundStyle(by: .value("Provider", displayName(point.provider)))
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Tokens per day by provider")
                }
            }

            section("Estimated cost per day") {
                if model.dayCosts.isEmpty {
                    // Dia 100% sem custo computável não vira barra zero.
                    Text("No cost data for this period")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(model.dayCosts) { day in
                        BarMark(
                            x: .value("Day", day.day),
                            y: .value("Cost (USD)", day.costUSD)
                        )
                    }
                    .frame(height: 160)
                    .accessibilityLabel("Estimated cost per day in US dollars")
                }
            }

            section("Usage & spend") {
                ledger
            }

            section("Daily cost heatmap") {
                heatmap
            }

            section("Top models") {
                if model.topModels.isEmpty {
                    emptyState
                } else {
                    Chart(model.topModels) { slice in
                        BarMark(
                            x: .value("Tokens", slice.tokens),
                            y: .value("Model", slice.model)
                        )
                        .annotation(position: .trailing) {
                            // "~$" junto da barra; nil = sem custo.
                            if let cost = slice.costUSD {
                                Text(formatEstimatedUSD(cost))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: CGFloat(max(model.topModels.count, 1)) * 28 + 12)
                    .accessibilityLabel("Top models by tokens")
                }
            }

            Text("Costs are estimates based on public per-model pricing (events without a known price are excluded).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Usage & Spend

    /// Ledger diário: um dia por linha, do mais recente ao mais antigo, só
    /// dias COM evento. Custo `nil` = nenhum provider do dia tinha preço
    /// computável → "—", nunca "$0.00" (NULL ≠ 0; zero real sai como $0.00).
    @ViewBuilder
    private var ledger: some View {
        if model.ledgerRows.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ledgerRow(day: "Day", tokens: "Tokens", cost: "Cost (USD)", isHeader: true)
                Divider()
                ForEach(model.ledgerRows) { row in
                    ledgerRow(
                        day: row.day,
                        tokens: row.tokens.formatted(.number.grouping(.automatic)),
                        cost: Self.ledgerCostText(row.costUSD),
                        isHeader: false,
                        muted: row.costUSD == nil)
                    if row.id != model.ledgerRows.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily usage and spend ledger")
        }
    }

    private func ledgerRow(
        day: String, tokens: String, cost: String, isHeader: Bool, muted: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Text(day)
                .frame(width: 96, alignment: .leading)
            Text(tokens)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(cost)
                .frame(width: 84, alignment: .trailing)
                .foregroundStyle(muted ? Color.secondary : Color.primary)
        }
        .font(isHeader ? .caption.weight(.semibold) : .caption)
        .monospacedDigit()
        .foregroundStyle(isHeader ? Color.secondary : Color.primary)
        .padding(.vertical, 3)
    }

    /// Heatmap de custo diário: grade semanal (Mon..Sun) do PERÍODO INTEIRO —
    /// inclusive dia sem evento (célula vazia, ≠ zero). A cor é relativa ao
    /// maior custo do período; dia sem custo computável fica vazio e o tooltip
    /// mostra "—" (token existe, preço não).
    @ViewBuilder
    private var heatmap: some View {
        if model.heatmapCells.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.cellSide, height: 12)
                    }
                }
                ForEach(Array(Self.weeks(of: model.heatmapCells).enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 4) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                            heatmapCell(cell)
                        }
                    }
                }
                heatmapLegend
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Daily cost heatmap for the selected period")
            .accessibilityValue(heatmapAccessibilityValue)
        }
    }

    @ViewBuilder
    private func heatmapCell(_ cell: AnalyticsModel.HeatmapCell?) -> some View {
        if let cell {
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    Color.accentColor.opacity(
                        cell.intensity <= 0
                            ? 0.08 : 0.15 + (Self.maxIntensityOpacity - 0.15) * cell.intensity)
                )
                .frame(width: Self.cellSide, height: Self.cellSide)
                .help(heatmapTooltip(cell))
        } else {
            // Coluna antes do 1º dia da janela: nada pintado, nada inventado.
            Color.clear.frame(width: Self.cellSide, height: Self.cellSide)
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text("less").font(.caption2).foregroundStyle(.secondary)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(step <= 0 ? 0.08 : 0.15 + 0.75 * step))
                    .frame(width: 10, height: 10)
            }
            Text("more").font(.caption2).foregroundStyle(.secondary)
            Text("· blank = no computable cost or $0.00")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func heatmapTooltip(_ cell: AnalyticsModel.HeatmapCell) -> String {
        let cost = cell.costUSD.map(formatEstimatedUSD) ?? "—"
        return "\(cell.day) · \(cell.tokens.formatted(.number.grouping(.automatic))) tokens · \(cost)"
    }

    /// Valor AX honesto: quantos dias da janela têm custo computável, sem
    /// fingir leitura célula a célula (o detalhe fica no tooltip).
    private var heatmapAccessibilityValue: String {
        let withCost = model.heatmapCells.filter { $0.costUSD != nil }.count
        return "\(model.heatmapCells.count) days, \(withCost) with computable cost"
    }

    /// Agrupa as células em semanas Mon..Sun posicionando CADA célula pela
    /// própria coluna (`weekday`, que vem do calendar do banco) — e não por
    /// incremento cego: assim um dia faltando na lista (lacuna, filtro futuro)
    /// deixa a coluna VAZIA em vez de escorregar todos os dias seguintes uma
    /// casa. A semana vira quando a coluna não avança (domingo → segunda), e a
    /// 1ª semana abre com colunas vazias se a janela não começa na segunda.
    static func weeks(
        of cells: [AnalyticsModel.HeatmapCell], columns: Int = 7
    ) -> [[AnalyticsModel.HeatmapCell?]] {
        guard columns > 0, !cells.isEmpty else { return [] }
        var grid: [[AnalyticsModel.HeatmapCell?]] = []
        var row = Array<AnalyticsModel.HeatmapCell?>(repeating: nil, count: columns)
        var previousColumn = -1
        var hasRow = false
        for cell in cells {
            let column = min(max(cell.weekday - 1, 0), columns - 1)
            if hasRow, column <= previousColumn {
                grid.append(row)
                row = Array(repeating: nil, count: columns)
            }
            row[column] = cell
            hasRow = true
            previousColumn = column
        }
        grid.append(row)
        return grid
    }

    // MARK: - Auxiliares

    /// Placeholder da coluna de custo: dia sem NENHUM custo computável.
    static let noComputableCostText = "—"

    /// Texto da coluna de custo do ledger: "—" quando nenhum provider do dia
    /// tinha preço computável (NULL ≠ 0) — nunca "~$0.00" inventado. Zero REAL
    /// sai como "~$0.00" (gasto que existiu e foi zero ≠ preço desconhecido).
    static func ledgerCostText(_ cost: Double?) -> String {
        guard let cost else { return noComputableCostText }
        return formatEstimatedUSD(cost)
    }

    private var periodBinding: Binding<AnalyticsModel.Period> {
        Binding(
            get: { model.period },
            set: { newValue in
                model.setPeriod(newValue)
                Task { await model.reload() }
            })
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var emptyState: some View {
        Text("No data for this period")
            .foregroundStyle(.secondary)
    }

    private func displayName(_ rawProvider: String) -> String {
        ProviderID(rawValue: rawProvider).map { MenuBarContent.displayName(for: $0) } ?? rawProvider
    }
}
