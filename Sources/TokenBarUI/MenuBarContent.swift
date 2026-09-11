import Foundation
import TokenBarCore

public func abbrevTokens(_ n: Int64) -> String {
    switch n {
    case ..<1_000:
        return String(n)
    case ..<1_000_000:
        return String(format: "%.1fk", Double(n) / 1_000)
    case ..<1_000_000_000:
        return String(format: "%.1fM", Double(n) / 1_000_000)
    default:
        return String(format: "%.1fG", Double(n) / 1_000_000_000)
    }
}

/// Janela mais crítica de um snapshot: a de `usedFraction` mais próximo de 1
/// (regra D5 do menu — ex.: Codex com 5h em 62% e semanal em 40% mostra 62%).
/// Empate: a primeira vista (ordem do array do provider) vence. `nil` quando
/// nenhuma janela tem fração conhecida (modo local — spec §5 regra 2).
public func criticalWindow(in windows: [UsageWindow]) -> UsageWindow? {
    var best: UsageWindow?
    var bestFraction = -1.0
    for window in windows {
        guard let fraction = window.usedFraction, fraction > bestFraction else { continue }
        best = window
        bestFraction = fraction
    }
    return best
}

/// Formato do custo estimado no painel: "~$12.34". Abaixo de 1 centavo usa 4
/// decimais para não virar "~$0.00" (que esconderia gasto real pequeno); o
/// "~" marca estimativa — conversão de moeda e precisão de centavos são fora
/// de escopo (Global Constraints F3).
public func formatEstimatedUSD(_ cost: Double) -> String {
    if cost > 0, cost < 0.01 {
        return String(format: "~$%.4f", cost)
    }
    return String(format: "~$%.2f", cost)
}

/// Linha de UMA conta no painel (F4 multi-conta): identidade + estado do
/// ciclo da conta. `invalidCredential` = path registrado inexistente (badge
/// de erro na linha — a conta degrada sozinha, sem derrubar o provider).
/// `display` carrega as janelas/auth/da CONTA (mesmo tipo do agregado).
public struct AccountDisplay: Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let active: Bool
    public let invalidCredential: Bool
    public let display: ProviderDisplay

    /// Key da conta é única por provider (PK provider+account_id do schema §6).
    public var id: String { key }

    public init(
        key: String, label: String, active: Bool,
        invalidCredential: Bool, display: ProviderDisplay
    ) {
        self.key = key
        self.label = label
        self.active = active
        self.invalidCredential = invalidCredential
        self.display = display
    }
}

