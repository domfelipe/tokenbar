import Charts
import SwiftUI
import TokenBarCore
import TokenBarUI

/// Janela de Analytics (F3 Task 3, spec §8): seletor 24h/7d/30d, barras
/// tokens/dia empilhadas por provider, custo estimado/dia e top 5 modelos.
/// Só existe enquanto a janela está aberta (o AppState cria a NSWindow sob
/// demanda e a descarta no fechamento — orçamento de RAM ≤40MB). Os dados
/// vêm do `AnalyticsModel` (testável headless); aqui é só desenho.
struct AnalyticsView: View {
    let model: AnalyticsModel

    var body: some View {
        ScrollView {
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
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 460)
        .task { await model.reload() }
        .onDisappear { model.clear() }
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
