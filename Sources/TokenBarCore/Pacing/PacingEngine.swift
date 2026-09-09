import Foundation

/// Previsão de esgotamento da janela de um provider (F4 Task 1).
///
/// SEMÂNTICA (contrato do painel rico):
/// - `usedFraction` da janela é o USO ACUMULADO (ex. 0.74 = "74% usado").
/// - `projectedFraction` = uso acumulado + USO ADICIONAL projetado até
///   `resetsAt`, convertido para fração pela relação tokens↔fração derivada
///   dos agregados diários (ver `PacingEngine.forecast`).
/// - `exhaustedIn`: segundos (`TimeInterval`) até a fração projetada atingir
///   1.0 (interpolado na reta de regressão) — só quando a projeção passa de
///   1.0; `nil` caso contrário (inclui "não há projeção").
/// - `deficitPct`: o quanto a projeção estoura o limite, em % —
///   `max(0, (projected − 1) × 100)`; `nil` quando não estoura.
public struct PacingForecast: Sendable, Equatable {
    public let exhaustedIn: TimeInterval?
    public let projectedFraction: Double
    public let deficitPct: Double?

    public init(exhaustedIn: TimeInterval?, projectedFraction: Double, deficitPct: Double?) {
        self.exhaustedIn = exhaustedIn
        self.projectedFraction = projectedFraction
        self.deficitPct = deficitPct
    }
}

/// Pacing honesto: regressão linear (mínimos quadrados) sobre os somatórios
/// diários de `daily_agg` → taxa de tokens/dia → projeção de uso no restante
/// da janela → `PacingForecast`.
///
/// REGRAS DE HONESTIDADE (spec F4 — "nada vai pra tela sem base real"):
/// - < 2 pontos diários → `nil` (sem chute; 1 dia não define tendência).
/// - `window.resetsAt == nil` → `nil` (sem horizonte não há projeção).
/// - `window.usedFraction == nil` → `nil` (sem a âncora de fração,
///   `projectedFraction` — tipo não-opcional — é indeterminável).
/// - Taxa ≤ 0 (uso flat/decrescente) → `projectedFraction = usedFraction` e
///   `exhaustedIn = nil` (tendência de queda não projeta esgotamento).
/// - Relação tokens↔fração não derivável (0 tokens da janela nos agregados,
///   `usedFraction == 0`, janela `.session` sem span conhecido) →
///   `projectedFraction = usedFraction`, `exhaustedIn = nil`.
/// - Valores absurdos (não-finitos, overflow — padrão Red Team F2):
///   `isFinite` + saturação/clamps; fração projetada satura em 1e6
///   (deficitPct proporcional, sempre finito); totais negativos são dados
///   corrompidos e DESCARTADOS (nunca entram como uso negativo).
///
/// DECISÃO DOCUMENTADA — GAP DE DIAS: só dias COM dados entram na regressão;
/// dia sem dado NÃO é zero-fill (seria inventar "não usei"). O eixo x usa a
/// DATA real de cada ponto (dias decorridos desde o primeiro ponto), então um
/// gap aumenta o intervalo de tempo entre vizinhos sem criar uso falso.
///
/// DECISÃO DOCUMENTADA — RELAÇÃO TOKENS↔FRAÇÃO: `usedFraction` / tokens já
/// usados na janela definem a capacidade (tokens ≙ fração 1.0). Os tokens da
/// janela atual são APROXIMADOS pela soma dos dias com dados dentro do início
/// da janela (`resetsAt − span`, span 7d p/ `.weekly`, 1d p/ `.daily` —
/// agregado diário não resolve a hora exata do início; janela `.session`
/// (horas) é granular demais p/ agregados diários → sem projeção).
///
/// Clock e calendar injetados — determinístico em teste (Swift Testing).
public struct PacingEngine {
    /// Limite de saturação da fração projetada (adversarial: mantém
    /// `deficitPct` finito e ordenável sem nunca trapar).
    static let maxProjectedFraction: Double = 1_000_000
    /// Janela da regressão: últimos 14 dias COM dados (peso igual entre
    /// pontos — o ajuste é simples, não ponderado).
    static let regressionWindowDays = 14

    private init() {}

