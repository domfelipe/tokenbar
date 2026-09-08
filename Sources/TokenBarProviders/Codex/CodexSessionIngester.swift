import Foundation
import os
import TokenBarCore

/// Ingest local do Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` →
/// `UsageEvent`s (spec §1.5), com o motor incremental da F1 (`TranscriptIngester`
/// + `FileOffsetStore`, apêndice por byte offset).
///
/// Três peças moram aqui: o tracker de `model` (linhas `turn_context` precedem
/// os `token_count` e o model muda no meio do arquivo), o parser tolerante de
/// linha e o wrapper que compõe ambos com o `TranscriptIngester` — o `makeEvent`
/// do padrão F1 (stamp de account/project/model).
///
/// Regra F2-CODEX-DELTA: contagem usa SOMENTE `payload.info.last_token_usage`
/// (delta por evento); `total_token_usage` é cumulativo — somar os dois duplica
/// tudo (verificado: dois eventos consecutivos com last 110→112 e total 110→222).
public struct CodexSessionIngester: Sendable {
    private let ingester: TranscriptIngester
    private let account: AccountID
    private let modelTracker: CodexModelTracker

    public init(account: AccountID, modelTracker: CodexModelTracker) {
        self.account = account
        self.modelTracker = modelTracker
        self.ingester = TranscriptIngester { line, modified in
            CodexLineParser(account: account, modelTracker: modelTracker)
                .parse(line: line, fileModificationDate: modified)
        }
    }

    /// Núcleo streaming da F1 com o `makeEvent` do Codex embutido.
    public func ingestChangedFilesStreaming(
        under directory: URL,
        cursors: [String: FileCursor],
        onEvents: (String, [UsageEvent], Bool, UInt64) throws -> Void
    ) throws -> [FileCursorUpdate] {
        try ingester.ingestChangedFilesStreaming(
            under: directory,
            cursors: cursors,
            makeEvent: stamp,
            onEvents: onEvents
        )
    }

    /// `makeEvent` do padrão F1: stamp de account/project/model. `project` =
    /// diretório do arquivo (padrão F1: `URL.deletingLastPathComponent()
    /// .lastPathComponent` — para o Codex é o dia da árvore YYYY/MM/DD, por
    /// decisão da spec §1.5).
    func stamp(_ event: UsageEvent, path: String) -> UsageEvent {
        var e = event
        e.account = account
        e.project = e.project ?? URL(filePath: path).deletingLastPathComponent().lastPathComponent
        return modelTracker.stamp(e, filePath: path)
    }
}

/// Estado de `model` do último `turn_context` visto (spec §1.5: "model do
/// último turn_context; muda no meio do arquivo"). Classe Sendable com lock
/// (padrão do repo — zero `@unchecked` em código de produção); o ingest é
/// sequencial por provider, o lock é disciplina do compilador + higiene.
///
/// Higiene entre arquivos: `stamp` detecta troca de arquivo; se o model
/// corrente não veio de um `turn_context` do arquivo NOVO (flag de frescor,
/// consumida a cada stamp), o model é limpo em vez de vazar o do arquivo
/// anterior. O parser grava via `record(model:)` ao ver `turn_context`.
public final class CodexModelTracker: Sendable {
    private struct State {
        var path: String?
        var model: String?
        var modelIsFresh = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Parser viu `turn_context` com model: vira o model corrente (fresh).
    public func record(model: String) {
        state.withLock { s in
            s.model = model
            s.modelIsFresh = true
        }
    }

    /// Estampa o model corrente no evento; consome o frescor. Na troca de
    /// arquivo mantém o model só se ele foi gravado por uma linha do novo
    /// arquivo (turn_context antes do 1º token_count — caso típico).
    func stamp(_ event: UsageEvent, filePath: String) -> UsageEvent {
        let model = state.withLock { s -> String? in
            if s.path != filePath {
                s.path = filePath
                if !s.modelIsFresh { s.model = nil }
            }
            s.modelIsFresh = false
            return s.model
        }
        var e = event
        e.model = model
        return e
    }
}

/// Parser tolerante de uma linha de rollout do Codex (spec §1.5).
/// Linhas inválidas/sem uso retornam nil — nunca lançam.
public struct CodexLineParser: Sendable {
    private let account: AccountID
    private let modelTracker: CodexModelTracker

    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()
    // JSONDecoder é Sendable — sem nonisolated(unsafe) necessário.
    private static let decoder = JSONDecoder()

