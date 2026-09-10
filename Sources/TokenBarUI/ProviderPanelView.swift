import SwiftUI
import TokenBarCore

/// Painel do menu bar — DESIGN PORTADO 1:1 da referência MIT (CodexBar;
/// ruling F5-DESIGN, ver NOTICE na raiz): chip-bar de providers com logos
/// (16pt template + indicador de quota 2pt, chip selecionado no accent do
/// sistema), header (nome semibold + "Updated just now" + badge de fonte à
/// direita), linhas de janela com BARRA SEGMENTADA (fill na cor do provider,
/// faixa de pacing verde/vermelha, trilha cinza), dashboard com KPIs grandes
/// ("Today / 30d / Recent tokens / 30d tokens"), chart diário de barras com
/// anotação de pico, linhas de detalhe com disclaimer de estimativa, linhas
/// de ação com chevron e rodapé de menu (Refresh ⌘R / Settings… ⌘, / About /
/// Quit ⌘Q).
///
/// Tokens de layout (de `UsageMenuCardLayout` e vizinhos, MIT): largura 310,
/// padding horizontal 20, espaçamento de seção 12/6, barra 6pt (raio = h/2),
/// chart 58pt (barras raio 1.5, espaçamento ≤ 2), KPI grid 2 colunas.
///
/// Ciclo de vida e orçamento: a view SÓ existe com o painel aberto (conteúdo
/// do `MenuBarExtra` estilo `.window`) — o chart e o countdown morrem com o
/// fechamento. O COUNTDOWN é estado LOCAL da view (Timer de 30s enquanto
/// aberta): nunca passa pelo render gate do menu bar. Toda a lógica vive no
/// `ProviderPanelModel` (puro, testável headless).
public struct ProviderPanelView: View {
    /// Largura do cartão da referência (`menuCardBaseWidth` = 310, MIT).
    static let panelWidth: CGFloat = 310
    /// Altura máxima da área rolável (orçamento do painel; o rodapé fica
    /// fixo embaixo, como no menu da referência).
    static let contentMaxHeight: CGFloat = 470

    /// Store observável (dados chegam pelo ciclo do coordinator).
    let store: SnapshotStore
    /// Gerenciamento de contas (F4). `nil` = sem registry (sem DB) — controles
    /// de conta não aparecem.
    let accounts: AccountsModel?
    /// Ação de abrir o formulário "+ Add account" (janela própria no app).
    let addAccountAction: ((ProviderID) -> Void)?
    /// Ações do painel (F5): `nil` = linha omitida (renders de teste).
    /// Settings fica DESABILITADO até a Task 3 (janela ainda não existe) —
    /// a linha aparece, o clique não.
    let refreshAction: (() -> Void)?
    let analyticsAction: (() -> Void)?
    let exportAction: (() -> Void)?
    let aboutAction: (() -> Void)?
    let quitAction: (() -> Void)?

    /// "Agora" local do countdown — atualizado a cada tick de 30 s. NUNCA
    /// alimenta texto do menu bar.
    @State private var countdownNow = Date()
    /// Tick de 30 s; a assinatura existe enquanto a view está instalada
    /// (painel aberto) — fechar o painel cancela a subscrição (spec F4).
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    public init(
        store: SnapshotStore,
        accounts: AccountsModel? = nil,
        addAccountAction: ((ProviderID) -> Void)? = nil,
        refreshAction: (() -> Void)? = nil,
        analyticsAction: (() -> Void)? = nil,
        exportAction: (() -> Void)? = nil,
        aboutAction: (() -> Void)? = nil,
        quitAction: (() -> Void)? = nil
    ) {
        self.store = store
        self.accounts = accounts
        self.addAccountAction = addAccountAction
        self.refreshAction = refreshAction
        self.analyticsAction = analyticsAction
        self.exportAction = exportAction
        self.aboutAction = aboutAction
        self.quitAction = quitAction
    }

