import Foundation
import TokenBarCore

/// Ponto diário da série 30d de um provider (chart do painel) —
/// no máximo 30 pontos por provider (`daily_agg`, nunca eventos crus). `day`
/// é "yyyy-MM-dd" (ordenação do SQL = cronológica; categoria no chart).
public struct PanelDayPoint: Identifiable, Equatable, Sendable {
    public let day: String
    public let tokens: Int64
    public let costUSD: Double?

    public init(day: String, tokens: Int64, costUSD: Double?) {
        self.day = day
        self.tokens = tokens
        self.costUSD = costUSD
    }

    public var id: String { day }
}

/// View-model do painel — TODA a lógica de estado/texto, sem SwiftUI: seleção
/// de aba, linha de janela (`WindowBarRow` com a faixa de pacing na barra),
/// countdown relativo, meta de pacing, KPIs do dashboard, linhas de detalhe,
/// chart diário, badge de auth e "Updated just now". Funções puras com
/// `now`/dados injetados — testável headless; a renderização
/// (`ProviderPanelView`) só desenha.
///
/// DESIGN F5 (ruling F5-DESIGN): formato/textos portados 1:1 da referência
/// MIT (CodexBar `UsagePaceText`/`UsageFormatter`/`InlineUsageDashboardContent`)
/// — ver NOTICE na raiz. Dados SEMPRE do motor local (UsageWindow,
/// HistoryQueries, PacingEngine); segmento ausente = linha/célula omitida
/// ("—" só onde a referência usa "—"). Strings em EN (Global Constraints).
public enum ProviderPanelModel {
    // MARK: - Abas

    /// Ordem das abas: providers COM dado, ordem D5 (C, X, G, Z; demais ids
    /// atrás em ordem alfabética) — a MESMA ordem do menu bar.
    public static func tabOrder(providers: [ProviderID: ProviderDisplay]) -> [ProviderID] {
        MenuBarContent(providers: providers).orderedProviders().map(\.id)
    }

    /// Seleção efetiva: a escolhida quando ainda tem dado; senão a primeira
    /// aba com dado (fallback automático — provider perdeu dado, aba cai p/
    /// um provider vivo; nunca aba morta nem provider inventado).
    public static func effectiveSelection(
        selected: ProviderID?, providers: [ProviderID: ProviderDisplay]
    ) -> ProviderID? {
        let tabs = tabOrder(providers: providers)
        if let selected, tabs.contains(selected) { return selected }
        return tabs.first
    }

    // MARK: - Countdown de reset

