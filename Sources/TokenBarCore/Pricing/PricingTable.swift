import Foundation

/// Tabela de preços públicos (USD/MTok) versionada — F3 Task 2. O JSON
/// (`Resources/pricing.json`, embutido no target via `Bundle.module`) traz
/// APENAS nomes de modelo e preços publicados nas pricing-pages dos vendors,
/// com URL + data de coleta por entrada. Nada de credencial; nada de preço
/// inventado: modelo ausente → custo `nil` (spec §6: "nunca chute").
///
/// - **Match por prefixo**: a chave mais longa que é prefixo do nome do
///   modelo vence — `claude-sonnet-4-5` cobre `claude-sonnet-4-5-20250929`;
///   `gemini-2.5-flash-lite` tem entrada própria e vence o prefixo
///   `gemini-2.5-flash`. Comparação case-insensitive.
/// - **Tier sem preço público por token** (`null` no JSON, ex.: cache write
///   do Gemini, cobrado por hora de armazenamento) CONTRIBUI 0 na estimativa.
/// - Atualização de preços = PR editando o JSON (bump de `version` +
///   `updated`); o custo é calculado NA INGEST e gravado em `cost_usd` —
///   eventos antigos mantêm o custo calculado na época (não-retroativo, o
///   `hwm` da persistência impede re-leitura).
public struct PricingTable: Sendable, Equatable {
    /// Preço de UM modelo por tier. `nil` = sem preço público confirmado p/
    /// aquele tier (não contribui na estimativa — nunca um chute).
    public struct ModelPrice: Sendable, Equatable, Codable {
        public let input: Double?
        public let output: Double?
        public let cacheRead: Double?
        public let cacheWrite: Double?
        /// URL pública da pricing-page + data de coleta (contrato do brief).
        public let source: String?

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case source
        }

        public init(
            input: Double?, output: Double?,
            cacheRead: Double?, cacheWrite: Double?, source: String? = nil
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.source = source
        }

        /// Estimativa USD de um evento: `(tokens × preço)/1e6` somado nos
        /// tiers com preço; tier `nil` contribui 0 (documentado no JSON).
        public func costUSD(
            inputTokens: Int64, outputTokens: Int64,
            cacheReadTokens: Int64, cacheWriteTokens: Int64
        ) -> Double {
            func tier(_ tokens: Int64, _ rate: Double?) -> Double {
                guard let rate, tokens > 0 else { return 0 }
                return Double(tokens) * rate
            }
            return (
                tier(inputTokens, input) + tier(outputTokens, output)
                    + tier(cacheReadTokens, cacheRead) + tier(cacheWriteTokens, cacheWrite)
            ) / 1_000_000
        }
    }

    /// Formato do arquivo (contrato: `{"version", "updated", "models": {...}}`).
    private struct PricingFile: Codable {
        let version: Int
        let updated: String
        let models: [String: ModelPrice]
    }

    /// Versão do schema do JSON (bump em mudança de formato).
    public let version: Int
    /// Data da última revisão de preços (YYYY-MM-DD).
    public let updated: String
    /// Chaves = prefixos de modelo (lowercase — match é case-insensitive).
    private let entries: [String: ModelPrice]

    public init(version: Int, updated: String, models: [String: ModelPrice]) {
        self.version = version
        self.updated = updated
        self.entries = models.mapKeys { $0.lowercased() }
    }

    /// Tabela embutida no target (`Resources/pricing.json`). `nil` quando o
    /// recurso falta ou não decodifica — degradação honesta: custo `nil`
    /// em todo evento, app segue vivo (mesmo espírito do DB opcional).
    /// (O `Bundle.module` é internal ao módulo, então o default fica no corpo
    /// e não como argumento público.)
    public static func bundled() -> PricingTable? {
        bundled(in: .module)
    }

    /// Variante injetável p/ testes (bundle sintético com pricing.json próprio).
    static func bundled(in bundle: Bundle) -> PricingTable? {
        guard let url = bundle.url(forResource: "pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PricingFile.self, from: data)
        else { return nil }
        return PricingTable(version: file.version, updated: file.updated, models: file.models)
    }

    /// Preço do modelo: a chave-prefixo MAIS LONGA que casa vence (exato é o
    /// caso-limite do prefixo). Sem nenhuma chave casa → `nil`.
    public func price(forModel model: String) -> ModelPrice? {
        let key = model.lowercased()
        var best: (prefix: String, price: ModelPrice)?
        for (prefix, price) in entries where key.hasPrefix(prefix) {
            if best == nil || prefix.count > best!.prefix.count {
                best = (prefix, price)
            }
        }
        return best?.price
    }

    /// Custo estimado (USD) de um evento. Modelo `nil` ou sem entrada na
    /// tabela → `nil` — a ausência é explícita, nunca um custo chutado.
    public func costUSD(
        model: String?, inputTokens: Int64, outputTokens: Int64,
        cacheReadTokens: Int64, cacheWriteTokens: Int64
    ) -> Double? {
        guard let price = model.flatMap({ price(forModel: $0) }) else { return nil }
        return price.costUSD(
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }
}

extension Dictionary {
    fileprivate func mapKeys<V>(_ transform: (Key) -> V) -> [V: Value] {
        var result: [V: Value] = [:]
        for (key, value) in self { result[transform(key)] = value }
        return result
    }
}