    public var body: some View {
        let tabs = ProviderPanelModel.tabOrder(providers: store.providers)
        let selected = ProviderPanelModel.effectiveSelection(
            selected: store.selectedProvider, providers: store.providers)
        Group {
            if tabs.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ProviderChipBar(
                        tabs: tabs, selected: selected, select: { store.select($0) },
                        providers: store.providers)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    Divider()
                    ScrollView(.vertical) {
                        if let selected, let display = store.providers[selected] {
                            ProviderDetailContent(
                                provider: selected,
                                display: display,
                                now: countdownNow,
                                accounts: accounts,
                                addAccountAction: addAccountAction,
                                analyticsAction: analyticsAction,
                                exportAction: exportAction)
                                .padding(.horizontal, 20)
                                .padding(.top, 6)
                                .padding(.bottom, 6)
                        }
                    }
                    .frame(maxHeight: Self.contentMaxHeight)
                    .accessibilityElement(children: .contain)
                    Divider()
                    footer
                }
                .frame(width: Self.panelWidth, alignment: .leading)
            }
        }
        .onAppear {
            countdownNow = Date()
            accounts?.reload()  // painel aberto: lista de contas fresca
        }
        .onReceive(ticker) { countdownNow = $0 }
    }

    /// Sem dados ainda — placeholder honesto (nada inventado).
    private var emptyState: some View {
        Text("TokenBar — no data yet")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(width: Self.panelWidth, alignment: .leading)
    }

    // MARK: Rodapé (menu da referência: ícone + título + atalho à direita)

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let refreshAction {
                MenuRowView(icon: "arrow.clockwise", title: "Refresh", shortcut: "⌘R")
                    { refreshAction() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Settings ⌘, — DESABILITADO até a Task 3 (janela de ajustes
            // ainda não existe); a linha já nasce no lugar da referência.
            MenuRowView(
                icon: "gearshape", title: "Settings…", shortcut: "⌘,",
                isEnabled: false, action: {})
            if let aboutAction {
                MenuRowView(icon: "info.circle", title: "About TokenBar") { aboutAction() }
            }
            if let quitAction {
                MenuRowView(icon: "power", title: "Quit TokenBar", shortcut: "⌘Q")
                    { quitAction() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
    }
}

// MARK: - Linha de menu do rodapé (ícone + título + atalho)

struct MenuRowView: View {
    let icon: String
    let title: String
    var shortcut: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Chip-bar de providers (topo do painel)

/// Fila de chips (port do `ProviderSwitcherView`, MIT): ícone 16pt template +
/// nome truncado, largura uniforme que quebra em linhas (grade adaptativa —
/// mínimo ~52pt, folga 1-2pt), selecionado com fundo no accent do sistema e
/// texto branco; indicador de quota (2pt, cor do provider) na base do chip.
struct ProviderChipBar: View {
    let tabs: [ProviderID]
    let selected: ProviderID?
    let select: (ProviderID) -> Void
    let providers: [ProviderID: ProviderDisplay]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 52), spacing: 1)],
            alignment: .leading,
            spacing: 2)
        {
            ForEach(tabs, id: \.self) { id in
                ProviderChipView(
                    id: id,
                    isSelected: id == selected,
                    percent: providers[id]?.percent,
                    select: select)
            }
        }
    }
}

struct ProviderChipView: View {
    let id: ProviderID
    let isSelected: Bool
    /// Fração crítica (0...100) do provider — alimenta o indicador de quota
    /// na base do chip; `nil` = sem barra (nada inventado).
    let percent: Double?
    let select: (ProviderID) -> Void