    public init(account: AccountID, modelTracker: CodexModelTracker) {
        self.account = account
        self.modelTracker = modelTracker
    }

    public func parse(line: String, fileModificationDate: Date) -> UsageEvent? {
        // Prefilter barato (padrão F1): a maioria das linhas reais não é
        // token_count nem turn_context — pula antes de decodificar.
        guard line.count <= 5_000_000 else { return nil }
        let hasTurnContext = line.contains("turn_context")
        let hasTokenCount = line.contains("token_count")
        guard hasTurnContext || hasTokenCount,
              let data = line.data(using: .utf8),
              let decoded = try? Self.decoder.decode(RolloutLine.self, from: data)
        else { return nil }

        if hasTurnContext, decoded.type == "turn_context", let model = decoded.payload?.model, !model.isEmpty {
            modelTracker.record(model: model)
        }

        guard hasTokenCount,
              decoded.type == "event_msg",
              decoded.payload?.type == "token_count",
              let usage = decoded.payload?.info?.lastTokenUsage
        else { return nil }

        // Mapeamento spec §1.5: reasoning_output_tokens é SUBCONJUNTO de
        // output_tokens (não soma); total_tokens é checksum (não usa).
        let input = max(0, usage.inputTokens ?? 0)
        let output = max(0, usage.outputTokens ?? 0)
        let cacheRead = max(0, usage.cachedInputTokens ?? 0)
        let cacheWrite = max(0, usage.cacheWriteInputTokens ?? 0)
        // Saneação F1 (Red Team caso 1): contagens absurdas são lixo, não uso.
        let cap: Int64 = 1_000_000_000_000_000
        guard input <= cap, output <= cap, cacheRead <= cap, cacheWrite <= cap,
              TokenSums(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite).total > 0
        else { return nil }

        // Timestamp ausente → mtime do arquivo; presente e inválido → nil.
        let ts: Date
        if let raw = decoded.timestamp {
            guard let parsed = ClaudeLineParser.fastISO8601(raw)
                ?? Self.iso8601Fractional.date(from: raw)
                ?? Self.iso8601.date(from: raw)
            else { return nil }
            ts = parsed
        } else {
            ts = fileModificationDate
        }

        // model/project/account são estampados no `makeEvent` (stamp), que tem
        // o path — o parser não sabe de que arquivo a linha veio.
        return UsageEvent(
            ts: ts, provider: .codex, account: account, model: nil,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            project: nil
        )
    }

    /// Envelope comum das linhas de rollout: `{ timestamp, type, payload }`.
    /// Payload é decodificado sob demanda (só os campos que interessam) —
    /// chaves extras (`rate_limits`, `context_window`, `cwd`, …) são ignoradas.
    private struct RolloutLine: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            timestamp = FlexibleJSON.string(c, "timestamp")
            type = FlexibleJSON.string(c, "type")
            payload = (try? c.decodeIfPresent(Payload.self, forKey: AnyKey("payload"))) ?? nil
        }

        struct Payload: Decodable {
            let type: String?
            let model: String?   // turn_context
            let info: Info?      // token_count

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                type = FlexibleJSON.string(c, "type")
                model = FlexibleJSON.string(c, "model")
                info = (try? c.decodeIfPresent(Info.self, forKey: AnyKey("info"))) ?? nil
            }

            struct Info: Decodable {
                /// F2-CODEX-DELTA: ÚNICA fonte de contagem. `total_token_usage`
                /// existe no arquivo e é propositalmente ignorado (cumulativo).
                let lastTokenUsage: LastUsage?

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: AnyKey.self)
                    lastTokenUsage = (try? c.decodeIfPresent(
                        LastUsage.self, forKey: AnyKey("last_token_usage")
                    )) ?? nil
                }

                struct LastUsage: Decodable {
                    let inputTokens: Int64?
                    let cachedInputTokens: Int64?
                    let cacheWriteInputTokens: Int64?
                    let outputTokens: Int64?
                    // reasoning_output_tokens: subconjunto de output_tokens.
                    // total_tokens: checksum.

                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: AnyKey.self)
                        inputTokens = FlexibleJSON.int64(c, "input_tokens", "inputTokens")
                        cachedInputTokens = FlexibleJSON.int64(c, "cached_input_tokens", "cachedInputTokens")
                        cacheWriteInputTokens = FlexibleJSON.int64(c, "cache_write_input_tokens", "cacheWriteInputTokens")
                        outputTokens = FlexibleJSON.int64(c, "output_tokens", "outputTokens")
                    }
                }
            }
        }
    }
}
