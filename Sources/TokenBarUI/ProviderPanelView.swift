import Charts
import SwiftUI
import TokenBarCore

/// Painel rico (F4 Task 2 — paridade CodexBar): linha de ABAS por provider
/// COM dado (logo autoral 16pt + sigla D5; selecionada destacada no accent),
/// detalhe do provider selecionado — header (nome + "updated Xs ago" + badge
/// local/auth), barras de janela com countdown de reset, linha de pacing,
/// custos hoje/30d e chart 30d.
///
/// Ciclo de vida e orçamento: a view SÓ existe com o painel aberto (conteúdo
/// do `MenuBarExtra` estilo `.window`) — o chart e o countdown morrem com o
/// fechamento. O COUNTDOWN é estado LOCAL da view (Timer de 30s enquanto
/// aberta, via `onAppear`/`onReceive`): nunca passa pelo render gate do menu
/// bar — a string "C:12.4k X:62%" não re-renderiza por causa de relógio.
/// Toda a lógica vive no `ProviderPanelModel` (puro, testável headless).
public struct ProviderPanelView: View {
    /// Store observável (dados chegam pelo ciclo do coordinator).
    let store: SnapshotStore
    /// Gerenciamento de contas (F4). `nil` = sem registry (sem DB) — controles
    /// de conta não aparecem.
    let accounts: AccountsModel?
    /// Ação de abrir o formulário "+ Add account" (janela própria no app).
    let addAccountAction: ((ProviderID) -> Void)?

    /// "Agora" local do countdown — atualizado a cada tick de 30 s. NUNCA
    /// alimenta texto do menu bar.
    @State private var countdownNow = Date()
    /// Tick de 30 s; a assinatura existe enquanto a view está instalada
    /// (painel aberto) — fechar o painel cancela a subscrição (spec F4).
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    public init(
        store: SnapshotStore,
        accounts: AccountsModel? = nil,
        addAccountAction: ((ProviderID) -> Void)? = nil
    ) {
        self.store = store
        self.accounts = accounts
        self.addAccountAction = addAccountAction
    }

    public var body: some View {
        let tabs = ProviderPanelModel.tabOrder(providers: store.providers)
        let selected = ProviderPanelModel.effectiveSelection(
            selected: store.selectedProvider, providers: store.providers)
        VStack(alignment: .leading, spacing: 10) {
            if tabs.isEmpty {
                Text("TokenBar — no data yet")
                    .foregroundStyle(.secondary)
            } else {
                tabRow(tabs, selected: selected)
                Divider()
                if let selected, let display = store.providers[selected] {
                    ProviderDetailView(
                        provider: selected,
                        display: display,
                        now: countdownNow,
                        accounts: accounts,
                        addAccountAction: addAccountAction)
                }
            }
        }
        .onAppear {
            countdownNow = Date()
            accounts?.reload()  // painel aberto: lista de contas fresca
        }
        .onReceive(ticker) { countdownNow = $0 }
    }

    // MARK: - Abas