    var body: some View {
        Button {
            select(id)
        } label: {
            VStack(spacing: 2) {
                ProviderPanelView.logoOrFallback(id, size: 16)
                Text(MenuBarContent.displayName(for: id))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                // Indicador de quota (port do QuotaIndicator: 2pt, inset 8).
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    if let percent {
                        Capsule()
                            .fill(ProviderLogo.brandColor(for: id))
                            .frame(width: max(0, min(100, percent)) / 100 * Self.quotaWidth)
                    }
                }
                .frame(width: Self.quotaWidth, height: 2)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Provider \(MenuBarContent.displayName(for: id))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    static let quotaWidth: CGFloat = 36
}

// MARK: - Conteúdo do detalhe do provider selecionado

struct ProviderDetailContent: View {
    let provider: ProviderID
    let display: ProviderDisplay
    let now: Date
    let accounts: AccountsModel?
    let addAccountAction: ((ProviderID) -> Void)?
    let analyticsAction: (() -> Void)?
    let exportAction: (() -> Void)?

    var body: some View {
        let rows = ProviderPanelModel.windowRows(
            windows: display.windows, now: now, pacing: display.pacing)
        let accountsVisible = accountsVisible(rows: rows)
        return VStack(alignment: .leading, spacing: 12) {
            header
            usageSection(rows: rows)
            dashboardSection
            accountsSection(rows: rows, visible: accountsVisible)
            actionRows(separated: accountsVisible)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header (nome / "Updated just now" + badge — layout da referência)

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Linha 1 do `UsageMenuCardHeaderView` (MIT): nome semibold.
            Text(MenuBarContent.displayName(for: provider))
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
            // Linha 2: subtítulo à esquerda, plan/badge à direita (não temos
            // dado de plano no motor — o badge de fonte ocupa o lugar, sem
            // invenção).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ProviderPanelModel.updatedText(now: now, fetchedAt: display.fetchedAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(ProviderPanelModel.authBadgeText(
                    source: display.source, authState: display.authState))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        Divider()
    }

    // MARK: Janelas (título + barra segmentada + meta de pacing)

    private func usageSection(rows: [ProviderPanelModel.WindowRow]) -> some View {
        let pacingMeta = ProviderPanelModel.pacingText(display.pacing, now: now)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                WindowBarRow(row: row, tint: ProviderLogo.brandColor(for: provider))
                // Meta de pacing (port da referência: "69% in deficit ·
                // Exhausts in 2h 44m") logo sob a barra da janela-âncora.
                if row.paceStripePercent != nil, let pacingMeta {
                    Text(pacingMeta)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, -2)
                }
            }
        }
    }

    // MARK: Dashboard (KPIs + chart + detalhes)

    @ViewBuilder
    private var dashboardSection: some View {
        let shows = ProviderPanelModel.showsDashboard(
            weekHistoryAvailable: display.weekHistoryAvailable,
            monthHistoryAvailable: display.monthHistoryAvailable,
            todayCostUsd: display.todayCostUsd,
            monthCostUsd: display.monthCostUsd,
            todayTokens: display.todayTokens,
            monthTokens: display.monthTokens,
            series: display.monthSeries)
        if shows {
            Divider()
            DashboardSectionView(display: display, provider: provider)
        }
    }

    // MARK: Contas (F4 multi-conta — preservada sob o dashboard)

    /// Seção de contas: uma linha por conta, montada pela UNIÃO registry ⊕
    /// ciclo (`ProviderPanelModel.accountRows`) — ATIVA ou INATIVA. Toggle
    /// liga/desliga; context menu remove; badges: "inactive", "invalid path",
    /// auth/local.
    @ViewBuilder
    private func accountsSection(
        rows: [ProviderPanelModel.WindowRow], visible: Bool
    ) -> some View {
        if visible, let accounts {
            let registered = accounts.accounts(for: provider)
            let accountRows = ProviderPanelModel.accountRows(
                cycled: display.accounts, registered: registered)
            VStack(alignment: .leading, spacing: 6) {
                Text("Accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(accountRows) { account in
                    AccountRowView(
                        provider: provider,
                        account: account,
                        now: now,
                        model: accounts)
                }
            }
        }
    }

    private func accountsVisible(rows: [ProviderPanelModel.WindowRow]) -> Bool {
        guard let accounts else { return false }
        let registered = accounts.accounts(for: provider)
        let accountRows = ProviderPanelModel.accountRows(
            cycled: display.accounts, registered: registered)
        return ProviderPanelModel.showsAccountsSection(
            rows: accountRows, registeredCount: registered.count)
    }

    // MARK: Linhas de ação (chevron — port do menu da referência)

    @ViewBuilder
    private func actionRows(separated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if separated { Divider() }
            if let analyticsAction {
                ActionRowView(icon: "chart.bar", title: "Usage dashboard")
                    { analyticsAction() }
            }
            if let exportAction {
                ActionRowView(icon: "square.and.arrow.up", title: "Export")
                    { exportAction() }
            }
            if let addAccountAction {
                ActionRowView(
                    icon: "plus", title: "Add account…", showsChevron: false)
                { addAccountAction(provider) }
            }
        }
    }
}

// MARK: - Dashboard (KPI grid + chart diário + linhas de detalhe)

