import Foundation
import GRDB
import os

/// Log estruturado da persistência (F3): eventos de degradação sem quebrar o
/// app. NUNCA interpola credenciais nem conteúdo de arquivo — `.private` nos
/// erros crus (podem conter paths).
package let persistenceLog = Logger(subsystem: "dev.domhubs.TokenBar", category: "persistence")

/// Banco SQLite (WAL) do TokenBar — spec §6. Caminho canônico:
/// `App Support/TokenBar/tokenbar.sqlite` (o override `TOKENBAR_SUPPORT_DIR`
/// do AppState move o diretório inteiro — DB incluso — para o e2e/testes).
///
/// - `DatabasePool` já abre em WAL (leitores concorrentes, 1 escritor).
/// - Migrations v1 = schema §6 COMPLETO (usage_events, daily_agg, accounts,
///   pricing, alert_rules, settings + índices), DDL verbatim da spec —
///   `alert_rules`/`pricing` são usados por tasks F3/F4 seguintes.
/// - Idempotência das migrations: o migrator do GRDB registra o que já
///   rodou em `grdb_migrations`; reabrir o mesmo arquivo é no-op.
///
/// Sendable: `DatabasePool` é Sendable e `Calendar` (injetado para o dia de
/// `daily_agg` bater com o ledger dos providers) é struct imutável.
public final class AppDatabase: Sendable {
    /// Nome do arquivo na support directory (wiring do coordinator).
    public static let databaseName = "tokenbar.sqlite"

    let writer: any DatabaseWriter
    private let calendar: Calendar
    /// Tabela de preços públicos (F3 Task 2) usada para calcular `cost_usd`
    /// NA INGEST. `nil` = sem tabela (recurso ausente/corrompido ou `nil`
    /// explícito) → todo evento persiste com custo NULL — degradação honesta.
    /// Internal (não `private`): a extensão `UsageEventPersisting`, em outro
    /// arquivo, é quem consome no hot loop da ingest.
    let pricing: PricingTable?

    /// Abre (ou cria) o banco em `url` e roda as migrations. Throws — o
    /// chamador (coordinator) degrada para o comportamento F2 em caso de erro
    /// (disco cheio/ilegível, path inválido…): persistência é aditiva, nunca
    /// uma condição de crash. `pricing` default = tabela embutida
    /// (`Resources/pricing.json`); `nil` explícito = eventos sem custo.
    public static func open(
        at url: URL, calendar: Calendar = .current,
        pricing: PricingTable? = PricingTable.bundled()
    ) throws -> AppDatabase {
        let pool = try DatabasePool(path: url.path)
        try Self.migrator.migrate(pool)
        return AppDatabase(writer: pool, calendar: calendar, pricing: pricing)
    }

    init(
        writer: any DatabaseWriter, calendar: Calendar = .current,
        pricing: PricingTable? = nil
    ) {
        self.writer = writer
        self.calendar = calendar
        self.pricing = pricing
    }

    /// Migrations v1 — schema da spec §6 (DDL verbatim). Versões futuras
    /// adicionam `registerMigration("v2")` etc.; nunca editar uma já
    /// publicada (o SQLite de usuários reais carrega o histórico).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE usage_events (
                  id INTEGER PRIMARY KEY, ts REAL NOT NULL,
                  provider TEXT NOT NULL, account TEXT NOT NULL, model TEXT,
                  input_tokens INT DEFAULT 0, output_tokens INT DEFAULT 0,
                  cache_read_tokens INT DEFAULT 0, cache_write_tokens INT DEFAULT 0,
                  cost_usd REAL, source TEXT NOT NULL, project TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_events_ts ON usage_events(ts)")
            try db.execute(sql: "CREATE INDEX idx_events_provider_ts ON usage_events(provider, ts)")

