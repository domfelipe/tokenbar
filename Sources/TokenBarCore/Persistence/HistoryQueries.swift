import Foundation
import GRDB

/// Leitores de histórico para a UI (F3 Task 3): painel "7d", Analytics
/// (Swift Charts) e export. SOMENTE LEITURA — a escrita continua exclusiva
/// do caminho de ingest (`UsageEventPersisting`).
///
/// CONTRATO DE CUSTO (review T2): `daily_agg.cost_usd` é NULL quando NENHUM
/// evento do grupo tinha preço computável (modelo ausente da tabela — "nunca
/// chute") e 0.0 só quando de fato custou zero. Toda leitura aqui preserva a
/// distinção: `costUSD: Double?` com `nil` = sem custo computável — NUNCA
/// normalizado para 0 (o `dailyAggRows` legado do T1 normaliza; os caminhos
/// novos de custo passam por AQUI).
///
/// Statements: o GRDB mantém cache de prepared statements por conexão — cada
/// chamada reusa a statement compilada (`cachedStatement` explícito no hot
/// loop da ingest; aqui basta o cache automático, são queries 1×/ciclo ou
/// sob demanda da janela de analytics).
///
/// Threading: métodos síncronos NÃO-isolados (o chamador os roda fora da
/// MainActor — `Task.detached` no coordinator/model — e recebe via `await`).
/// O render gate da F1 continua sem tocar no banco.
extension AppDatabase {
    /// Um ponto da série diária: tokens totais do dia para um provider e o
    /// custo computável — `nil` quando todo o custo do grupo é NULL.
    public struct DailySeriesRow: Sendable, Equatable {
        public var day: String
        public var provider: String
        public var tokens: Int64
        public var costUSD: Double?

