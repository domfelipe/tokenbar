import Foundation
import GRDB

/// Contrato de persistência da ingest local (F3 Task 1) — os providers
/// dependem DESTE protocolo, nunca do GRDB (o detalhe SQLite vive no Core;
/// testes injetam mocks).
public protocol UsageEventPersisting: Sendable {
    /// Persiste um lote da ingest streaming: `usage_events` + upsert de
    /// `daily_agg` + marca d'água por arquivo — TUDO na MESMA transação
    /// (spec §6: "ingest incremental: transação por lote; daily_agg
    /// atualizada na mesma transação").
    ///
    /// - `endOffset`: offset ABSOLUTO no arquivo logo após o último byte
    ///   consumido deste lote. Dedupe: lote com `endOffset <=` marca d'água
    ///   persistida do path é ignorado — o re-scan de rollover (cursores
    ///   zerados na virada de dia) e o re-ingest por cursor perdido relêem o
    ///   arquivo inteiro; sem a marca d'água o histórico dobraria a cada
    ///   meia-noite. A marca d'água avança na mesma transação dos eventos,
    ///   então crash entre evento e cursor não duplica nem perde.
    /// - `resetToZero`: o arquivo ENCOLHEU (truncamento/rewrite) — a marca
    ///   d'água anterior é descartada e o conteúdo re-lido é persistido como
    ///   novo (o ledger exibe a soma corrigida; no DB o conteúdo antigo do
    ///   mesmo arquivo permanece — limitação documentada do caso patológico).
    ///
    /// Custo (F3 Task 2): `cost_usd` é calculado NA INGEST pela `PricingTable`
    /// injetada no `AppDatabase` e gravado na mesma INSERT (`usage_events`) e
    /// no upsert de `daily_agg`. Modelo sem preço público → `NULL`, nunca 0.
    /// NÃO-RETROATIVO POR CONSTRUÇÃO: eventos já persistidos (T1, sem custo —
    /// e sem tabela de preços) ficam como estão — o `hwm` impede re-leitura,
    /// então nunca são re-precificados; só eventos novos ganham custo.
    func persistBatch(
        provider: ProviderID, path: String, events: [UsageEvent],
        endOffset: UInt64, resetToZero: Bool
    ) throws
}

/// Chave da marca d'água de um arquivo na tabela `settings`. A chave é
/// opaca (nunca parseada — lookup exato), então `:` no path é inofensivo.
func highWaterKey(provider: ProviderID, path: String) -> String {
    "hwm:\(provider.rawValue):\(path)"
}

extension AppDatabase: UsageEventPersisting {
    public func persistBatch(
        provider: ProviderID, path: String, events: [UsageEvent],
        endOffset: UInt64, resetToZero: Bool
    ) throws {
        let hwmKey = highWaterKey(provider: provider, path: path)
        try writer.write { db in
            if resetToZero {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [hwmKey])
            }
            let previous = try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [hwmKey]
            ).flatMap { UInt64($0) }
            if let previous, endOffset <= previous { return }  // já persistido

            // Agrupa por (dia, provider, account, modelo) em memória: um
            // upsert por grupo com a soma do lote (few statements; 100k
            // eventos <10s). O provider do agrupamento vem do PRÓPRIO evento
            // (stampado no parser) — o parâmetro `provider` só governa a
            // marca d'água.
            if !events.isEmpty {
                struct Group {
                    var day: String
                    var provider: String
                    var account: String
                    var model: String
                    var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0
                    var cost: Double = 0
                    /// Eventos do grupo SEM preço na tabela deixam o custo do
                    /// grupo NULL (honesto) — nunca 0 ("grátis").
                    var hasCost = false
                }
                var groups: [String: Group] = [:]
                // Memo de preço por string de modelo do lote: o match de
                // prefixo roda 1× por modelo distinto, não por evento
                // (transcripts repetem poucos modelos em milhares de linhas).
                var priceByModel: [String: PricingTable.ModelPrice?] = [:]
                for event in events {
                    let day = dayString(from: event.ts)
                    let model = event.model ?? Self.unknownModel
                    let groupKey = "\(day)|\(event.provider.rawValue)|\(event.account.key)|\(model)"
                    // Custo do evento: calculado NA INGEST (Task 2); modelo
                    // `nil` ou sem entrada na tabela → NULL no banco.
                    var eventCost: Double?
                    if let eventModel = event.model {
                        let price: PricingTable.ModelPrice?
                        if let cached = priceByModel[eventModel] {
                            price = cached
                        } else {
                            let looked = pricing?.price(forModel: eventModel)
                            priceByModel[eventModel] = looked
                            price = looked
                        }
                        eventCost = price?.costUSD(
                            inputTokens: event.inputTokens, outputTokens: event.outputTokens,
                            cacheReadTokens: event.cacheReadTokens,
                            cacheWriteTokens: event.cacheWriteTokens)
                    }
                    var group = groups[groupKey] ?? Group(
                        day: day, provider: event.provider.rawValue,
                        account: event.account.key, model: model)
                    group.input += event.inputTokens
                    group.output += event.outputTokens
                    group.cacheRead += event.cacheReadTokens
                    group.cacheWrite += event.cacheWriteTokens
                    if let eventCost {
                        group.cost += eventCost
                        group.hasCost = true
                    }
                    groups[groupKey] = group
                    // Insert tipado (UsageEventRecord → colunas §6); o GRDB
                    // reusa a prepared statement entre chamadas.
                    try UsageEventRecord(event, costUSD: eventCost).insert(db)
                }

                let upsert = try db.cachedStatement(sql: """
                    INSERT INTO daily_agg (day, provider, account, model, input_tokens, output_tokens,
                                           cache_read_tokens, cache_write_tokens, cost_usd)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (day, provider, account, model) DO UPDATE SET
                      input_tokens = input_tokens + excluded.input_tokens,
                      output_tokens = output_tokens + excluded.output_tokens,
                      cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
                      cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
                      cost_usd = CASE
                        WHEN excluded.cost_usd IS NULL THEN cost_usd
                        ELSE COALESCE(cost_usd, 0) + excluded.cost_usd
                      END
                    """)
                for group in groups.values {
                    try upsert.execute(
                        arguments: [group.day, group.provider, group.account, group.model,
                                    group.input, group.output, group.cacheRead, group.cacheWrite,
                                    group.hasCost ? group.cost : nil])
                }
            }

            // Marca d'água avança na MESMA transação dos eventos.
            try db.execute(
                sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                arguments: [hwmKey, String(endOffset)])
        }
    }

    /// Sentinel de agrupamento para evento sem model — diário/analytics
    /// mostram o grupo; nunca um modelo inventado (spec: "nunca chute").
    static let unknownModel = "unknown"

    /// Marca d'água atual de um path (testes; nil = nada persistido).
    public func highWater(provider: ProviderID, path: String) throws -> UInt64? {
        try setting(forKey: highWaterKey(provider: provider, path: path)).flatMap { UInt64($0) }
    }
}
