import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

/// Red Team F2 caso 1 — fuzz determinístico dos 3 parsers de linha (Claude,
/// Codex, Gemini) + dos 2 decoders de API (Codex `wham/usage`, Z.ai
/// `quota/limit`).
///
/// Contrato (spec §5/§9): entrada hostil NUNCA crasha (o teste passar = sem
/// trap/SIGTRAP) e nunca inventa evento — no máximo rejeita a linha. A linha
/// de controle legítima de CADA parser roda antes e depois da bateria: se o
/// parser corromper estado com lixo, o controle deixa de contar.
///
/// Bateria: todos os bytes 0x00–0xFF (isolados e embutidos em JSON válido),
/// JSON profundo (50k níveis), linha de ~5 MB, `1e999`/Int64.max/min/negativos
/// em cada campo numérico, números como string/float/bool/null, envelopes com
/// tipos errados, JSON truncado, chaves duplicadas, unicode hostil (RTL
/// override, combining, emoji, NUL) e timestamps inválidos. Profundidade
/// extrema (200k) fica na rodada runtime (selfcheck, processo separado).
@Suite(.serialized)
final class ParserFuzzTests {
    static let mtime = Date(timeIntervalSince1970: 1_788_000_000)

    let claude = ClaudeLineParser(
        account: AccountID(provider: .claude, key: "fuzz"), project: nil
    )
    let codex = CodexLineParser(
        account: AccountID(provider: .codex, key: "fuzz"),
        modelTracker: CodexModelTracker()
    )
    let gemini = GeminiLineParser(
        account: AccountID(provider: .gemini, key: "fuzz")
    )

    /// Roda UMA linha nos 3 parsers. Retorno só para o compilador — o contrato
    /// é "não crasha"; asserts de valor ficam nos testes de controle.
    @discardableResult
    func runAll(_ line: String) -> (Bool, Bool, Bool) {
        let c = claude.parse(line: line, fileModificationDate: Self.mtime)
        let x = codex.parse(line: line, fileModificationDate: Self.mtime)
        let g = gemini.parse(line: line, fileModificationDate: Self.mtime)
        return (c != nil, x != nil, g != nil)
    }

    // MARK: - Controles (legítimo continua contando antes e depois do lixo)

    static let controlClaude =
        #"{"type":"assistant","timestamp":"2026-09-07T12:00:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}"#
    static let controlCodex =
        #"{"timestamp":"2026-09-07T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":10,"cache_write_input_tokens":5,"output_tokens":60}}}}"#
    static let controlGemini =
        #"{"type":"gemini","id":"ctrl-1","timestamp":"2026-09-07T12:00:00.000Z","content":"ok","model":"gemini-2.5-flash","tokens":{"input":7,"output":8,"cached":9,"thoughts":2,"tool":1,"total":27}}"#

    @Test func controlLinesParseBeforeAndAfterBattery() {
        func controls() -> (Int64, Int64, Int64) {
            let c = claude.parse(line: Self.controlClaude, fileModificationDate: Self.mtime)!
            let x = codex.parse(line: Self.controlCodex, fileModificationDate: Self.mtime)!
            let g = gemini.parse(line: Self.controlGemini, fileModificationDate: Self.mtime)!
            return (c.inputTokens, x.inputTokens, g.inputTokens)
        }
        let before = controls()
        #expect(before == (10, 100, 7))
        battery()
        let after = controls()
        #expect(after == (10, 100, 7), "parser corrompido pelo lixo deixou de contar linha legítima")
    }

