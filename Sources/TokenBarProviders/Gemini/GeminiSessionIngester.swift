import Foundation
import TokenBarCore

/// Ingest local do Gemini CLI: `~/.gemini/tmp/<projeto>/chats/session-*.jsonl`
/// → `UsageEvent`s (spec F2 §3), com o motor incremental da F1
/// (`TranscriptIngester` + `FileOffsetStore`, apêndice por byte offset).
///
/// Duas peças moram aqui: o parser tolerante da linha e o wrapper que o compõe
/// com o `TranscriptIngester` (o `makeEvent` do padrão F1: stamp de
/// account/project). O DEDUPE por `id` não mora aqui — o parser é stateless
/// por linha; o provider decide o drop no `onEvents` (onde há path E lote),
/// consultando o `GeminiDedupe` semeado pelo cursor (ver `GeminiProvider`).
public struct GeminiSessionIngester: Sendable {
    private let ingester: TranscriptIngester
    private let account: AccountID

    public init(account: AccountID) {
        self.account = account
        self.ingester = TranscriptIngester { line, modified in
            GeminiLineParser(account: account).parse(line: line, fileModificationDate: modified)
        }
    }

    /// Núcleo streaming da F1 com o `makeEvent` do Gemini embutido.
    public func ingestChangedFilesStreaming(
        under directory: URL,
        cursors: [String: FileCursor],
        onEvents: (String, [UsageEvent], Bool) throws -> Void
    ) throws -> [FileCursorUpdate] {
        try ingester.ingestChangedFilesStreaming(
            under: directory,
            cursors: cursors,
            makeEvent: stamp,
            onEvents: onEvents
        )
    }

    /// `makeEvent` do padrão F1: stamp de account/project. O model NÃO é
    /// estampado aqui — no Gemini ele vem na própria linha (parser), não de um
    /// `turn_context` posicional como no Codex.
    ///
    /// `project` = diretório `<projeto>` de `~/.gemini/tmp/<projeto>/chats/
    /// session-*.jsonl` (spec §3.5) — o AVÔ do arquivo. O padrão F1
    /// (`deletingLastPathComponent`) daria "chats"; aqui são dois níveis.
    func stamp(_ event: UsageEvent, path: String) -> UsageEvent {
        var e = event
        e.account = account
        e.project = e.project ?? URL(filePath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        return e
    }
}

/// Parser tolerante de uma linha de sessão do Gemini CLI (spec F2 §3.3).
///
/// O arquivo mistura DOIS formatos de linha e só um gera evento:
/// - **Linha-raiz** `{type, id, timestamp, content, model?, tokens?}` — só
///   `type == "gemini"` tem `tokens`; `user`/`info` (e a meta `kind:"main"`)
///   viram nil. `content` é string nas `gemini`/`info` e array nas `user` —
///   irrelevante p/ contagem, NUNCA decodificado.
/// - **Delta `$set`** — espelha mensagens sem tokens; sem `type` no topo,
///   rejeitado antes de qualquer custo.
///
/// Mapeamento F2-GEMINI-FIELDS (tokens REAIS, sem estimativa):
/// `inputTokens = tokens.input`; `outputTokens = output + thoughts + tool`
/// (tudo que o modelo gerou — no Claude/Codex o output já engloba reasoning);
/// `cacheReadTokens = tokens.cached`; `cacheWriteTokens = 0`. `tokens.total`
/// é só checksum (`input+output+thoughts+tool`): divergência aceita os
/// componentes e segue — nunca trava o ingest nem usa o total sozinho.
public struct GeminiLineParser: Sendable {
    private let account: AccountID

    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()
    // JSONDecoder é Sendable — sem nonisolated(unsafe) necessário.
    private static let decoder = JSONDecoder()

    public init(account: AccountID) {
        self.account = account
    }

    public func parse(line: String, fileModificationDate: Date) -> UsageEvent? {
        // Prefilter barato: linha-raiz com tokens sempre contém "tokens";
        // metas, `user`, `info` e `$set` caem fora antes de decodificar.
        guard line.count <= 5_000_000, line.contains("tokens"),
              let data = line.data(using: .utf8),
              let decoded = try? Self.decoder.decode(SessionLine.self, from: data)
        else { return nil }

        guard decoded.type == "gemini",
              let id = decoded.id, !id.isEmpty,
              let tokens = decoded.tokens
        else { return nil }

        // F2-GEMINI-FIELDS: componentes, não o total (checksum). A composição
        // do output é SATURANTE (Red Team F2 caso 1: campos ~Int64.max com `+`
        // comum trapavam aqui, antes do saneamento de baixo).
        let input = max(0, tokens.input ?? 0)
        let thoughts = max(0, tokens.thoughts ?? 0)
        let tool = max(0, tokens.tool ?? 0)
        let output = TokenSums.saturatingSum(
            TokenSums.saturatingSum(max(0, tokens.output ?? 0), thoughts),
            tool
        )
        let cacheRead = max(0, tokens.cached ?? 0)
        let cacheWrite: Int64 = 0

        // Saneação F1 (padrão Codex): contagens absurdas são lixo, não uso.
        let cap: Int64 = 1_000_000_000_000_000
        guard input <= cap, output <= cap, cacheRead <= cap,
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

        return UsageEvent(
            ts: ts, provider: .gemini, account: account,
            model: decoded.model.isEmpty ? nil : decoded.model,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            project: nil,
            dedupeID: id
        )
    }

    /// Linha-raiz da sessão. Só os campos que interessam — `content` (string
    /// OU array, conforme o tipo), `thoughts`, `toolCalls`, `kind`, `sessionId`
    /// e chaves de `$set` são ignorados sem quebrar o decode.
    private struct SessionLine: Decodable {
        let type: String
        let id: String?
        let timestamp: String?
        let model: String
        let tokens: Tokens?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            type = FlexibleJSON.string(c, "type") ?? ""
            id = FlexibleJSON.string(c, "id")
            timestamp = FlexibleJSON.string(c, "timestamp")
            model = FlexibleJSON.string(c, "model") ?? ""
            tokens = (try? c.decodeIfPresent(Tokens.self, forKey: AnyKey("tokens"))) ?? nil
        }

        struct Tokens: Decodable {
            let input: Int64?
            let output: Int64?
            let cached: Int64?
            let thoughts: Int64?
            let tool: Int64?
            // `total`: checksum (input+output+thoughts+tool) — de propósito
            // não decodificado: o split vem dos componentes (spec §3.4).

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                input = FlexibleJSON.int64(c, "input")
                output = FlexibleJSON.int64(c, "output")
                cached = FlexibleJSON.int64(c, "cached")
                thoughts = FlexibleJSON.int64(c, "thoughts")
                tool = FlexibleJSON.int64(c, "tool")
            }
        }
    }
}
