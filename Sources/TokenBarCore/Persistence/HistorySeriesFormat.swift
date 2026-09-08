import Foundation

/// Formato de stdout do subcomando `tokenbar history` (F3 Task 4) — contrato
/// golden-tested, mesma disciplina do `HistoryExporter`. Reutiliza as MESMAS
/// convenções de formatação (header + linhas, LF com quebra final, RFC 4180,
/// `formatCost` aparado, custo NULL = campo vazio — desconhecido ≠ grátis),
/// mas sobre a SÉRIE DIÁRIA AGREGADA de `dailySeries` (dia × provider), não
/// sobre eventos crus: as colunas são `day,provider,tokens,cost_usd`.
///
/// JSON: array PLANO de `{day, provider, tokens, costUsd|null}` — sem
/// metadados (contrato do brief T4, mais enxuto que o Document do export);
/// nulo de custo EXPLÍCITO (encode customizado, decode sintetizado) e `[]`
/// quando vazio. Pretty-printed com chaves ordenadas — byte a byte estável
/// para um mesmo conjunto de linhas (o e2e T5 valida ingest → history).
///
/// Threading: síncrono e sem estado — o CLI chama direto após a query fora
/// de qualquer MainActor.
public enum HistorySeriesFormat {
    /// Header do CSV (mesma nomenclatura de colunas do export).
    public static let csvHeader = "day,provider,tokens,cost_usd"

    /// Linha do array JSON. `costUsd: Double?` com nil → `"costUsd": null`
    /// explícito (a síntese de Codable omitiria a chave via encodeIfPresent).
    public struct JSONRow: Sendable, Equatable, Codable {
        public var day: String
        public var provider: String
        public var tokens: Int64
        public var costUsd: Double?

        public init(day: String, provider: String, tokens: Int64, costUsd: Double?) {
            self.day = day
            self.provider = provider
            self.tokens = tokens
            self.costUsd = costUsd
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(day, forKey: .day)
            try c.encode(provider, forKey: .provider)
            try c.encode(tokens, forKey: .tokens)
            try c.encode(costUsd, forKey: .costUsd)  // nil → null explícito
        }
    }

    /// CSV completo com header — `rows` já ordenados (ordem do banco: day,
    /// provider). Termina em LF (mesma regra do `HistoryExporter.csv`).
    public static func csv(from rows: [AppDatabase.DailySeriesRow]) -> String {
        var lines = [csvHeader]
        for row in rows {
            let cost = row.costUSD.map(HistoryExporter.formatCost) ?? ""
            lines.append([
                HistoryExporter.csvField(row.day),
                HistoryExporter.csvField(row.provider),
                String(row.tokens),
                HistoryExporter.csvField(cost),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Mapeia a série do banco para as linhas do array JSON.
    public static func jsonRows(from rows: [AppDatabase.DailySeriesRow]) -> [JSONRow] {
        rows.map { row in
            JSONRow(day: row.day, provider: row.provider, tokens: row.tokens, costUsd: row.costUSD)
        }
    }

    /// Array JSON pretty-printed com chaves ordenadas; vazio → `[]` (o
    /// JSONEncoder com prettyPrinted quebraria o array vazio em "[\n\n]" —
    /// contrato do CLI é o literal compacto).
    public static func json(from rows: [AppDatabase.DailySeriesRow]) throws -> Data {
        guard !rows.isEmpty else { return Data("[]".utf8) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(jsonRows(from: rows))
    }
}
