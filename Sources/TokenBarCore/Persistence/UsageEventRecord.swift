import Foundation
import GRDB

/// Linha de `usage_events` (spec §6). Mapeamento explícito das colunas
/// snake_case via `CodingKeys` com rawValue = nome da coluna (o caminho
/// idiomático do GRDB; o DDL é da spec e não muda).
///
/// `ts` é armazenado como REAL (epoch segundos — estratégia default de Date
/// no GRDB); `cost_usd` fica `nil` na Task 1 (a tabela `pricing` e o cálculo
/// "~USD" entram na Task 2; nunca chute, spec §6).
public struct UsageEventRecord: Sendable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "usage_events"

    public var id: Int64?
    public var ts: Date
    public var provider: String
    public var account: String
    public var model: String?
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var costUSD: Double?
    public var source: String
    public var project: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, provider, account, model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case costUSD = "cost_usd"
        case source, project
    }

    /// Valor de `source` para eventos de ingest local (Task 1 só persiste
    /// ingest local; o dia em que usage via API virar evento, entra "api").
    public static let localSource = "local"

    public init(_ event: UsageEvent, source: String = UsageEventRecord.localSource) {
        self.id = nil
        self.ts = event.ts
        self.provider = event.provider.rawValue
        self.account = event.account.key
        self.model = event.model
        self.inputTokens = event.inputTokens
        self.outputTokens = event.outputTokens
        self.cacheReadTokens = event.cacheReadTokens
        self.cacheWriteTokens = event.cacheWriteTokens
        self.costUSD = nil
        self.source = source
        self.project = event.project
    }
}