/// Estado de exibição de UM provider — o que a UI/heartbeat consome por ciclo.
/// `percent` em escala 0...100 (`nil` = sem janela com fração conhecida);
/// `resetsAt` da janela crítica (linha "reseta em" do menu); `source` alimenta
/// o badge "(local)". Estende o mínimo do brief ({percent, todayTokens,
/// authState, fetchedAt}) com o que a spec do menu exige.
public struct ProviderDisplay: Equatable, Sendable {
    public var percent: Double?
    public var todayTokens: Int64
    /// Custo estimado do dia (soma de `cost_usd` dos eventos de hoje, do DB).
    /// `nil` = sem custo computável (sem DB, sem evento precificado hoje) — o
    /// painel mantém só tokens. NUNCA aparece na string do menu bar (o render
    /// gate da F1 preserva "C:12.4k X:0% Z:17%"); custo é só painel/heartbeat.
    public var todayCostUsd: Double?
    /// Tokens dos últimos 7 dias (daily_agg, janela de 7 dias calendário) —
    /// F3 Task 3, linha "7d: X tok ~$Y" do painel. 0 = sem histórico na
    /// janela (segmento omitido). Atualizado 1× por ciclo, fora da MainActor.
    public var weekTokens: Int64
    /// Custo estimado dos 7 dias (`nil` = sem custo computável — NULL ≠ 0).
    public var weekCostUsd: Double?
    /// A leitura do histórico 7d foi bem-sucedida no ciclo (F3 Task 4, campo
    /// `history7d` do heartbeat v3): `true` só quando a query do banco rodou;
    /// `false` = sem DB, query falhou ou nunca rodou — o heartbeat OMITE o
    /// campo (nada fake), enquanto o painel mantém o último valor bom.
    public var weekHistoryAvailable: Bool
    public var authState: AuthState
    public var source: DataSource
    public var resetsAt: Date?
    public var fetchedAt: Date
    // MARK: Campos aditivos F4 (painel rico) — TODOS com default; a string do
    // menu bar NÃO muda com nenhum deles (render gate da F1 intocado).
    /// Todas as janelas do último snapshot (barras do painel; o menu bar
    /// continua mostrando só a crítica via `percent`/`resetsAt`).
    public var windows: [UsageWindow]
    /// Tokens dos últimos 30 dias (daily_agg) — totais do painel + heartbeat.
    public var monthTokens: Int64
    /// Custo estimado dos 30 dias (`nil` = sem custo computável — NULL ≠ 0).
    public var monthCostUsd: Double?
    /// A leitura 30d do ciclo foi bem-sucedida (`false` → heartbeat OMITE o
    /// campo; painel mantém o último valor bom — mesmo padrão do 7d).
    public var monthHistoryAvailable: Bool
    /// Forecast de pacing contra a janela crítica (`nil` = sem chute — <2
    /// pontos, janela sem reset/fração; linha de pacing some do painel).
    public var pacing: PacingForecast?
    /// Série diária 30d do provider (chart do painel; ≤30 pontos, daily_agg).
    public var monthSeries: [PanelDayPoint]
    /// Multi-conta (F4): linhas por conta ciclada. Vazio = conta única — o
    /// comportamento F2/F3 fica bit-a-bit igual (nenhum campo do menu bar ou
    /// do heartbeat v3 depende disto; é só painel).
    public var accounts: [AccountDisplay]
    /// Modelo com mais tokens nos últimos 7 dias (daily_agg/daily_model_agg,
    /// janela 7d, provider-wide — F5, linha "Top model:" do painel; port da
    /// referência). `nil` = sem histórico com modelo na janela (linha
    /// omitida — nada inventado). Painel-only: a string do menu bar NÃO muda
    /// (render gate da F1 intocado).
    public var topModel7d: String?
    /// Créditos do último snapshot (F5 T6: saldo de API do Codex/OpenRouter/
    /// DeepSeek; linha "Credits" do painel). `nil` = provider sem crédito no
    /// ciclo (linha omitida). Painel/heartbeat-only: menu bar intocado.
    public var credits: CreditsInfo?

    public init(
        percent: Double? = nil,
        todayTokens: Int64 = 0,
        todayCostUsd: Double? = nil,
        weekTokens: Int64 = 0,
        weekCostUsd: Double? = nil,
        weekHistoryAvailable: Bool = false,
        authState: AuthState = .missing,
        source: DataSource = .localOnly,
        resetsAt: Date? = nil,
        fetchedAt: Date = Date(timeIntervalSince1970: 0),
        windows: [UsageWindow] = [],
        monthTokens: Int64 = 0,
        monthCostUsd: Double? = nil,
        monthHistoryAvailable: Bool = false,
        pacing: PacingForecast? = nil,
        monthSeries: [PanelDayPoint] = [],
        accounts: [AccountDisplay] = [],
        topModel7d: String? = nil,
        credits: CreditsInfo? = nil
    ) {
        self.percent = percent
        self.todayTokens = todayTokens
        self.todayCostUsd = todayCostUsd
        self.weekTokens = weekTokens
        self.weekCostUsd = weekCostUsd
        self.weekHistoryAvailable = weekHistoryAvailable
        self.authState = authState
        self.source = source
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.monthTokens = monthTokens
        self.monthCostUsd = monthCostUsd
        self.monthHistoryAvailable = monthHistoryAvailable
        self.pacing = pacing
        self.monthSeries = monthSeries
        self.accounts = accounts
        self.topModel7d = topModel7d
        self.credits = credits
    }