    @ViewBuilder
    private func tabRow(_ tabs: [ProviderID], selected: ProviderID?) -> some View {
        HStack(spacing: 6) {
            ForEach(tabs, id: \.self) { id in
                tabChip(id, isSelected: id == selected)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func tabChip(_ id: ProviderID, isSelected: Bool) -> some View {
        Button {
            store.select(id)
        } label: {
            HStack(spacing: 4) {
                Self.logoOrFallback(id, size: 16)
                Text(MenuBarContent.sigla(for: id))
                    .font(.caption)
                    .bold()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : Color.primary.opacity(0.06)))
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor : .clear,
                    lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Provider \(MenuBarContent.displayName(for: id))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Logo autoral quando existe; fallback = sigla D5 sobre a cor de marca
    /// (ruling F4-LOGOS — nunca inventa imagem).
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

// MARK: - Detalhe do provider selecionado

struct ProviderDetailView: View {
    let provider: ProviderID
    let display: ProviderDisplay
    let now: Date
    /// Gerenciamento de contas (F4); `nil` = sem registry.
    let accounts: AccountsModel?
    let addAccountAction: ((ProviderID) -> Void)?

    var body: some View {
        // Conteúdo extraído em `ProviderDetailContent` (testabilidade: o
        // ImageRenderer não compõe ScrollView — a evidência visual do QA F4
        // renderiza o conteúdo direto). Comportamento idêntico.
        ScrollView(.vertical) {
            ProviderDetailContent(
                provider: provider, display: display, now: now,
                accounts: accounts, addAccountAction: addAccountAction)
        }
        .frame(maxHeight: 300)  // painel não cresce sem limite (orçamento)
        .accessibilityElement(children: .contain)
    }
}

/// Conteúdo do detalhe do provider (header, barras, pacing, custos, chart,
/// contas) — extraído do ScrollView para composição fora de janela.
struct ProviderDetailContent: View {
    let provider: ProviderID
    let display: ProviderDisplay
    let now: Date
    let accounts: AccountsModel?
    let addAccountAction: ((ProviderID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(rows) { row in
                WindowBarRow(row: row)
            }
            if let pacing = ProviderPanelModel.pacingText(display.pacing, now: now) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pacing)
                    Text(ProviderPanelModel.pacingDisclaimer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let costs = ProviderPanelModel.costsText(
                todayCostUsd: display.todayCostUsd,
                monthCostUsd: display.monthCostUsd,
                monthTokens: display.monthTokens)
            {
                Text(costs)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if !display.monthSeries.isEmpty {
                monthChart
            }
            accountsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var rows: [ProviderPanelModel.WindowRow] {
        ProviderPanelModel.windowRows(windows: display.windows, now: now)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            ProviderPanelView.logoOrFallback(provider, size: 18)
            Text(MenuBarContent.displayName(for: provider))
                .font(.headline)
            Text(ProviderPanelModel.authBadgeText(
                source: display.source, authState: display.authState))
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
            Spacer(minLength: 0)
            Text(ProviderPanelModel.updatedText(now: now, fetchedAt: display.fetchedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Chart 30d (daily_agg, ≤30 pontos, só existe com painel aberto)

    private var monthChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Chart(display.monthSeries) { point in
                BarMark(
                    x: .value("Day", point.day),
                    y: .value("Tokens", point.tokens)
                )
            }
            .chartXAxis(.hidden)  // 30 categorias não cabem legível — tooltip é F5
            .frame(height: 80)
            .accessibilityLabel("Tokens per day, last 30 days")
            Text("Last 30 days — tokens per day")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Contas (F4 multi-conta)

    /// Seção de contas: uma linha por conta quando o provider tem MAIS DE UMA
    /// conta ativa no ciclo (decisão F4-MULTIACCOUNT: com uma conta só, a
    /// seção é ruído — as janelas já estão no topo). Toggle liga/desliga a
    /// conta; context menu remove; path inexistente ganha badge de erro.
    @ViewBuilder
    private var accountsSection: some View {
        if let accounts, display.accounts.count > 1 {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(display.accounts) { account in
                    AccountRowView(
                        provider: provider,
                        account: account,
                        now: now,
                        model: accounts)
                }
                if let addAccountAction {
                    Button {
                        addAccountAction(provider)
                    } label: {
                        Label("Add account…", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add account for \(MenuBarContent.displayName(for: provider))")
                }
            }
        }
    }
}

// MARK: - Linha de conta (F4): label + badges + toggle ativa + remover

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
                if account.invalidCredential {
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
            ForEach(ProviderPanelModel.windowRows(windows: account.display.windows, now: now)) { row in
                WindowBarRow(row: row)
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

// MARK: - Linha de janela (barra de progresso + countdown)

struct WindowBarRow: View {
    let row: ProviderPanelModel.WindowRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.usageText)
                Spacer(minLength: 0)
                if let countdown = row.countdownText {
                    Text(countdown)
                        .foregroundStyle(countdown == "Renewed" ? .secondary : .primary)
                }
            }
            .font(.callout)
            if let fraction = row.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