            try db.execute(sql: """
                CREATE TABLE daily_agg (
                  day TEXT NOT NULL, provider TEXT NOT NULL, account TEXT NOT NULL, model TEXT NOT NULL,
                  input_tokens INT DEFAULT 0, output_tokens INT DEFAULT 0,
                  cache_read_tokens INT DEFAULT 0, cache_write_tokens INT DEFAULT 0,
                  cost_usd REAL DEFAULT 0, PRIMARY KEY (day, provider, account, model)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE accounts (
                  provider TEXT NOT NULL, account_id TEXT NOT NULL,
                  label TEXT NOT NULL, kind TEXT NOT NULL,
                  active INT NOT NULL DEFAULT 1,
                  PRIMARY KEY (provider, account_id)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE pricing (
                  model TEXT NOT NULL, valid_from TEXT NOT NULL,
                  input_per_mtok REAL, output_per_mtok REAL,
                  cache_read_per_mtok REAL, cache_write_per_mtok REAL,
                  PRIMARY KEY (model, valid_from)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE alert_rules (
                  id INTEGER PRIMARY KEY, provider TEXT NOT NULL, account TEXT NOT NULL,
                  window_kind TEXT NOT NULL, threshold_pct INT NOT NULL,
                  enabled INT NOT NULL DEFAULT 1, last_fired_at REAL
                )
                """)

            try db.execute(sql: "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        }
        return migrator
    }

    // MARK: - Settings (spec §6: key TEXT PRIMARY KEY, value TEXT NOT NULL)

    public func setting(forKey key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    /// `value == nil` remove a chave. Upsert em uma statement.
    public func setSetting(_ value: String?, forKey key: String) throws {
        try writer.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - Consultas mínimas (testes Task 1; analytics F3 Task 3 amplia)

    public struct DailyAggRow: Sendable, Equatable {
        public var day: String
        public var provider: String
        public var account: String
        public var model: String
        public var inputTokens: Int64
        public var outputTokens: Int64
        public var cacheReadTokens: Int64
        public var cacheWriteTokens: Int64
        public var costUSD: Double

        public init(
            day: String, provider: String, account: String, model: String,
            inputTokens: Int64, outputTokens: Int64,
            cacheReadTokens: Int64, cacheWriteTokens: Int64, costUSD: Double
        ) {
            self.day = day
            self.provider = provider
            self.account = account
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.costUSD = costUSD
        }
    }

    public func usageEventCount(provider: ProviderID? = nil) throws -> Int {
        try writer.read { db in
            // Argumentos vinculados sempre (padrão anti-injection do Red Team T5).
            if let provider {
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM usage_events WHERE provider = ?",
                    arguments: [provider.rawValue]) ?? 0
            } else {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events") ?? 0
            }
        }
    }

    public func dailyAggRows(provider: ProviderID? = nil) throws -> [DailyAggRow] {
        try writer.read { db in
            let rows: [Row]
            if let provider {
                rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM daily_agg WHERE provider = ? ORDER BY day, model",
                    arguments: [provider.rawValue])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM daily_agg ORDER BY day, model")
            }
            return rows.map { row -> DailyAggRow in
                let cost: Double? = row["cost_usd"]
                return DailyAggRow(
                    day: row["day"], provider: row["provider"], account: row["account"], model: row["model"],
                    inputTokens: row["input_tokens"], outputTokens: row["output_tokens"],
                    cacheReadTokens: row["cache_read_tokens"], cacheWriteTokens: row["cache_write_tokens"],
                    costUSD: cost ?? 0
                )
            }
        }
    }

    /// Soma de `cost_usd` dos eventos de HOJE (fuso do calendar injetado) de
    /// um provider — fonte do "~$" do painel (F3 Task 2). `nil` = nenhum
    /// evento com custo computável hoje (o provider fica só com tokens);
    /// eventos persistidos com custo NULL (T1/modelo sem preço) ficam de fora
    /// — a soma nunca inventa custo. Query de leitura indexada, 1× por ciclo
    /// do provider (o render gate da F1 NÃO consulta o banco).
    public func todayCostUSD(provider: ProviderID, now: Date = Date()) throws -> Double? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return try writer.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT SUM(cost_usd) FROM usage_events
                    WHERE provider = ? AND ts >= ? AND ts < ?
                    """,
                arguments: [provider.rawValue, today, tomorrow])
        }
    }

    /// Dia ("yyyy-MM-dd") de um evento no calendar injetado — mesma fonte do
    /// rollover do ledger, então daily_agg e display "Hoje" concordam.
    public func dayString(from date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
