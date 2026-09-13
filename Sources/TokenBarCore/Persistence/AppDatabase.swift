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
    /// Fonte da tabela de preços. `.bundledLazy` = tabela embutida via
    /// `Bundle.module` — carregada LAZY na 1ª leitura (ver `BundledPricingBox`);
    /// `.fixed` = tabela explícita (`pricing:` no `open`, testes/wiring).
    private enum PricingSource: Sendable {
        case bundledLazy
        case fixed(PricingTable?)
    }

    private let pricingSource: PricingSource
    /// Box do `.bundledLazy` — alocação barata (um lock), criada sempre.
    private let bundledPricing = BundledPricingBox()

    /// Tabela de preços em uso — lida APENAS no hot loop da ingest
    /// (`persistBatch`, extensão `UsageEventPersisting`), que roda fora da
    /// main thread dentro do ciclo do coordinator. É a garantia do fix do
    /// hang: o accessor `Bundle.module` nunca roda na main thread do init.
    var pricing: PricingTable? {
        switch pricingSource {
        case .fixed(let table):
            return table
        case .bundledLazy:
            return bundledPricing.value
        }
    }
    /// Nome do arquivo na support directory (wiring do coordinator).
    public static let databaseName = "tokenbar.sqlite"

    let writer: any DatabaseWriter
    /// PÚBLICO desde a F7: além das extensões de leitura de histórico
    /// (`HistoryQueries`), o motor de alertas precisa do MESMO calendar do
    /// rollover do ledger e da escrita de `daily_agg` para calcular o mês do
    /// orçamento (projeção por dias corridos) — painel, gráficos e alertas têm
    /// que concordar no dia.
    public let calendar: Calendar
    /// Tabela de preços públicos (F3 Task 2) usada para calcular `cost_usd`
    /// NA INGEST. `nil` = sem tabela (recurso ausente/corrompido ou `nil`
    /// explícito) → todo evento persiste com custo NULL — degradação honesta.
    /// (O acesso passou para a computed `pricing` — lazy quando `.bundledLazy`.)

    /// Abre (ou cria) o banco em `url` e roda as migrations, com a pricing
    /// table EMBUTIDA em modo LAZY — o accessor `Bundle.module` NÃO roda neste
    /// call site (era o hang via `open`: default argument avaliado dentro do
    /// `ProviderCoordinator.init`, na main thread, sob a transação do
    /// CFBundle do LaunchServices). Throws — o chamador (coordinator) degrada
    /// para o comportamento F2 em caso de erro: persistência é aditiva, nunca
    /// uma condição de crash. A 1ª leitura da tabela acontece no ciclo de
    /// ingest (fora da main) — ver `BundledPricingBox`.
    public static func open(at url: URL, calendar: Calendar = .current) throws -> AppDatabase {
        try open(at: url, calendar: calendar, source: .bundledLazy)
    }

    /// Variante com pricing table EXPLÍCITA (`nil` = eventos sem custo) —
    /// testes e wiring que já têm a tabela na mão; carregamento imediato,
    /// sem tocar `Bundle.module`.
    public static func open(
        at url: URL, calendar: Calendar = .current, pricing: PricingTable?
    ) throws -> AppDatabase {
        try open(at: url, calendar: calendar, source: .fixed(pricing))
    }

    private static func open(
        at url: URL, calendar: Calendar, source: PricingSource
    ) throws -> AppDatabase {
        let pool = try DatabasePool(path: url.path)
        try Self.migrator.migrate(pool)
        return AppDatabase(writer: pool, calendar: calendar, pricingSource: source)
    }

    private init(
        writer: any DatabaseWriter, calendar: Calendar = .current,
        pricingSource: PricingSource = .fixed(nil)
    ) {
        self.writer = writer
        self.calendar = calendar
        self.pricingSource = pricingSource
    }

    /// Migrations v1 — schema da spec §6 (DDL verbatim). Versões futuras
    /// adicionam `registerMigration("v2")` etc.; nunca editar uma já
    /// publicada (o SQLite de usuários reais carrega o histórico).
    ///
    /// v2 (F4 multi-conta): a tabela `accounts` ganha as colunas de resolução
    /// read-only da credencial e do corpus local — `credential_path` (arquivo
    /// de credencial que o provider lê no ciclo) e `directory_path` (raiz de
    /// ingest própria da conta; vazio = conta API-only, sem ingest). ALTER
    /// TABLE aditivo: o schema §6 v1 permanece intacto para bancos existentes.
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
        // v2 (F4 multi-conta): colunas de resolução da conta registrada —
        // `credential_path` (arquivo lido read-only pelo provider no ciclo) e
        // `directory_path` (raiz de ingest própria; vazio = conta API-only).
        // ALTER aditivo: bancos v1 existentes migram sem tocar no histórico.
        migrator.registerMigration("v2") { db in
            try db.execute(
                sql: "ALTER TABLE accounts ADD COLUMN credential_path TEXT NOT NULL DEFAULT ''")
            try db.execute(
                sql: "ALTER TABLE accounts ADD COLUMN directory_path TEXT NOT NULL DEFAULT ''")
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

/// Box LAZY e thread-safe da pricing table embutida (`PricingTable.bundled()`).
///
/// Fix do hang pós-merge F4: o default argument `pricing: PricingTable? =
/// PricingTable.bundled()` avaliava `Bundle.module` NO call site — dentro do
/// `ProviderCoordinator.init`, na main thread, ANTES do NSApplication
/// completar o launch. Lançado via LaunchServices (`open`), o CFBundle está em
/// transação nesse momento e o accessor (`_cfBundle`/`NSBundle
/// URLForResource`) trava a main thread por minutos (status item nunca
/// aparece); via exec direto nunca reproduzia. Agora o accessor só roda na
/// 1ª LEITURA de `AppDatabase.pricing` — que acontece no hot loop da ingest
/// (`persistBatch`, dentro do ciclo do coordinator, FORA da main thread).
///
/// Memoização com `OSAllocatedUnfairLock`: computa UMA vez (mesma semântica
/// do argumento default eager, que também avaliava 1× por open) e memoiza
/// `nil` também — recurso ausente/corrompido segue a degradação honesta
/// (custo `nil` em todo evento), sem retry implícito a cada lote. Ingests
/// concorrentes (multi-conta/providers em paralelo) disputam o lock, não o
/// carregamento duplicado.
private final class BundledPricingBox: @unchecked Sendable {
    private struct State: Sendable {
        var table: PricingTable?
        var loaded = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var value: PricingTable? {
        lock.withLock { state in
            if !state.loaded {
                state.table = PricingTable.bundled()
                state.loaded = true
            }
            return state.table
        }
    }
}
