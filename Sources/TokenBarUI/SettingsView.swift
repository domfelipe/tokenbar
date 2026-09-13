import AppKit
import SwiftUI
import TokenBarCore

/// Janela de Settings (⌘,) — F5 Task 3, montada em 3 abas nativas (General /
/// Alerts / Menu Bar). Segue a linguagem da F5-T1: formulário macOS padrão
/// (`.formStyle(.grouped)`), tipografia do sistema com legendas em footnote
/// e estados HONESTOS (avisos de permissão/registro na própria janela).
/// Strings EN (constraint do plano). Toda a regra vive no `SettingsModel`.
public struct SettingsView: View {
    let model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            alertsTab
                .tabItem { Label("Alerts", systemImage: "bell") }
            menuBarTab
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            budgetTab
                .tabItem { Label("Budget", systemImage: "dollarsign.circle") }
        }
        .frame(width: 470)
        .task {
            await model.refreshNotificationStatus()
            model.refreshLoginStatus()
        }
    }

    // MARK: - General (launch at login + intervalos de refresh)

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }))
                if let notice = model.launchNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("launchNotice")
                }
            }
            Section("Refresh") {
                intervalRow(
                    title: "Open panel",
                    caption: "How often usage refreshes while the panel is open.",
                    seconds: model.foregroundRefreshSeconds,
                    range: AppSettingsStore.menuRange,
                    step: 10,
                    set: { newValue in Task { await model.setForegroundRefresh(seconds: newValue) } })
                intervalRow(
                    title: "In background",
                    caption: "How often usage refreshes with the panel closed.",
                    seconds: model.idleRefreshSeconds,
                    range: AppSettingsStore.idleRange,
                    step: 30,
                    set: { newValue in Task { await model.setIdleRefresh(seconds: newValue) } })
            }
        }
        .formStyle(.grouped)
    }

    private func intervalRow(
        title: String, caption: String, seconds: Int,
        range: ClosedRange<Int>, step: Int,
        set: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(seconds) s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(seconds) },
                    set: { newValue in set(Int(newValue)) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) refresh interval: \(seconds) seconds")
    }

    // MARK: - Budget (F7 Spend control)

    /// Orçamento do MÊS: teto global + teto por provider (o do provider vence).
    /// O valor entra em USD, como todo o app; o cálculo do gasto é o do
    /// mês-calendário (dia 1 até hoje) com a mesma precificação do resto —
    /// dia sem preço conhecido fica FORA, nunca contado como $0.
    private var budgetTab: some View {
        Form {
            Section("Monthly budget") {
                BudgetField(
                    label: "All providers",
                    value: model.budget.monthlyUSD,
                    set: { newValue in Task { await model.setMonthlyBudget(newValue) } })
                Text("Default cap for every provider that has no budget of its own. Spend counts the calendar month (1st until today). An empty field means no budget — it is not $0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Per provider") {
                ForEach(model.allProviders, id: \.self) { provider in
                    BudgetField(
                        label: MenuBarContent.displayName(for: provider),
                        value: model.budget.perProvider[provider],
                        set: { newValue in
                            Task { await model.setProviderBudget(newValue, for: provider) }
                        })
                }
                Text("A provider budget overrides the global one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // SEM isto a aba renderiza no estilo "columns": os rótulos ficam numa
        // coluna à ESQUERDA da janela (x=959 num cartão que começa em 1045,
        // medido por AX em 13/09) e a janela aparece só com os campos — era o
        // "Budget quebrado". As outras abas já usavam .grouped.
        .formStyle(.grouped)
    }

    // MARK: - Alerts (global + thresholds + lembrete de reset)

    private var alertsTab: some View {
        Form {
            Section {
                Toggle(
                    "Enable alerts",
                    isOn: Binding(
                        get: { model.alertsEnabled },
                        set: { newValue in Task { await model.setAlertsEnabled(newValue) } }))
                notificationStatusText
                if let notice = model.alertsNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("alertsNotice")
                }
                Text("Alerts fire once per window when usage crosses a threshold, and stay quiet until usage drops below it or the window renews.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Limit alerts")
            }

            Section("Thresholds") {
                ForEach(model.thresholds.indices, id: \.self) { index in
                    thresholdRow(index: index)
                }
                Button {
                    Task { await model.addThreshold() }
                } label: {
                    Label("Add threshold", systemImage: "plus")
                }
                .disabled(model.thresholds.count >= SettingsModel.maxThresholds
                    || (model.thresholds.last ?? 0) >= SettingsModel.thresholdRange.upperBound)
            }

            Section("Reset reminder") {
                Picker(
                    "Remind before reset",
                    selection: Binding(
                        get: { model.resetReminderMinutes },
                        set: { newValue in Task { await model.setResetReminder(minutes: newValue) } })
                ) {
                    Text("Off").tag(Int?.none)
                    ForEach(
                        SettingsModel.reminderOptions.compactMap { $0 }, id: \.self
                    ) { minutes in
                        Text("\(minutes) minutes").tag(Int?.some(minutes))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Estado REAL da autorização (honesto): só diz algo quando importa —
    /// ligado e autorizado fica em silêncio; negado mostra o caminho de
    /// desbloqueio.
    @ViewBuilder
    private var notificationStatusText: some View {
        switch model.notificationStatus {
        case .denied:
            Label(
                "Notifications are turned off for TokenBar in System Settings.",
                systemImage: "bell.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .granted where model.alertsEnabled:
            EmptyView()
        case .granted:
            Label("Notifications are enabled.", systemImage: "bell")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .notDetermined:
            EmptyView()
        }
    }

    private func thresholdRow(index: Int) -> some View {
        let value = model.thresholds[index]
        return HStack {
            Stepper(
                "\(value)% of window used",
                onIncrement: {
                    Task { await model.updateThreshold(at: index, value: value + SettingsModel.thresholdStep) }
                },
                onDecrement: {
                    Task { await model.updateThreshold(at: index, value: value - SettingsModel.thresholdStep) }
                })
            Spacer()
            Button {
                Task { await model.removeThreshold(at: index) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.thresholds.count <= 1)
            .accessibilityLabel("Remove \(value) percent threshold")
        }
    }

    // MARK: - Menu bar (checkboxes de providers no texto)

    private var menuBarTab: some View {
        Form {
            Section {
                ForEach(model.allProviders, id: \.self) { id in
                    Toggle(
                        MenuBarContent.displayName(for: id),
                        isOn: Binding(
                            get: { model.visibleProviders.contains(id) },
                            set: { newValue in
                                Task { await model.setProviderVisible(id, newValue) }
                            }))
                }
                Text("Checked providers appear in the menu bar text once they have data. Providers without data never appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Providers in the menu bar text")
            }
        }
        .formStyle(.grouped)
    }
}

/// Campo de orçamento em USD (F7): texto livre com commit no Enter ou ao sair
/// do foco. Entrada inválida NÃO apaga o que estava gravado — o campo volta ao
/// valor real (nada de zerar orçamento por typo); vazio = sem orçamento, que é
/// diferente de $0.
private struct BudgetField: View {
    let label: String
    let value: Double?
    let set: (Double?) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        // LabeledContent (e não um HStack manual): o rótulo entra na coluna de
        // rótulos do Form — é o que mantém o texto DENTRO da janela.
        LabeledContent(label) {
            TextField("No budget", text: $draft)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 110)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .accessibilityIdentifier("budgetField")
        }
        .onAppear { draft = Self.text(for: value) }
        .onChange(of: value) { _, newValue in draft = Self.text(for: newValue) }
    }

    /// Aceita "150", "1,250.50" (vírgula de milhar tolerada; decimal é ponto —
    /// o app é USD). Vazio limpa o teto; inválido reverte para o valor gravado.
    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if value != nil { set(nil) }
            draft = Self.text(for: nil)
            return
        }
        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        // Sanitiza AQUI também (review F7, Minor): sem isto um typo acima do teto
        // de sanidade virava "sem orçamento" e o teto gravado era apagado sem
        // aviso — ou o campo mostrava um valor que não existia no banco.
        guard let parsed = Double(normalized), parsed.isFinite,
              let sanitized = BudgetConfig.sanitize(parsed)
        else {
            draft = Self.text(for: value)
            return
        }
        set(sanitized)
        draft = Self.text(for: sanitized)
    }

    private static func text(for value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Linha "Settings…" (⌘,) do rodapé do painel (F5 Task 3): abre a scene
/// `Settings` do app via `\.openSettings` (API pública, macOS 14) e ativa o
/// app antes — menu bar apps são accessory e a janela nova precisa do app
/// ativo para vir à frente. Sem scene `Settings` no app (renders de teste),
/// a ação do sistema é no-op — nunca crash.
struct SettingsMenuRow: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuRowView(icon: "gearshape", title: "Settings…", shortcut: "⌘,") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