        public init(day: String, provider: String, tokens: Int64, costUSD: Double?) {
            self.day = day
            self.provider = provider
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    /// Totais de um provider na janela.
    public struct ProviderTotalRow: Sendable, Equatable {
        public var provider: String
        public var tokens: Int64
        public var costUSD: Double?

        public init(provider: String, tokens: Int64, costUSD: Double?) {
            self.provider = provider
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    /// Fatia do breakdown por modelo (ordenada por tokens desc no SQL).
    /// NOTA: o breakdown sai de `daily_agg` (dia×provider×conta×modelo) —
    /// não tem contagem de eventos crus (a contagem aqui seria de GRUPOS,
    /// não de eventos, o que enganaria; quem quiser eventos usa o export).
    public struct ModelBreakdownRow: Sendable, Equatable {
        public var model: String
        public var tokens: Int64
        public var costUSD: Double?

        public init(model: String, tokens: Int64, costUSD: Double?) {
            self.model = model
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    /// Total 7d de UM provider — fonte da linha "7d: X tok ~$Y" do painel.
    public struct WeekTotal: Sendable, Equatable {
        public var tokens: Int64
        public var costUSD: Double?

        public init(tokens: Int64, costUSD: Double?) {
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    /// Primeiro dia (INCLUSIVE) da janela de `days` dias terminando hoje —
    /// "yyyy-MM-dd" no calendar injetado do banco (o mesmo do rollover do
    /// ledger e do `daily_agg.day`, então painel e gráficos concordam).
    /// `days <= 1` → só hoje.
    func windowStartDay(days: Int, now: Date) -> String {
        dayString(from: windowStartDate(days: days, now: now))
    }

    /// Instante de início da janela (00:00 local do primeiro dia, DST-safe
    /// via `Calendar.date(byAdding:)` — nunca soma fixa de segundos).
    func windowStartDate(days: Int, now: Date) -> Date {
        let today = calendar.startOfDay(for: now)
        guard days > 1,
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)
        else { return today }
        return start
    }

    /// Um dia da janela com o início do dia correspondente. O heatmap diário
    /// (Usage & Spend) desenha a GRADE INTEIRA — inclusive dia sem evento
    /// (célula vazia ≠ zero) — sem reimplementar o calendário do banco.
    public struct WindowDay: Sendable, Equatable, Identifiable {
        /// "yyyy-MM-dd" no calendar injetado — mesma chave de `daily_agg.day`.
        public var day: String
        /// 00:00 do dia NESSE calendar (posição na grade semanal).
        public var date: Date
        /// Coluna na grade semanal: 1 = segunda … 7 = domingo, no calendar do
        /// BANCO. Vem daqui, e não da view: o `date` é 00:00 nesse calendar, e
        /// recalcular com `Calendar.current` (fuso a oeste) jogaria o dia para
        /// a coluna anterior.
        public var weekday: Int
        public var id: String { day }

        public init(day: String, date: Date, weekday: Int) {
            self.day = day
            self.date = date
            self.weekday = weekday
        }
    }

    /// Dias da janela de `days` dias terminando HOJE, do mais antigo ao mais
    /// recente. Mesma fonte do `windowStartDay` usado no `WHERE day >= ?`, então
    /// grade do heatmap e `dailySeries` concordam por construção. Avança com
    /// `Calendar.date(byAdding:)` (DST-safe), nunca somando 86_400s.
    /// `days <= 1` → só hoje (mesma regra do `windowStartDate`).
    public func windowDays(days: Int, now: Date = Date()) -> [WindowDay] {
        let today = calendar.startOfDay(for: now)
        var cursor = windowStartDate(days: days, now: now)
        var result: [WindowDay] = []
        while cursor <= today {
            // .weekday do Gregorian: 1 = domingo … 7 = sábado → 1 = segunda … 7 = domingo.
            let raw = calendar.component(.weekday, from: cursor)
            result.append(WindowDay(
                day: dayString(from: cursor), date: cursor, weekday: ((raw + 5) % 7) + 1))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Série diária (dia, provider) dentro da janela — barras do Analytics
    /// (empilhadas por provider) e custo/dia. `provider`/`model` opcionais
    /// filtram; `nil` = todos. Dias sem eventos NÃO vêm do banco (o chart
    /// lida com lacunas); custo do dia = `SUM(cost_usd)` do SQL: soma os
    /// grupos precificados e só é `nil` quando TODOS são NULL (mesma
    /// semântica do `todayCostUSD` do T2 — parcial nunca vira 0 nem some).
    /// - Returns: linhas ordenadas por dia, depois provider.
    public func dailySeries(
        provider: ProviderID? = nil, model: String? = nil,
        days: Int, now: Date = Date()
    ) throws -> [DailySeriesRow] {
        var sql = """
            SELECT day, provider,
                   SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS tokens,
                   SUM(cost_usd) AS cost
            FROM daily_agg
            WHERE day >= ?
            """
        var arguments: [any DatabaseValueConvertible] = [windowStartDay(days: days, now: now)]
        if let provider {
            sql += " AND provider = ?"
            arguments.append(provider.rawValue)
        }
        if let model {
            sql += " AND model = ?"
            arguments.append(model)
        }
        sql += " GROUP BY day, provider ORDER BY day, provider"
        return try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                let cost: Double? = row["cost"]
                let tokens: Int64 = row["tokens"] ?? 0
                return DailySeriesRow(day: row["day"], provider: row["provider"], tokens: tokens, costUSD: cost)
            }
        }
    }

    /// Totais por provider na janela (linha do painel é o caso `provider:`
    /// único de `weekTotal`; esta alimenta o resumo do Analytics).
    /// - Returns: ordenado por provider (ordem alfabética do rawValue).
    public func totals(days: Int, now: Date = Date()) throws -> [ProviderTotalRow] {
        let sql = """
            SELECT provider,
                   SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS tokens,
                   SUM(cost_usd) AS cost
            FROM daily_agg
            WHERE day >= ?
            GROUP BY provider
            ORDER BY provider
            """
        return try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [windowStartDay(days: days, now: now)]).map { row in
                let cost: Double? = row["cost"]
                let tokens: Int64 = row["tokens"] ?? 0
                return ProviderTotalRow(provider: row["provider"], tokens: tokens, costUSD: cost)
            }
        }
    }

    /// Total de UM provider na janela — "7d" do painel (1 query por CICLO,
    /// fora da MainActor). Provider sem histórico → zeros com custo `nil`.
    public func weekTotal(provider: ProviderID, days: Int = 7, now: Date = Date()) throws -> WeekTotal {
        let sql = """
            SELECT SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS tokens,
                   SUM(cost_usd) AS cost
            FROM daily_agg
            WHERE day >= ? AND provider = ?
            """
        let row = try writer.read { db in
            try Row.fetchOne(
                db, sql: sql,
                arguments: [windowStartDay(days: days, now: now), provider.rawValue])
        }
        let cost: Double? = row?["cost"]
        let tokens: Int64 = row?["tokens"] ?? 0
        return WeekTotal(tokens: tokens, costUSD: cost)
    }

    /// Breakdown por modelo na janela, tokens desc (a UI corta o top 5 —
    /// `AnalyticsModel.topModelsLimit`); custo com a semântica NULL ≠ 0.
    /// `provider` opcional (F5): filtra UM provider — fonte da linha "Top
    /// model" do painel; `nil` mantém o comportamento global (Analytics).
    public func modelBreakdown(
        days: Int, provider: ProviderID? = nil, now: Date = Date()
    ) throws -> [ModelBreakdownRow] {
        let sql = """
            SELECT model,
                   SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS tokens,
                   SUM(cost_usd) AS cost
            FROM daily_agg
            WHERE day >= ?\(provider != nil ? " AND provider = ?" : "")
            GROUP BY model
            ORDER BY tokens DESC, model ASC
            """
        var arguments: [String] = [windowStartDay(days: days, now: now)]
        if let provider { arguments.append(provider.rawValue) }
        return try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                let cost: Double? = row["cost"]
                let tokens: Int64 = row["tokens"] ?? 0
                return ModelBreakdownRow(model: row["model"], tokens: tokens, costUSD: cost)
            }
        }
    }

    /// Pontos diários para o `PacingEngine` (F4 Task 1) — [(dia, total)] da
    /// janela, um ponto por dia COM dados (gaps ficam de fora; o engine não
    /// faz zero-fill e usa a data real de cada ponto no eixo x). `day` é o
    /// início do dia no calendar do banco (mesma fonte do `day` persistido),
    /// ordenado ascendente. Provider/conta sem histórico → array vazio (o
    /// engine devolve nil — <2 pontos, sem chute). Consumido pela Task 2 (UI).
    public func pacingInput(
        provider: ProviderID, account: AccountID, days: Int, now: Date = Date()
    ) throws -> [(day: Date, total: Int64)] {
        let rows: [(day: String, total: Int64)] = try writer.read { db in
            try Row.fetchAll(
                db, sql: """
                    SELECT day,
                           SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS tokens
                    FROM daily_agg
                    WHERE day >= ? AND provider = ? AND account = ?
                    GROUP BY day ORDER BY day
                    """,
                arguments: StatementArguments([
                    windowStartDay(days: days, now: now), provider.rawValue, account.key,
                ])
            ).map { (day: $0["day"], total: $0["tokens"] ?? 0) }
        }
        return rows.compactMap { row in
            // Parse "yyyy-MM-dd" no calendar do banco (mesmo fuso do
            // dayString do rollover); linha malformada é descartada — nunca
            // inventa data.
            guard let day = Self.date(fromDayString: row.day, calendar: calendar) else { return nil }
            return (day: day, total: row.total)
        }
    }

    /// Inverso do `AppDatabase.dayString` — "yyyy-MM-dd" → início do dia no
    /// calendar injetado. Internal p/ os testes (@testable).
    static func date(fromDayString string: String, calendar: Calendar) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        return calendar.date(from: comps)
    }

    /// Eventos crus da janela — fonte do export CSV/JSON (30d fixo por ora).
    /// Ordenação estável (ts, id) → export determinístico para um DB imutável.
    public func eventsForExport(
        days: Int, now: Date = Date(), provider: ProviderID? = nil
    ) throws -> [UsageEventRecord] {
        // Início da janela via calendar (DST-safe), não soma fixa de segundos.
        var sql = "SELECT * FROM usage_events WHERE ts >= ?"
        var arguments: [any DatabaseValueConvertible] = [windowStartDate(days: days, now: now)]
        if let provider {
            sql += " AND provider = ?"
            arguments.append(provider.rawValue)
        }
        sql += " ORDER BY ts ASC, id ASC"
        return try writer.read { db in
            try UsageEventRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }
}
