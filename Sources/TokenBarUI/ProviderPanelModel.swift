import Foundation
import TokenBarCore

/// Ponto diário da série 30d de um provider (chart do painel rico, F4) —
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

/// View-model do painel rico (F4 Task 2) — TODA a lógica de estado/texto,
/// sem SwiftUI: seleção de aba, linha de janela (`WindowBarRow`), countdown
/// relativo, pacing condicional, custos hoje/30d, badge de auth e "updated
/// Xs ago". Funções puras com `now`/dados injetados — testável headless; a
/// renderização (`ProviderPanelView`) só desenha.
///
/// Strings em EN (Global Constraints — UI strings EN).
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
    }

    /// Uma linha por janela do snapshot, na ordem do provider.
    public static func windowRows(windows: [UsageWindow], now: Date) -> [WindowRow] {
        windows.enumerated().map { index, window in
            let fraction = window.usedFraction.map { min(max($0, 0), 1) }
            let usageText: String
            if let fraction {
                usageText = "\(kindTitle(window.kind)) \(Int((fraction * 100).rounded()))% used"
            } else {
                usageText = "\(kindTitle(window.kind)) window"
            }
            let countdown = window.resetsAt.map { renewText(from: now, to: $0) }
            return WindowRow(
                id: "\(window.kind.rawValue)#\(index)",
                kind: window.kind,
                fraction: fraction,
                usageText: usageText,
                countdownText: countdown)
        }
    }

    /// Título estável da janela pelo `kind` (não pelo label do provider — o
    /// label varia por API: "Hoje", "Semanal", "5h"; o kind é canônico).
    static func kindTitle(_ kind: WindowKind) -> String {
        switch kind {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .daily: return "Daily"
        }
    }

    // MARK: - Pacing

    /// Disclaimer curto da linha de pacing (padrão do referencial: honesto).
    public static let pacingDisclaimer = "estimate — not a guarantee"

    /// Texto do pacing quando existe forecast: "Estimated — exhausts in 2h
    /// 44m"; forecast sem esgotamento (taxa flat/queda) → "Estimated —
    /// should last until renew". `nil` = sem forecast (menos de 2 pontos de
    /// dados, janela sem reset/fração) → linha NÃO aparece (sem chute).
    public static func pacingText(_ forecast: PacingForecast?, now: Date) -> String? {
        guard let forecast else { return nil }
        if let exhaustedIn = forecast.exhaustedIn, exhaustedIn > 0 {
            let at = now.addingTimeInterval(exhaustedIn)
            return "Estimated — exhausts in " + countdownText(from: now, to: at)
        }
        return "Estimated — should last until renew"
    }

    // MARK: - Custos

    /// "Today ~$0.08 · 30d ~$2.10 · 8.9G tok" — segmentos omitidos quando
    /// sem dado (custo `nil` = sem preço computável — NULL ≠ 0; tokens 0 =
    /// sem histórico na janela). Tudo sem dado → `nil` (linha some).
    public static func costsText(
        todayCostUsd: Double?, monthCostUsd: Double?, monthTokens: Int64
    ) -> String? {
        var segments: [String] = []
        if let today = todayCostUsd { segments.append("Today " + formatEstimatedUSD(today)) }
        if let month = monthCostUsd { segments.append("30d " + formatEstimatedUSD(month)) }
        if monthTokens > 0 { segments.append(abbrevTokens(monthTokens) + " tok") }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: " · ")
    }

    // MARK: - Header

    /// "updated 42s ago" / "updated 5m ago" / "updated 3h ago". Nunca ciclado
    /// (fetchedAt na época zero) → "not updated yet" (honesto, nada fake).
    public static func updatedText(now: Date, fetchedAt: Date) -> String {
        guard fetchedAt.timeIntervalSince1970 > 0 else { return "not updated yet" }
        let delta = max(0, now.timeIntervalSince(fetchedAt))
        if delta < 60 { return "updated \(max(1, Int(delta)))s ago" }
        if delta < 3_600 { return "updated \(Int(delta / 60))m ago" }
        return "updated \(Int(delta / 3_600))h ago"
    }

    /// Badge do header: "local" (ingest local — fonte do dado é o arquivo
    /// local), "auth" (API com credencial ok), "no auth"/"auth invalid" para
    /// os estados ruins da API.
    public static func authBadgeText(source: DataSource, authState: AuthState) -> String {
        if source == .localOnly { return "local" }
        switch authState {
        case .ok: return "auth"
        case .missing: return "no auth"
        case .invalid: return "auth invalid"
        }
    }
}