    /// Ajusta a reta e projeta o esgotamento. Ver contrato na doc do tipo.
    public static func forecast(
        dailySums: [(day: Date, total: Int64)],
        window: UsageWindow,
        now: Date,
        calendar: Calendar
    ) -> PacingForecast? {
        // Honestidade 1: sem reset conhecido não há horizonte → nil.
        guard let resetsAt = window.resetsAt else { return nil }
        // Honestidade 2: sem fração conhecida não há âncora → nil.
        guard let rawFraction = window.usedFraction, rawFraction.isFinite else { return nil }
        // Adversarial: fração fora de 0...1 satura nos limites (não crasha).
        let usedFraction = min(max(rawFraction, 0), 1)

        // Adversarial: totais negativos são dados corrompidos → descartados.
        // Ordenação por dia + últimos 14 pontos com dados.
        let points = dailySums
            .filter { $0.total >= 0 }
            .sorted { $0.day < $1.day }
            .suffix(regressionWindowDays)
        // Honestidade 3: < 2 pontos não definem tendência → nil.
        guard points.count >= 2 else { return nil }

        // x em dias desde o primeiro ponto (normaliza datas gigantes — Red
        // Team F2 — e mantém o ajuste numericamente estável).
        let x0 = points.first!.day.timeIntervalSinceReferenceDate
        let xs = points.map { ($0.day.timeIntervalSinceReferenceDate - x0) / 86_400 }
        let ys = points.map { Double($0.total) }
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) {
            let dx = x - meanX
            sxy += dx * (y - meanY)
            sxx += dx * dx
        }
        // Todos os pontos no mesmo dia: sem variação temporal não há taxa
        // derivável → nil (sem chute).
        guard sxx > 0, sxx.isFinite, sxy.isFinite else { return nil }
        let tokensPerDay = sxy / sxx
        guard tokensPerDay.isFinite else { return nil }

        // Projeção só faz sentido com taxa positiva; flat/queda → sem
        // esgotamento projetado (honestidade 4).
        guard tokensPerDay > 0 else {
            return PacingForecast(exhaustedIn: nil, projectedFraction: usedFraction, deficitPct: nil)
        }

        // Tempo restante da janela; reset no passado → horizonte zero (nada
        // mais se acumula antes do reset) → projeção = uso atual.
        let remainingDays = max(0, resetsAt.timeIntervalSince(now)) / 86_400
        guard remainingDays > 0 else {
            return PacingForecast(exhaustedIn: nil, projectedFraction: usedFraction, deficitPct: nil)
        }

        // Relação tokens↔fração da janela atual (capacidade: tokens ≙ fração
        // 1.0). Inderivável → projeção = uso atual, sem esgotamento (honestidade 5).
        guard
            let windowStart = windowStartDate(window: window, resetsAt: resetsAt, calendar: calendar),
            usedFraction > 0
        else {
            return PacingForecast(exhaustedIn: nil, projectedFraction: usedFraction, deficitPct: nil)
        }
        let windowTokens = points
            .filter { $0.day >= windowStart }
            .reduce(Int64(0)) { TokenSums.saturatingSum($0, $1.total) }
        guard windowTokens > 0 else {
            return PacingForecast(exhaustedIn: nil, projectedFraction: usedFraction, deficitPct: nil)
        }
        let capacityTokens = Double(windowTokens) / usedFraction
        guard capacityTokens.isFinite, capacityTokens > 0 else {
            return PacingForecast(exhaustedIn: nil, projectedFraction: usedFraction, deficitPct: nil)
        }

        // Uso adicional projetado até o reset, em tokens → fração.
        let additionalTokens = tokensPerDay * remainingDays
        guard additionalTokens.isFinite else {
            return PacingForecast(exhaustedIn: nil, projectedFraction: usedFraction, deficitPct: nil)
        }
        let projected = min(
            usedFraction + additionalTokens / capacityTokens, maxProjectedFraction)
        let deficitPct: Double? = projected > 1 ? (projected - 1) * 100 : nil

        // Interpolação: dias até a fração atingir 1.0 na reta (capacidade −
        // tokens já usados, ÷ taxa). A reta só cruza 1.0 ANTES do reset quando
        // a projeção estoura — clamp de segurança contra ruído de ponto
        // flutuante no limite (nunca "esgota depois do reset").
        var exhaustedIn: TimeInterval?
        if projected > 1 {
            let daysToOne = (capacityTokens - Double(windowTokens)) / tokensPerDay
            if daysToOne.isFinite {
                exhaustedIn = min(daysToOne, remainingDays) * 86_400
            }
        }
        return PacingForecast(
            exhaustedIn: exhaustedIn, projectedFraction: projected, deficitPct: deficitPct)
    }

    /// Início da janela atual (`resetsAt − span` no calendar injetado,
    /// DST-safe). `.session` não tem span derivável de agregados diários.
    static func windowStartDate(window: UsageWindow, resetsAt: Date, calendar: Calendar) -> Date? {
        let spanDays: Int
        switch window.kind {
        case .weekly: spanDays = 7
        case .daily: spanDays = 1
        case .session: return nil
        }
        return calendar.date(byAdding: .day, value: -spanDays, to: resetsAt)
    }
}
