import Foundation
import Testing
@testable import TokenBarCore

/// F3 Task 2 — PricingTable: match por prefixo (sufixo datado), longest-match,
/// cálculo com tiers de cache, modelo ausente → nil (nunca chute) e a tabela
/// embutida cobrindo as famílias dos transcripts reais.
@Suite
struct PricingTableTests {
    /// Tabela sintética p/ mecânica de match (independe do conteúdo do JSON).
    func syntheticTable() -> PricingTable {
        PricingTable(version: 1, updated: "2026-09-08", models: [
            "claude-sonnet-4": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            "gpt-5": .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: nil),
            "gpt-5-mini": .init(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: nil),
            "gemini-2.5-flash": .init(input: 0.3, output: 2.5, cacheRead: 0.03, cacheWrite: nil),
            "gemini-2.5-flash-lite": .init(input: 0.1, output: 0.4, cacheRead: 0.01, cacheWrite: nil),
        ])
    }

    // MARK: - Match por prefixo

    @Test("match exato e por sufixo datado")
    func exactAndDatedSuffix() {
        let table = syntheticTable()
        #expect(table.price(forModel: "claude-sonnet-4") != nil)
        // Sufixo datado herda o preço do prefixo (contrato do brief).
        #expect(table.price(forModel: "claude-sonnet-4-5-20250929")?.input == 3)
        #expect(table.price(forModel: "gpt-5-2025-08-07")?.input == 1.25)
    }

    @Test("longest match vence o prefixo curto")
    func longestPrefixWins() {
        let table = syntheticTable()
        // flash-lite tem entrada própria — NÃO herda o preço do flash (5×).
        #expect(table.price(forModel: "gemini-2.5-flash-lite")?.input == 0.1)
        #expect(table.price(forModel: "gemini-2.5-flash-lite-preview-06-17")?.input == 0.1)
        // gpt-5-mini tem entrada própria — NÃO herda o gpt-5.
        #expect(table.price(forModel: "gpt-5-mini")?.input == 0.25)
        // Sem entrada própria: herda o prefixo mais longo existente.
        #expect(table.price(forModel: "gemini-2.5-flash-preview")?.input == 0.3)
    }

    @Test("match é case-insensitive")
    func caseInsensitive() {
        let table = syntheticTable()
        #expect(table.price(forModel: "Claude-Sonnet-4")?.input == 3)
        #expect(table.price(forModel: "GPT-5-MINI")?.input == 0.25)
    }

    @Test("modelo ausente ou nil → nil (nunca chute)")
    func unknownModelYieldsNilCost() {
        let table = syntheticTable()
        #expect(table.price(forModel: "totally-unknown-llm") == nil)
        #expect(table.costUSD(model: "totally-unknown-llm", inputTokens: 1_000, outputTokens: 1_000, cacheReadTokens: 0, cacheWriteTokens: 0) == nil)
        // Prefixo que casa com NADA não inventa preço de família vizinha.
        #expect(table.price(forModel: "llama-4") == nil)
        #expect(table.costUSD(model: nil, inputTokens: 1_000, outputTokens: 1_000, cacheReadTokens: 0, cacheWriteTokens: 0) == nil)
    }

    // MARK: - Cálculo com tiers de cache

    @Test("custo soma input+output+cache read+cache write (1M tokens = preço cheio)")
    func costWithCacheTiers() {
        let table = syntheticTable()
        // claude-sonnet-4: 3 + 15 + 0.3 + 3.75 = 22.05 USD por 1M em cada tier.
        let cost = table.costUSD(
            model: "claude-sonnet-4-5", inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)
        #expect(abs(cost! - 22.05) < 1e-9)
        // Fracionado: 100k in × $3 + 200k out × $15 = 0.30 + 3.00 = 3.30.
        let frac = table.costUSD(
            model: "claude-sonnet-4", inputTokens: 100_000, outputTokens: 200_000,
            cacheReadTokens: 0, cacheWriteTokens: 0)
        #expect(abs(frac! - 3.30) < 1e-9)
    }

    @Test("tier sem preço público (null) contribui 0, mas custo segue não-nil")
    func nullTierContributesZero() {
        let table = syntheticTable()  // gemini/gpt: cache_write null
        // Só cache write → tier sem preço → 0.0 (não nil: o modelo É precificado).
        let writeOnly = table.costUSD(
            model: "gemini-2.5-flash", inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 500_000)
        #expect(writeOnly == 0)
        // Cache read tem preço: 1M × 0.03 = 0.03.
        let read = table.costUSD(
            model: "gemini-2.5-flash", inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 1_000_000, cacheWriteTokens: 500_000)
        #expect(abs(read! - 0.03) < 1e-9)
    }

    @Test("evento zerado de modelo precificado custa 0.0")
    func zeroTokensCostZero() {
        let table = syntheticTable()
        #expect(table.costUSD(model: "gpt-5", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0) == 0)
    }

    // MARK: - Tabela embutida (Resources/pricing.json)

    @Test("bundled: carrega, versionada, e cobre as famílias dos transcripts")
    func bundledTableCoversTranscriptFamilies() throws {
        let table = try #require(PricingTable.bundled())
        #expect(table.version >= 1)
        #expect(!table.updated.isEmpty)

        // Modelos que aparecem nos transcripts reais (fixtures F2/F3).
        let required = [
            "claude-sonnet-4-6", "claude-opus-4-6",       // claude-* (sufixos dated herdam)
            "gpt-5.2", "gpt-5.3-codex", "gpt-5-codex",    // gpt-*/codex
            "gemini-2.5-flash", "gemini-2.5-pro",         // gemini-2.5-*
            "glm-4.7", "glm-4.7-mcp",                     // glm-* (Z.ai)
        ]
        for model in required {
            #expect(table.price(forModel: model) != nil, "\(model) precisa estar coberto")
        }

        // Sufixos datados das famílias também.
        #expect(table.price(forModel: "claude-sonnet-4-5-20250929") != nil)
        #expect(table.price(forModel: "claude-opus-4-1-20250805") != nil)

        // Valores conferidos nas pricing-pages (amostra por vendor).
        #expect(table.price(forModel: "claude-sonnet-4-6")?.output == 15)
        #expect(table.price(forModel: "gpt-5.2")?.input == 1.75)
        #expect(table.price(forModel: "gemini-2.5-flash")?.cacheRead == 0.03)
        #expect(table.price(forModel: "glm-4.7")?.input == 0.6)

        // Sem preço público confirmado → de fora (custo nil): gpt-5.3 chat não
        // está na pricing-page da OpenAI; gemini-3-pro não está na do Google.
        #expect(table.price(forModel: "made-up-model-9000") == nil)
    }

    @Test("bundled: toda entrada tem fonte pública documentada")
    func bundledEntriesDocumentSources() throws {
        let table = try #require(PricingTable.bundled())
        // Cada preço precisa citar URL + data (contrato do brief). Validação
        // via re-encode: ModelPrice expõe `source` publicamente.
        let models = [
            "claude-opus-4-1", "claude-opus-4", "claude-opus-4-5", "claude-opus-4-6",
            "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
            "claude-sonnet-4", "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-sonnet-5",
            "claude-haiku-4-5",
            "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.2", "gpt-5.2-pro",
            "gpt-5.3-codex", "o3", "o4-mini",
            "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
            "glm-4.5", "glm-4.6", "glm-4.7", "glm-4.7-flash",
            "glm-5", "glm-5.1", "glm-5.2", "glm-5.3",
        ]
        #expect(!models.isEmpty)
        for model in models {
            let price = try #require(table.price(forModel: model), "\(model) ausente da tabela")
            let source = try #require(price.source, "\(model) sem source")
            #expect(source.contains("https://"), "\(model): source precisa citar a URL")
            #expect(source.contains("2026-09-08"), "\(model): source precisa citar a data")
            #expect(price.input != nil && price.output != nil, "\(model): input/output são obrigatórios")
        }
    }

    @Test("bundled faltando/corrompido → nil (degradação, nunca crash)")
    func missingResourceYieldsNil() {
        // Bundle sem pricing.json algum (o runner de testes não o carrega).
        #expect(PricingTable.bundled(in: .main) == nil)
    }
}