/// Port de `InlineUsageDashboardContent` (MIT): KPIs em grid 2 colunas
/// ("Today" com ênfase headline), barras diárias 58pt com rótulo de pico no
/// topo, linhas de detalhe com janela 7d/top model/disclaimer.
struct DashboardSectionView: View {
    let display: ProviderDisplay
    let provider: ProviderID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cells = ProviderPanelModel.kpiCells(
                todayCostUsd: display.todayCostUsd,
                monthCostUsd: display.monthCostUsd,
                todayTokens: display.todayTokens,
                monthTokens: display.monthTokens)
            {
                kpiGrid(cells)
            }
            if let chart = ProviderPanelModel.chartModel(series: display.monthSeries) {
                MiniUsageBars(
                    chart: chart, tint: ProviderLogo.brandColor(for: provider))
            }
            let lines = ProviderPanelModel.detailLines(
                weekCostUsd: display.weekCostUsd,
                weekTokens: display.weekTokens,
                topModel: display.topModel7d,
                showsEstimate: display.todayCostUsd != nil || display.monthCostUsd != nil
                    || display.pacing != nil)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func kpiGrid(_ cells: [ProviderPanelModel.KPICell]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 118), alignment: .leading),
                GridItem(.flexible(minimum: 100), alignment: .leading),
            ],
            alignment: .leading,
            spacing: 6)
        {
            ForEach(cells) { cell in
                VStack(alignment: .leading, spacing: 1) {
                    Text(cell.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(cell.value)
                        .font(cell.emphasis ? .headline : .subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Barras diárias (port de `MiniUsageBars`, MIT): rótulo do pico no topo à
/// direita (caption2, monoespaçado), barras raio 1.5 com espaçamento ≤ 2,
/// opacidade 0.42 + 0.58·razão (piso 0.18), mínimo 3pt, linha de base 1pt.
struct MiniUsageBars: View {
    let chart: ProviderPanelModel.ChartModel
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let peakLabel = chart.peakLabel {
                Text(peakLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            GeometryReader { geometry in
                let layout = barLayout(width: geometry.size.width, count: chart.values.count)
                HStack(alignment: .bottom, spacing: layout.spacing) {
                    ForEach(Array(chart.values.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(fill(for: value))
                            .frame(width: layout.barWidth)
                            .frame(height: barHeight(for: value, available: geometry.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .overlay(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 1)
                }
            }
        }
        .frame(height: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage per day for the last 30 days")
    }

    private func fill(for value: Double) -> Color {
        let maxima = chart.values.max() ?? 0
        guard maxima > 0, value > 0 else { return .clear }
        let ratio = max(0.18, value / maxima)
        return tint.opacity(0.42 + ratio * 0.58)
    }

    private func barHeight(for value: Double, available: CGFloat) -> CGFloat {
        let maxima = chart.values.max() ?? 0
        guard maxima > 0, value > 0 else { return 1 }
        return max(3, CGFloat(value / maxima) * available)
    }

    /// Port de `InlineUsageBarLayout`: espaçamento ≤ 2 (¼ da fatia da barra),
    /// largura uniforme.
    private func barLayout(width: CGFloat, count: Int) -> (spacing: CGFloat, barWidth: CGFloat) {
        guard count > 0 else { return (0, 0) }
        let spacing = count <= 1 ? 0 : min(2, width / CGFloat(count) / 4)
        let barWidth = count == 1
            ? width
            : max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        return (spacing, barWidth)
    }
}

// MARK: - Linha de conta (F4 multi-conta): label + badges + toggle + remover

struct AccountRowView: View {
    let provider: ProviderID
    let account: AccountDisplay
    let now: Date
    @Bindable var model: AccountsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(account.label)
                    .font(.callout)
                if !account.active {
                    // Conta registrada fora do ciclo (fix review final): badge
                    // "inactive" — a linha (e com ela toggle/Remove) permanece.
                    Text("inactive")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                } else if account.invalidCredential {
                    Text("invalid path")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.red.opacity(0.75)))
                } else {
                    Text(ProviderPanelModel.authBadgeText(
                        source: account.display.source,
                        authState: account.display.authState))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer(minLength: 0)
                Toggle("", isOn: activeBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Enable \(account.label)")
            }
            // Janelas DA CONTA (decisão F4: com >1 conta, as linhas de janela
            // por conta moram aqui — o topo mostra a crítica/agregada).
            ForEach(
                ProviderPanelModel.windowRows(windows: account.display.windows, now: now)
            ) { row in
                WindowBarRow(row: row, tint: ProviderLogo.brandColor(for: provider))
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Remove account", role: .destructive) {
                if let registered = registered {
                    model.remove(registered)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Registro correspondente no registry (fonte de remove/setActive).
    private var registered: RegisteredAccount? {
        model.accounts(for: provider).first { $0.accountKey == account.key }
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { account.active },
            set: { newValue in
                if let registered {
                    model.setActive(newValue, account: registered)
                }
            })
    }
}

// MARK: - Linha de janela (título + barra segmentada + meta de pacing)

/// Port de `MetricRow` (MIT): "Weekly 74% used" (body medium) + "Renews in
/// 6d 16h" (footnote secondary) na mesma linha, barra segmentada de 6pt,
/// meta de pacing (footnote secondary) sob a barra.
struct WindowBarRow: View {
    let row: ProviderPanelModel.WindowRow
    /// Cor de fill = cor de marca do provider (resolvida pela seção pai).
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.usageText)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if let countdown = row.countdownText {
                    Text(countdown)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if let fraction = row.fraction {
                SegmentedUsageBar(
                    percent: fraction * 100,
                    paceStripePercent: row.paceStripePercent,
                    paceIsDeficit: row.paceIsDeficit,
                    tint: tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Barra segmentada (Canvas — port de `UsageProgressBar`, MIT)

/// Trilha cinza (tertiaryLabel 22%) + fill na cor do provider + FAIXA de
/// pacing (2pt, verde/vermelho, com "punch-out" de 1px de cada lado — mesma
/// técnica de canvas da referência). Altura 6, raio h/2.
struct SegmentedUsageBar: View {
    let percent: Double
    let paceStripePercent: Double?
    let paceIsDeficit: Bool
    let tint: Color

    private var clamped: Double { min(100, max(0, percent)) }

    var body: some View {
        Canvas { context, size in
            let fillPercent = Self.renderedFillPercent(clamped)
            let fillWidth = size.width * fillPercent / 100
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            // Trilha
            let trackPath = Path { p in p.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(
                trackPath,
                with: .color(Color(nsColor: .tertiaryLabelColor).opacity(0.22)))

            // Fill (usado — cor do provider)
            if fillWidth > 0 {
                let fillRect = CGRect(
                    x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { p in p.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(tint))
            }

            // Faixa de pacing: punch-out + stripe central (vermelho em
            // déficit, verde no ritmo).
            if let stripe = paceStripePercent {
                let x = size.width * min(100, max(0, stripe)) / 100
                let stripeColor: Color = paceIsDeficit ? .red : .green
                let punch = CGRect(x: x - 2, y: -4, width: 4, height: size.height + 8)
                let stripeRect = CGRect(x: x - 1, y: 0, width: 2, height: size.height)
                context.blendMode = .destinationOut
                context.fill(Path(punch), with: .color(.white.opacity(0.9)))
                context.blendMode = .normal
                context.fill(Path(stripeRect), with: .color(stripeColor))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Usage used")
        .accessibilityValue("\(Int(clamped.rounded())) percent")
    }

    /// Alinha a borda com o rótulo arredondado: <0,5% vazio; ≥99,5% cheio.
    static func renderedFillPercent(_ percent: Double) -> Double {
        let clamped = min(100, max(0, percent))
        let display = Int(clamped.rounded())
        if display <= 0 { return 0 }
        if display >= 100 { return 100 }
        return clamped
    }
}

// MARK: - Linha de ação (ícone + título + chevron)

struct ActionRowView: View {
    let icon: String
    let title: String
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityLabel(title)
    }
}

// MARK: - Logos

extension ProviderPanelView {
    /// Logo MIT portado quando existe; fallback = sigla D5 sobre a cor de
    /// marca da referência (ruling F5-DESIGN). Nunca inventa imagem.
    @ViewBuilder
    static func logoOrFallback(_ id: ProviderID, size: CGFloat) -> some View {
        if let image = ProviderLogo.image(for: id) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .frame(width: size, height: size)
        } else {
            Text(MenuBarContent.sigla(for: id))
                .font(.caption2)
                .bold()
                .foregroundStyle(.white)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ProviderLogo.brandColor(for: id)))
                .frame(width: size + 2, height: size + 2)
        }
    }
}