    /// Estado inicial (nada ciclo ainda): sem dado — some da string do menu.
    public static let empty = ProviderDisplay()

    /// Tem algo a mostrar: fração de janela ou tokens do dia.
    public var hasData: Bool { percent != nil || todayTokens > 0 }

    /// Fragmento do menu bar ("C:12.4k" | "X:62%"); `nil` = sem dados, some.
    public var menuBarFragment: String? {
        if let percent {
            let clamped = min(max(percent, 0), 100)
            return "\(Int(clamped.rounded()))%"
        }
        guard todayTokens > 0 else { return nil }
        return abbrevTokens(todayTokens)
    }
}

/// Conteúdo consolidado do menu bar — estado POR provider (F2). A string de
/// exibição segue a tabela de siglas D5, ordem fixa C, X, G, Z; provider sem
/// dado (sem % e sem tokens) some da string.
///
/// F5 Task 3: `visibleProviders` filtra QUAIS providers aparecem no texto
/// (janela de Settings → checkboxes; persistência na tabela `settings`, lida
/// pelo coordinator). Default = todos — comportamento idêntico ao de quem
/// nunca abriu settings. O gate da F1 segue valendo: visibilidade que não
/// muda a string exibida (provider escondido sem dados) não re-renderiza.
public struct MenuBarContent: Equatable, Sendable {
    /// Tabela de siglas D5 — codex é "X" (não colide com claude). F5 (ruling
    /// F5-SIGLAS): cursor=U, openrouter=O, qwen/alibaba=Q, antigravity=V,
    /// deepseek=D, grok=K (G conflita com gemini; A conflita com a ordem
    /// alfabética dos demais — tabela estendida em docs/decisoes-f5).
    public static let siglas: [ProviderID: String] = [
        .claude: "C", .codex: "X", .gemini: "G", .zai: "Z",
        .cursor: "U", .openrouter: "O", .alibaba: "Q",
        .antigravity: "V", .deepseek: "D", .grok: "K",
    ]

    /// Ordem fixa de exibição; ids fora da tabela (cursor/openrouter/copilot)
    /// entram depois, em ordem alfabética de rawValue.
    public static let displayOrder: [ProviderID] = [.claude, .codex, .gemini, .zai]

    /// Nome completo p/ as linhas do painel (menu, não menu bar).
    public static let displayNames: [ProviderID: String] = [
        .claude: "Claude", .codex: "Codex", .gemini: "Gemini", .zai: "Z.ai",
        .cursor: "Cursor", .openrouter: "OpenRouter", .alibaba: "Qwen",
        .antigravity: "Antigravity", .deepseek: "DeepSeek", .grok: "Grok",
    ]

    public let providers: [ProviderID: ProviderDisplay]
    /// Providers presentes no texto do menu bar/linhas (Task 3). Vazio é
    /// escolha válida → displayString fica "TB".
    public let visibleProviders: Set<ProviderID>

    public static let empty = MenuBarContent(providers: [:])

    public init(
        providers: [ProviderID: ProviderDisplay],
        visibleProviders: Set<ProviderID> = Set(ProviderID.allCases)
    ) {
        self.providers = providers
        self.visibleProviders = visibleProviders
    }

    /// Conveniência de migração (F1/totais crus): só tokens, sem janela.
    public init(todayTokens: [ProviderID: Int64]) {
        self.init(providers: todayTokens.mapValues { ProviderDisplay(todayTokens: $0) })
    }

    public static func sigla(for id: ProviderID) -> String {
        siglas[id] ?? String(id.rawValue.prefix(1)).uppercased()
    }

    public static func displayName(for id: ProviderID) -> String {
        displayNames[id] ?? id.rawValue.capitalized
    }