    /// O corpo da bateria, reaproveitado pelo teste de controle (estado dos
    /// parsers tem de sobreviver a tudo isso e seguir contando).
    func battery() {
        // Bytes 0x00–0xFF isolados e embutidos num envelope Claude válido.
        for v: UInt8 in 0...255 {
            runAll(String(decoding: [v], as: UTF8.self))
            runAll(String(decoding: [v], as: UTF8.self) + Self.controlClaude)
            runAll(Self.controlClaude + String(decoding: [v], as: UTF8.self))
        }
        // Bytes crus dentro dos campos de string dos 3 formatos.
        let junk = String(decoding: (0...255).map { UInt8($0) }, as: UTF8.self)
        runAll(#"{"type":"assistant","timestamp":"2026-09-07T12:00:00.000Z","message":{"model":"\#(junk)","usage":{"input_tokens":1,"output_tokens":2}}}"#)
        runAll(#"{"type":"gemini","id":"\#(junk)","timestamp":"2026-09-07T12:00:00.000Z","tokens":{"input":1,"output":2}}"#)

        // JSON profundo (50k níveis — 200k fica na rodada runtime).
        runAll(String(repeating: "[", count: 50_000))
        runAll(String(repeating: "[", count: 50_000) + Self.controlClaude)
        runAll(#"{"a":"# + String(repeating: "[", count: 25_000) + String(repeating: "]", count: 25_000) + "}")

        // Linha ~5 MB (no limiar do prefilter) com keywords dos 3 prefilters.
        let big = String(repeating: "a", count: 5_000_000)
        runAll(#"{"type":"assistant","usage":"# + big)
        runAll(#"{"type":"event_msg","payload":{"type":"token_count","x":"# + big + "}}")
        runAll(#"{"type":"gemini","tokens":"# + big)
        runAll(big + "tokens" + big)  // passa no prefilter do Codex/Gemini só pelo keyword

        // 1e999 / enormes / negativos / tipos errados em cada campo numérico.
        for field in ["input_tokens", "output_tokens", "cache_read_input_tokens",
                      "cache_creation_input_tokens", "cached_input_tokens",
                      "cache_write_input_tokens", "input", "output", "cached",
                      "thoughts", "tool", "used_percent", "percentage", "code"] {
            runAll(
                #"{"type":"assistant","timestamp":"2026-09-07T12:00:00.000Z","message":{"usage":{"\#(field)":1e999,"input_tokens":1,"output_tokens":2}}}"#
            )
            runAll(
                #"{"type":"gemini","id":"g","timestamp":"2026-09-07T12:00:00.000Z","tokens":{"\#(field)":1e999,"input":1,"output":2}}"#
            )
            runAll(
                #"{"timestamp":"2026-09-07T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"\#(field)":1e999,"input_tokens":1,"output_tokens":2}}}}"#
            )
            for value in ["9223372036854775807", "9223372036854775808",
                          "-9223372036854775808", "-1e999", "\"1e999\"",
                          "9e999", "1.5", "true", "null", "[]", "{}"] {
                runAll(
                    #"{"type":"assistant","message":{"usage":{"input_tokens":\#(value),"output_tokens":\#(value),"cache_read_input_tokens":\#(value),"cache_creation_input_tokens":\#(value)}}}"#
                )
                runAll(
                    #"{"type":"gemini","id":"g","tokens":{"input":\#(value),"output":\#(value),"cached":\#(value),"thoughts":\#(value),"tool":\#(value)}}"#
                )
                runAll(
                    #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(value),"output_tokens":\#(value),"cached_input_tokens":\#(value),"cache_write_input_tokens":\#(value)}}}}"#
                )
            }
        }

        // Int64.max em TODOS os componentes de uma vez (o trap original do
        // Gemini era a composição output+thoughts+tool antes da saturação).
        let m = Int64.max
        runAll(
            #"{"type":"gemini","id":"g","timestamp":"2026-09-07T12:00:00.000Z","tokens":{"input":\#(m),"output":\#(m),"cached":\#(m),"thoughts":\#(m),"tool":\#(m),"total":\#(m)}}"#
        )

        // Envelope com tipos errados / truncado / chaves duplicadas.
        runAll(#"{"type":42,"message":"string","usage":[1,2,3]}"#)
        runAll(#"{"type":{"nested":"obj"},"tokens":"string","payload":7}"#)
        runAll(Self.controlClaude.dropLast(40).description)
        runAll(Self.controlGemini.dropLast(30).description)
        runAll(#"{"type":"assistant","type":"event_msg","message":{"message":{"usage":{"input_tokens":1,"input_tokens":1e999,"output_tokens":2}}}}"#)

        // Unicode hostil em todos os campos de string + timestamp.
        let hostile = "\u{202E}spoof\u{0301}\u{0308}\u{1F600}\u{10FFFF}\u{0000}nul"
        runAll(
            #"{"type":"assistant","timestamp":"\#(hostile)","message":{"model":"\#(hostile)","usage":{"input_tokens":1,"output_tokens":2}}}"#
        )
        runAll(
            #"{"type":"gemini","id":"\#(hostile)","timestamp":"\#(hostile)","model":"\#(hostile)","tokens":{"input":1,"output":2}}"#
        )

        // Timestamps hostis (presentes mas inválidos → nil; nunca crash).
        for ts in ["not-a-date", "9999-99-99T99:99:99Z", "2026-13-45T00:00:00Z",
                   "2026-02-30T00:00:00Z", "", "2026-09-07T12:00:00+99:00",
                   "2026-09-07", "0", "-999999999999999999999"] {
            runAll(
                #"{"type":"assistant","timestamp":"\#(ts)","message":{"usage":{"input_tokens":1,"output_tokens":2}}}"#
            )
            runAll(
                #"{"type":"gemini","id":"g","timestamp":"\#(ts)","tokens":{"input":1,"output":2}}"#
            )
        }
    }

    // MARK: - Decoders de API (Codex wham/usage, Z.ai quota/limit)

    /// Red Team T8 (P1, achado NOVO da bateria): `Int(Double)` TRAPA (SIGTRAP)
    /// fora do range de Int — `number: 1e300` (Z.ai windowLabel) e
    /// `limit_window_seconds: ±1e300` (Codex kindAndLabel) derrubavam o app
    /// com API hostil/bugada. `1e999` não bastava: é não-finito e já era
    /// rejeitado; o vetor são valores FINITOS gigantes. Fix: FlexibleJSON só
    /// finito + saturação antes de toda conversão Int(Double).
    @Test func finiteHugeDoublesDoNotTrapIntConversions() throws {
        let decoder = JSONDecoder()
        // Z.ai: number gigante + percentage válida (janela é criada → label
        // é calculado → era o ponto do trap).
        let zai = try decoder.decode(
            ZaiQuotaResponse.self,
            from: Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":50,"number":1e300,"nextResetTime":1e300}]}}"#.utf8)
        )
        let window = zai.limits.compactMap(ZaiProvider.mapWindow).first
        #expect(window?.label != nil, "janela com number gigante precisa mapear sem trap")

        // Codex: limit_window_seconds gigante positivo (branch weekly) e
        // negativo enorme (branch session) — os dois trapavam.
        for seconds in ["1e300", "-1e300", "1e308", "-1e308"] {
            let codex = try decoder.decode(
                CodexUsageResponse.self,
                from: Data(#"{"rate_limit":{"primary_window":{"used_percent":42,"reset_at":9999999999,"limit_window_seconds":\#(seconds)}}}"#.utf8)
            )
            let window = CodexProvider.mapWindow(codex.primaryWindow, fallback: (.session, "5h"))
            #expect(window != nil, "janela com limit_window_seconds \(seconds) precisa mapear sem trap")
        }
    }

    @Test func codexAPIDecoderSurvivesHostilePayloads() throws {
        let decoder = JSONDecoder()
        for payload in hostileAPIPayloads(field: "used_percent") {
            let decoded = try? decoder.decode(CodexUsageResponse.self, from: payload)
            // Mapeamento para janela: fração satura em 0...1 mesmo com absurdo.
            if let window = decoded.flatMap({ CodexProvider.mapWindow($0.primaryWindow, fallback: (.session, "5h")) }),
               let fraction = window.usedFraction {
                #expect((0.0...1.0).contains(fraction), "used_percent hostil virou fração fora de 0...1")
            }
        }
        // Controle: shape canônico continua mapeando 42%.
        let ok = try decoder.decode(
            CodexUsageResponse.self,
            from: Data(#"{"rate_limit":{"primary_window":{"used_percent":42,"reset_at":9999999999,"limit_window_seconds":18000}}}"#.utf8)
        )
        let window = CodexProvider.mapWindow(ok.primaryWindow, fallback: (.session, "5h"))
        #expect(window?.usedFraction == 0.42)
    }

    @Test func zaiAPIDecoderSurvivesHostilePayloads() throws {
        let decoder = JSONDecoder()
        for payload in hostileAPIPayloads(field: "percentage") {
            let decoded = try? decoder.decode(ZaiQuotaResponse.self, from: payload)
            for window in (decoded?.limits ?? []).compactMap(ZaiProvider.mapWindow) {
                if let fraction = window.usedFraction {
                    #expect((0.0...1.0).contains(fraction), "percentage hostil virou fração fora de 0...1")
                }
                if let resetsAt = window.resetsAt {
                    #expect(resetsAt.timeIntervalSince1970.isFinite, "nextResetTime hostil virou data não-finita")
                }
            }
        }
        // Controle: shape canônico continua virando janela 81%.
        let ok = try decoder.decode(
            ZaiQuotaResponse.self,
            from: Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":81,"nextResetTime":9999999999999}]}}"#.utf8)
        )
        let window = ok.limits.compactMap(ZaiProvider.mapWindow).first
        #expect(window?.usedFraction == 0.81)
    }

    /// Payloads hostis comuns aos 2 decoders: o campo de percentual vem em cada
    /// tipo errado; o envelope inteiro vem em formas fora do contrato.
    func hostileAPIPayloads(field: String) -> [Data] {
        let values = ["1e999", "-1e999", "9e999", "\"1e999\"", "9223372036854775808",
                      "-9223372036854775808", "true", "null", "[]", "{}", "NaN", "Infinity"]
        var payloads = values.map {
            Data(#"{"rate_limit":{"primary_window":{"\#(field)":\#($0)}},"data":{"limits":[{"percentage":\#($0),"nextResetTime":\#($0)}]}}"#.utf8)
        }
        payloads += [
            Data("[".utf8), Data("null".utf8), Data("{}".utf8),
            Data(String(repeating: "[", count: 50_000).utf8),
            Data(#"{"rate_limit":[1,2,3],"data":{"limits":"string"}}"#.utf8),
            Data(#"{"data":{"limits":[1,"dois",null,{},{"percentage":50}]}}"#.utf8),
            Data(#"{"success":{"a":1},"code":[200],"msg":"x"}"#.utf8),
            Data((#"{"junk":""# + String(repeating: "a", count: 3_000_000) + #""}"#).utf8),
        ]
        return payloads
    }
}
