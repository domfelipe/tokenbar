import Foundation

/// Export do histórico (F3 Task 3, spec §8): CSV e JSON das linhas cruas de
/// `usage_events` (30 dias fixos por ora) gravados em
/// `<support>/exports/history-<timestamp>.csv|.json`. Formatos SÃO contrato
/// (testes golden): não mudar sem bump de `version` do JSON.
///
/// - CSV (RFC 4180): `ts,provider,account,model,tokens,cost_usd` — `ts` ISO
///   UTC, `tokens` = total (in+out+cache read+write), `cost_usd` VAZIO quando
///   NULL (desconhecido ≠ grátis) e `model` vazio quando NULL.
/// - JSON: mesma linha estruturada (nulos explícitos) + metadados
///   `version`/`generated_at`/`period`. Chaves ordenadas, pretty-printed —
///   byte a byte estável para um mesmo conjunto de eventos.
///
/// Formatação de `cost_usd` (CSV): `%.6f` com zeros à direita aparados
/// ("0.000759", "12.46", "0") — determinístico, sem notação científica.
/// Threading: síncrono, para rodar FORA da MainActor (quem chama empacota em
/// `Task.detached`); o reveal no Finder (AppKit) fica no chamador.
public struct HistoryExporter: Sendable {
    /// Janela do export — 30 dias fixos por ora (brief Task 3).
    public static let exportDays = 30
    /// Versão do formato JSON (bump em mudança de contrato).
    public static let formatVersion = 1

    public let database: AppDatabase
    /// Diretório de saída (o app usa `<support>/exports`; testes injetam tmp).
    public let directory: URL

    public init(database: AppDatabase, supportDirectory: URL) {
        self.database = database
        self.directory = supportDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    // MARK: - Documento JSON

    /// Documento JSON completo — público p/ golden tests e para o CLI de
    /// history (Task 4) reusar o MESMO formato da UI.
    public struct Document: Sendable, Equatable, Codable {
        public struct Period: Sendable, Equatable, Codable {
            public var days: Int
            public var from: String
            public var to: String
        }
        /// Linha estruturada: mesmo campo do CSV; nulos EXPLÍCITOS (custom
        /// encode — a síntese de Codable usaria encodeIfPresent e omitiria).
        /// Decode é sintetizado (null → nil via decodeIfPresent).
        public struct Row: Sendable, Equatable, Codable {
            public var ts: String
            public var provider: String
            public var account: String
            public var model: String?
            public var tokens: Int64
            public var costUSD: Double?

            enum CodingKeys: String, CodingKey {
                case ts, provider, account, model, tokens
                case costUSD = "cost_usd"
            }

            public init(ts: String, provider: String, account: String, model: String?, tokens: Int64, costUSD: Double?) {
                self.ts = ts
                self.provider = provider
                self.account = account
                self.model = model
                self.tokens = tokens
                self.costUSD = costUSD
            }

            public func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(ts, forKey: .ts)
                try c.encode(provider, forKey: .provider)
                try c.encode(account, forKey: .account)
                try c.encode(model, forKey: .model)  // nil → null explícito
                try c.encode(tokens, forKey: .tokens)
                try c.encode(costUSD, forKey: .costUSD)  // idem
            }
        }

        public var version: Int
        public var generatedAt: String
        public var period: Period
        public var rows: [Row]

        enum CodingKeys: String, CodingKey {
            case version
            case generatedAt = "generated_at"
            case period, rows
        }
    }

    // MARK: - Formatação pura (golden tests)

    /// ISO UTC ("2026-09-07T12:34:56Z") — locale fixo, sem depender do fuso
    /// da máquina rodando o export.
    public static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    public static func formatCost(_ cost: Double) -> String {
        var text = String(format: "%.6f", cost)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Escape RFC 4180: cita só quando precisa (, " CR LF) e dobra as aspas.
    public static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// CSV completo com header — `rows` já ordenados (ordem do DB: ts, id).
    public static func csv(from rows: [Document.Row]) -> String {
        var lines = ["ts,provider,account,model,tokens,cost_usd"]
        for row in rows {
            let cost = row.costUSD.map(formatCost) ?? ""
            let model = row.model ?? ""
            lines.append([
                csvField(row.ts), csvField(row.provider), csvField(row.account),
                csvField(model), String(row.tokens), csvField(cost),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Mapeia eventos do DB para linhas do documento (fonte comum CSV/JSON).
    public static func documentRows(from events: [UsageEventRecord]) -> [Document.Row] {
        events.map { event in
            Document.Row(
                ts: isoString(from: event.ts),
                provider: event.provider,
                account: event.account,
                model: event.model,
                tokens: event.inputTokens + event.outputTokens
                    + event.cacheReadTokens + event.cacheWriteTokens,
                costUSD: event.costUSD)
        }
    }

    public static func jsonDocument(
        events: [UsageEventRecord], now: Date, days: Int, database: AppDatabase
    ) throws -> Document {
        let from = database.windowStartDay(days: days, now: now)
        return Document(
            version: formatVersion,
            generatedAt: isoString(from: now),
            period: Document.Period(days: days, from: from, to: isoString(from: now)),
            rows: documentRows(from: events))
    }

    public static func json(from events: [UsageEventRecord], now: Date, days: Int, database: AppDatabase) throws -> Data {
        let document = try jsonDocument(events: events, now: now, days: days, database: database)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    // MARK: - Escrita

    /// "20260907-123456" (UTC, POSIX) — nome estável e ordenável.
    public static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Exporta CSV e JSON da mesma janela — MESMOS dados nos dois formatos.
    /// - Returns: [csv, json] (nessa ordem).
    @discardableResult
    public func exportAll(now: Date = Date()) throws -> [URL] {
        let events = try database.eventsForExport(days: Self.exportDays, now: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.fileTimestamp(now)

        let csvURL = directory.appendingPathComponent("history-\(stamp).csv")
        try Self.csv(from: Self.documentRows(from: events))
            .write(to: csvURL, atomically: true, encoding: .utf8)

        let jsonURL = directory.appendingPathComponent("history-\(stamp).json")
        try Self.json(from: events, now: now, days: Self.exportDays, database: database)
            .write(to: jsonURL, options: .atomic)

        return [csvURL, jsonURL]
    }
}