    /// Pares (id, display) com dado, na ordem fixa de exibição (C, X, G, Z;
    /// demais ids atrás, alfabético). Respeita `visibleProviders` (Task 3):
    /// provider fora do conjunto NÃO entra no texto do menu bar nem nas
    /// linhas — some por escolha do usuário, não por falta de dado.
    public func orderedProviders() -> [(id: ProviderID, display: ProviderDisplay)] {
        var order: [ProviderID: Int] = [:]
        let allIDs: [ProviderID] = Self.displayOrder + ProviderID.allCases.sorted { $0.rawValue < $1.rawValue }
        for (index, id) in allIDs.enumerated() {
            if order[id] == nil { order[id] = index }  // primeira ocorrência vence
        }
        let active = providers.compactMap { (id: $0.key, display: $0.value) }
            .filter { $0.display.hasData && visibleProviders.contains($0.id) }
        let sorted = active.sorted { lhs, rhs in
            let lhsIndex = order[lhs.id] ?? Int.max
            let rhsIndex = order[rhs.id] ?? Int.max
            return lhsIndex < rhsIndex
        }
        return sorted
    }

    /// Fragmento do provider na string ("C:12.4k"); `nil` = sem dados.
    public func displayFragment(for id: ProviderID) -> String? {
        guard let display = providers[id], display.hasData else { return nil }
        return Self.sigla(for: id) + ":" + (display.menuBarFragment ?? "")
    }

    /// String do ícone: "C:12.4k X:62% Z:81% G:3.1k"; "TB" quando vazio.
    public func displayString() -> String {
        let fragments = orderedProviders().compactMap { displayFragment(for: $0.id) }
        guard !fragments.isEmpty else { return "TB" }
        return fragments.joined(separator: " ")
    }

    /// Linhas do painel (menu aberto): "X Codex: 62% — reseta em 2h",
    /// "C Claude: 12.4k hoje ~$0.08 (local)". Provider sem dado não ganha
    /// linha; provider sem custo computável mantém só tokens (F3 Task 2).
    public func menuLines(now: Date = Date()) -> [String] {
        orderedProviders().map { id, display in
            var line = "\(Self.sigla(for: id)) \(Self.displayName(for: id)): "
            if let percent = display.percent {
                let clamped = min(max(percent, 0), 100)
                line += "\(Int(clamped.rounded()))%"
            } else {
                line += abbrevTokens(display.todayTokens) + " hoje"
            }
            // Custo do dia vem logo após a métrica principal ("C:12.4k ~$0.08").
            if let cost = display.todayCostUsd {
                line += " " + formatEstimatedUSD(cost)
            }
            // Histórico 7d (F3 Task 3): após as métricas de hoje, antes do
            // sufixo de reset — "· 7d: 45.6k ~$0.31". Sem tokens na janela →
            // segmento omitido (nada inventado); custo só quando computável.
            if display.weekTokens > 0 {
                line += " · 7d: " + abbrevTokens(display.weekTokens)
                if let weekCost = display.weekCostUsd {
                    line += " " + formatEstimatedUSD(weekCost)
                }
            }
            if let resetsAt = display.resetsAt, let suffix = Self.resetSuffix(from: now, to: resetsAt) {
                line += " — \(suffix)"
            }
            if display.source == .localOnly {
                line += " (local)"
            }
            return line
        }
    }

    /// "reseta em 42min / 3h / 5d"; janela já vencida → sem sufixo (nada a
    /// prometer — o próximo ciclo atualiza a janela).
    static func resetSuffix(from now: Date, to resetsAt: Date) -> String? {
        let delta = resetsAt.timeIntervalSince(now)
        guard delta > 0 else { return nil }
        if delta < 3_600 {
            return "reseta em \(max(1, Int(delta / 60)))min"
        }
        if delta < 172_800 {
            return "reseta em \(max(1, Int(delta / 3_600)))h"
        }
        return "reseta em \(max(1, Int(delta / 86_400)))d"
    }
}