    /// Countdown relativo: "6d 16h" (≥1 dia), "2h 44m" (≥1h), "44m" (<1h,
    /// mínimo 1m). Reset no passado → "renewed" (a janela já virou; o próximo
    /// ciclo traz os valores novos — nada a prometer sobre a janela velha).
    public static func countdownText(from now: Date, to resetsAt: Date) -> String {
        let delta = resetsAt.timeIntervalSince(now)
        guard delta > 0 else { return "renewed" }
        let days = Int(delta / 86_400)
        let hours = Int(delta.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(delta.truncatingRemainder(dividingBy: 3_600) / 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    /// "Renews in 6d 16h" (countdown da janela de um `WindowBarRow`);
    /// reset já passado → "Renewed" (a janela virou; o próximo ciclo atualiza).
    public static func renewText(from now: Date, to resetsAt: Date) -> String {
        let countdown = countdownText(from: now, to: resetsAt)
        if countdown == "renewed" { return "Renewed" }
        return "Renews in " + countdown
    }

    // MARK: - Linhas de janela (WindowBarRow)

    /// Estado puro de uma linha de janela do painel. `fraction` é 0...1
    /// (saturado) ou `nil` = desconhecida (modo local — sem barra, sem
    /// porcentagem inventada).
    ///
    /// Faixa de pacing (F5, port de `UsageProgressBar`): `paceStripePercent`
    /// marca ONDE a projeção atual termina (saturada em 0...100) e
    /// `paceIsDeficit` pinta a faixa de vermelho (projeção estoura a janela)
    /// ou verde (cabe no ritmo) — MESMA semântica da referência. A faixa só
    /// existe na janela CRÍTICA (âncora do `PacingEngine`).
    public struct WindowRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: WindowKind
        public let fraction: Double?
        /// "Weekly 74% used" — ou "Weekly window" quando a fração é
        /// desconhecida (nada a inventar).
        public let usageText: String
        /// "Renews in 6d 16h"; `nil` quando a janela não tem `resetsAt`
        /// (janela sem reset → só contagem, Global Constraints).
        public let countdownText: String?
        /// Posição da faixa de pacing em % da barra (0...100); `nil` = sem
        /// forecast (a faixa não aparece — nada de chute).
        public let paceStripePercent: Double?
        /// `true` = projeção estoura a janela (`deficitPct` do engine) →
        /// faixa vermelha; `false` = verde.
        public let paceIsDeficit: Bool
    }

    /// Uma linha por janela do snapshot, na ordem do provider. O pacing
    /// (quando existe) é da janela CRÍTICA — a faixa vai nessa linha.
    public static func windowRows(
        windows: [UsageWindow], now: Date, pacing: PacingForecast? = nil
    ) -> [WindowRow] {
        let criticalFraction = criticalWindowFraction(pacing: pacing, windows: windows)
        return windows.enumerated().map { index, window in
            let fraction = window.usedFraction.map { min(max($0, 0), 1) }
            let usageText: String
            if let fraction {
                usageText = "\(kindTitle(window.kind)) \(Int((fraction * 100).rounded()))% used"
            } else {
                usageText = "\(kindTitle(window.kind)) window"
            }
            let countdown = window.resetsAt.map { renewText(from: now, to: $0) }
            // A faixa de pacing pertence à janela-âncora (mesma fração da
            // crítica; empate → primeira, igual ao `criticalWindow` do menu).
            var stripe: Double?
            var isDeficit = false
            if let pacing, let projected = projectedFractionSaturated(pacing),
               let fraction, fraction == criticalFraction
            {
                stripe = (projected * 100).rounded()
                isDeficit = pacing.deficitPct != nil
            }
            return WindowRow(
                id: "\(window.kind.rawValue)#\(index)",
                kind: window.kind,
                fraction: fraction,
                usageText: usageText,
                countdownText: countdown,
                paceStripePercent: stripe,
                paceIsDeficit: isDeficit)
        }
    }

    /// Fração da janela crítica (maior fração; empate → primeira) — a âncora
    /// do `PacingEngine`. `nil` quando nenhuma janela tem fração.
    private static func criticalWindowFraction(
        pacing: PacingForecast?, windows: [UsageWindow]
    ) -> Double? {
        guard pacing != nil else { return nil }
        var best: Double?
        for window in windows {
            guard let fraction = window.usedFraction else { continue }
            let clamped = min(max(fraction, 0), 1)
            if best == nil || clamped > best! { best = clamped }
        }
        return best
    }

    /// `projectedFraction` saturado em 0...1 (a faixa vive DENTRO da barra;
    /// projeção > 100% encosta no fim — o vermelho conta o resto na meta).
    private static func projectedFractionSaturated(_ pacing: PacingForecast) -> Double? {
        guard pacing.projectedFraction.isFinite else { return nil }
        return min(max(pacing.projectedFraction, 0), 1)
    }

    /// Título estável da janela pelo `kind` (não pelo label do provider — o
    /// label varia por API: "Hoje", "Semanal", "5h"; o kind é canônico).
    static func kindTitle(_ kind: WindowKind) -> String {
        switch kind {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .daily: return "Daily"
        case .monthly: return "Monthly"
        }
    }

    // MARK: - Pacing (meta da linha, formato da referência)

    /// Meta da linha de janela com forecast — port de `UsagePaceText`:
    /// - déficit: "69% in deficit · Exhausts in 2h 44m" (eta válido);
    ///   eta inválido/zero com déficit → só o déficit (nada a prometer);
    /// - folga: "N% in reserve · Lasts until reset" (projeção < 100%);
    /// - no ritmo: "On pace · Lasts until reset".
    /// `nil` = sem forecast (menos de 2 pontos, janela sem reset/fração) →
    /// linha NÃO aparece (sem chute).
    public static func pacingText(_ forecast: PacingForecast?, now: Date) -> String? {
        guard let forecast else { return nil }
        let projected = forecast.projectedFraction
        if let deficit = forecast.deficitPct, deficit > 0 {
            let label = "\(Int(deficit.rounded()))% in deficit"
            if let exhaustedIn = forecast.exhaustedIn, exhaustedIn > 0 {
                let at = now.addingTimeInterval(exhaustedIn)
                return label + " · Exhausts in " + countdownText(from: now, to: at)
            }
            return label
        }
        if projected.isFinite, projected > 0, projected < 0.995 {
            let reserve = Int(((1 - projected) * 100).rounded())
            if reserve > 0 { return "\(reserve)% in reserve · Lasts until reset" }
        }
        return "On pace · Lasts until reset"
    }

    // MARK: - Header

    /// "Updated just now" (< 60s — port de `UsageFormatter.updatedString`), 
    /// "Updated 42m ago" / "Updated 3h ago"; ≥ 24h cai para o dia absoluto
    /// ("Updated Sep 8"). Capitalização CONFERIDA contra o upstream MIT
    /// (T6/carry-forward: todos os ramos usam "Updated" com U maiúsculo).
    /// Nunca ciclado (fetchedAt na época zero) → "not updated yet" (honesto,
    /// extensão nossa — o upstream não tem esse caso). Delta negativo (clock
    /// do snapshot no futuro) satura em "just now" — nunca número negativo.
    public static func updatedText(now: Date, fetchedAt: Date) -> String {
        guard fetchedAt.timeIntervalSince1970 > 0 else { return "not updated yet" }
        let delta = max(0, now.timeIntervalSince(fetchedAt))
        if delta < 60 { return "Updated just now" }
        if delta < 3_600 { return "Updated \(Int(delta / 60))m ago" }
        if delta < 86_400 { return "Updated \(Int(delta / 3_600))h ago" }
        let day = fetchedAt.formatted(.dateTime.month(.abbreviated).day())
        return "Updated \(day)"
    }

    /// Badge do header (posição do plan/level da referência — não temos dado
    /// de plano no motor, o badge de fonte ocupa o lugar, sem invenção):
    /// "local" (ingest local), "auth" (API ok), "no auth"/"auth invalid".
    public static func authBadgeText(source: DataSource, authState: AuthState) -> String {
        if source == .localOnly { return "local" }
        switch authState {
        case .ok: return "auth"
        case .missing: return "no auth"
        case .invalid: return "auth invalid"
        }
    }

    // MARK: - Credits (F5 T6 — verdicto da investigação do wham/usage)

    /// Linha "Credits" do painel — verdicto T6 (ver `docs/specs/f5-providers.md`
    /// § Codex): o `wham/usage` TRAZ `credits.balance` (utilizável quando não
    /// nulo; já decodificado no snapshot desde a F2), mas NÃO traz o inventário
    /// "Limit Reset Credits" da referência — esse vive no endpoint dedicado
    /// `/wham/rate-limit-reset-credits` (fora do escopo F5, documentado).
    /// Portanto: saldo real → linha; `unlimited` → "Credits: unlimited";
    /// saldo ausente/nulo → linha omitida (NUNCA "Limit reset credits" — a
    /// semântica da linha da referência é o inventário de grants, não o saldo).
    /// `nil` = nada a mostrar (nada inventado).
    public static func creditsText(_ credits: CreditsInfo?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited { return "Credits: unlimited" }
        guard let remaining = credits.remaining else { return nil }
        return "Credits: " + kpiCostString(remaining)
    }

    // MARK: - Dashboard (KPIs + chart + linhas de detalhe)

    /// Célula do grid de KPIs (port de `KPIBlock`): título pequeno, valor
    /// grande; `emphasis` → headline (o "Today" da referência).
    public struct KPICell: Identifiable, Equatable, Sendable {
        public let title: String
        public let value: String
        public let emphasis: Bool

        public init(title: String, value: String, emphasis: Bool = false) {
            self.title = title
            self.value = value
            self.emphasis = emphasis
        }

        public var id: String { title }
    }

    /// Grid 2×2 da referência: "Today $0.00 · 30d $1,116.52 · Recent tokens
    /// 216M · 30d tokens 8.9B". Custo ausente (NULL ≠ 0) → "—" (a referência
    /// usa "—" na célula; nunca inventa número). `nil` = nada a mostrar
    /// (provider sem histórico carregado → seção some).
    public static func kpiCells(
        todayCostUsd: Double?,
        monthCostUsd: Double?,
        todayTokens: Int64,
        monthTokens: Int64
    ) -> [KPICell]? {
        let hasAnyData = todayCostUsd != nil || monthCostUsd != nil
            || todayTokens > 0 || monthTokens > 0
        guard hasAnyData else { return nil }
        return [
            KPICell(title: "Today", value: kpiCostString(todayCostUsd), emphasis: true),
            KPICell(title: "30d", value: kpiCostString(monthCostUsd)),
            KPICell(title: "Recent tokens", value: tokenCountString(todayTokens)),
            KPICell(title: "30d tokens", value: tokenCountString(monthTokens)),
        ]
    }

    /// O dashboard inteiro aparece só com ALGUM dado de histórico (custo,
    /// tokens ou série) — sem DB, seção omitida (comportamento F3/F4).
    public static func showsDashboard(
        weekHistoryAvailable: Bool, monthHistoryAvailable: Bool,
        todayCostUsd: Double?, monthCostUsd: Double?,
        todayTokens: Int64, monthTokens: Int64, series: [PanelDayPoint]
    ) -> Bool {
        weekHistoryAvailable || monthHistoryAvailable || series.isEmpty == false
            || todayCostUsd != nil || monthCostUsd != nil || todayTokens > 0 || monthTokens > 0
    }

    /// O valor monetário da célula: "$1,116.52" (agrupado, 2 decimais);
    /// sub-centavo real mantém 4 decimais ($0.0050 — não vira $0.00);
    /// `nil` → "—" (NULL ≠ 0).
    static func kpiCostString(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        if cost > 0, cost < 0.01 { return String(format: "$%.4f", cost) }
        return cost.formatted(
            .currency(code: "USD").precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
    }

    /// Contagem compacta no formato da referência: "216M", "8.9B", "3.1K" —
    /// um decimal e ".0" cortado; ≥10 unidades sem decimal. Port de
    /// `UsageFormatter.tokenCountString`.
    public static func tokenCountString(_ value: Int64) -> String {
        let absValue = value.magnitude
        let sign = value < 0 ? "-" : ""
        let units: [(threshold: UInt64, divisor: Double, suffix: String)] = [
            (999_500_000, 1_000_000_000, "B"),
            (999_500, 1_000_000, "M"),
            (1_000, 1_000, "K"),
        ]
        for unit in units where absValue >= unit.threshold {
            let scaled = Double(absValue) / unit.divisor
            let formatted: String
            if scaled >= 10 {
                formatted = String(format: "%.0f", scaled)
            } else {
                var s = String(format: "%.1f", scaled)
                if s.hasSuffix(".0") { s.removeLast(2) }
                formatted = s
            }
            return "\(sign)\(formatted)\(unit.suffix)"
        }
        return String(value)
    }

    /// Modelo do chart diário (port de `MiniUsageBars`): valores diários e o
    /// rótulo de escala ("$282" — o pico, quando os pontos têm custo; senão
    /// tokens abreviados). `nil` = série vazia (chart omitido).
    public struct ChartModel: Equatable, Sendable {
        public let values: [Double]
        /// Rótulo do topo (pico da série) — `nil` quando todos os pontos são
        /// zero (nada a anotar).
        public let peakLabel: String?
    }

    public static func chartModel(series: [PanelDayPoint]) -> ChartModel? {
        guard !series.isEmpty else { return nil }
        let usesCost = series.contains { ($0.costUSD ?? 0) > 0 }
        let values = series.map { point in
            usesCost ? max(0, point.costUSD ?? 0) : max(0, Double(point.tokens))
        }
        guard let peak = values.max(), peak > 0 else {
            return ChartModel(values: values, peakLabel: nil)
        }
        let label = usesCost
            ? compactCurrency(peak)
            : tokenCountString(Int64(peak))
        return ChartModel(values: values, peakLabel: label)
    }

    /// "$282" / "$1,116" (0 decimais); abaixo de $1 mantém centavos — port
    /// de `UsageFormatter.compactCurrencyString` (USD).
    static func compactCurrency(_ value: Double) -> String {
        if value != 0, abs(value) < 1 {
            return String(format: "$%.2f", value)
        }
        return value.formatted(
            .currency(code: "USD").precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
    }

    /// Linhas de detalhe sob o chart (port das `detailLines`): "Last 7 days:
    /// $585.43 · 3.1B tokens", "Top model: gpt-5.6", e o disclaimer de
    /// estimativa quando há custo/projeção na tela. Segmento sem dado some
    /// (NULL ≠ 0); linha sem segmentos não nasce.
    /// Linha do orçamento do mês (F7 Spend control) — `nil` sem teto
    /// configurado. Com teto e sem custo computável no mês: "— of $X" (NULL ≠ 0:
    /// nunca "$0.00 de $X", que diria que o mês não gastou nada). Com custo:
    /// "$A of $B · N% · projected $C" (a projeção some quando não há base).
    /// Texto da fração do orçamento ("42%"). Guarda a finitude e o teto do
    /// ratio ANTES da conversão para Int (review F7, Minor 3): o caminho de
    /// alerta já guarda `isFinite`; a UI precisa da mesma proteção (NaN/inf
    /// não podem virar trap num Text). `nil` = sem base válida.
    public static func budgetPercentText(_ spent: Double, of budget: Double) -> String? {
        guard spent.isFinite, budget.isFinite, budget > 0 else { return nil }
        let percent = min(max(spent / budget, 0), 1_000) * 100
        return String(Int(percent.rounded())) + "%"
    }

    public static func budgetLine(
        budgetUsd: Double?,
        monthToDateUsd: Double?,
        monthProjectedUsd: Double?
    ) -> String? {
        guard let budgetUsd, budgetUsd > 0 else { return nil }
        var parts: [String] = []
        if let monthToDateUsd {
            parts.append(kpiCostString(monthToDateUsd) + " of " + kpiCostString(budgetUsd))
            if let percent = budgetPercentText(monthToDateUsd, of: budgetUsd) {
                parts.append(percent)
            }
        } else {
            parts.append("— of " + kpiCostString(budgetUsd))
        }
        if let monthProjectedUsd {
            parts.append("projected " + kpiCostString(monthProjectedUsd))
        }
        return "Budget: " + parts.joined(separator: " · ")
    }

    public static func detailLines(
        weekCostUsd: Double?,
        weekTokens: Int64,
        topModel: String?,
        showsEstimate: Bool,
        budgetUsd: Double? = nil,
        monthToDateUsd: Double? = nil,
        monthProjectedUsd: Double? = nil
    ) -> [String] {
        var lines: [String] = []
        var weekParts: [String] = []
        if let weekCost = weekCostUsd { weekParts.append(kpiCostString(weekCost)) }
        if weekTokens > 0 { weekParts.append(tokenCountString(weekTokens) + " tokens") }
        if !weekParts.isEmpty { lines.append("Last 7 days: " + weekParts.joined(separator: " · ")) }
        if let topModel, !topModel.isEmpty {
            lines.append("Top model: " + shortModelName(topModel))
        }
        if let budget = budgetLine(
            budgetUsd: budgetUsd, monthToDateUsd: monthToDateUsd,
            monthProjectedUsd: monthProjectedUsd)
        {
            lines.append(budget)
        }
        if showsEstimate {
            lines.append("Estimated from token usage · not a subscription bill")
        }
        return lines
    }

    /// Nomes longos truncam em 26 caracteres ("…" final) — port de
    /// `shortModelName` da referência.
    public static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    /// Disclaimer da referência para custos estimados (hint do Codex).
    public static let estimateDisclaimer = "Estimated from token usage · not a subscription bill"

    // MARK: - Multi-conta (união registry ⊕ ciclo)

    /// Linhas da seção de contas: UNIÃO do ciclo com o registry (fix do review
    /// final F4). O ciclo só itera contas ATIVAS — montar a seção só com
    /// `display.accounts` fazia a linha de uma conta desativada SUMIR (o
    /// toggle de reativação e o "Remove account" desapareciam juntos, e o
    /// re-add era bloqueado pelo guard de overlap: conta presa no banco).
    /// Contrato do README/`AccountRegistry.setActive` ("o registro permanece
    /// para reativação"): toda linha ciclada segue como veio; conta registrada
    /// fora do ciclo entra com o estado do REGISTRO (`active == false` → badge
    /// "inactive") e display vazio (nada inventado). Ordem: cicladas primeiro
    /// (comportamento anterior preservado bit-a-bit), depois as só-registro na
    /// ordem do registry (label).
    public static func accountRows(
        cycled: [AccountDisplay], registered: [RegisteredAccount]
    ) -> [AccountDisplay] {
        var rows = cycled
        let cycledKeys = Set(cycled.map(\.key))
        for account in registered where !cycledKeys.contains(account.accountKey) {
            rows.append(AccountDisplay(
                key: account.accountKey,
                label: account.label,
                active: account.active,
                invalidCredential: false,
                display: .empty))
        }
        return rows
    }

    /// A seção de contas aparece quando há MAIS DE UMA linha (decisão
    /// F4-MULTIACCOUNT: conta única ativa é ruído — as janelas já estão no
    /// topo) OU quando existe QUALQUER conta registrada — uma única conta
    /// INATIVA precisa continuar alcançável para reativação/remoção.
    public static func showsAccountsSection(
        rows: [AccountDisplay], registeredCount: Int
    ) -> Bool {
        rows.count > 1 || registeredCount > 0
    }

    // MARK: - Estado honesto de alertas (F5 T2)

    /// Texto da linha de estado de notificações no rodapé do painel. `nil`
    /// quando nada a dizer (alerts ligados E autorizados — silêncio honesto).
    /// Off/sem permissão aparecem SEMPRE (spec §8: estado honesto na UI).
    public static func alertsStatusText(_ status: AlertsPanelStatus) -> String? {
        switch status {
        case .enabled:
            return nil
        case .disabled:
            return "Notifications off — enable in Settings"
        case .notConfigured:
            return "Notifications pending permission — allow in Settings"
        case .blocked:
            return "Notifications blocked — allow in System Settings"
        }
    }
}
