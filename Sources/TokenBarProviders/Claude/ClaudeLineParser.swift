import Foundation
import TokenBarCore

/// Parser tolerante de uma linha de transcript do Claude Code.
/// Linhas inválidas/sem uso retornam nil — nunca lançam.
public struct ClaudeLineParser: Sendable {
    private let account: AccountID
    private let project: String?

    // ISO8601DateFormatter é thread-safe para parse; nonisolated(unsafe) pois
    // Foundation não anota Sendable, mas o uso é só-leitura.
    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    public init(account: AccountID, project: String?) {
        self.account = account
        self.project = project
    }

    public func parse(line: String, fileModificationDate: Date) -> UsageEvent? {
        guard line.count <= 5_000_000,
              let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ClaudeTranscriptLine.self, from: data),
              decoded.type == "assistant",
              let usage = decoded.message?.usage
        else { return nil }

        let input = max(0, usage.input_tokens ?? 0)
        let output = max(0, usage.output_tokens ?? 0)
        let cacheRead = max(0, usage.cache_read_input_tokens ?? 0)
        let cacheWrite = max(0, usage.cache_creation_input_tokens ?? 0)
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        // Timestamp ausente -> fallback para mtime do arquivo.
        // Timestamp presente porém inválido -> nil (contrato: "timestamp inválido" => nil).
        let ts: Date
        if let raw = decoded.timestamp {
            guard let parsed = Self.iso8601Fractional.date(from: raw) ?? Self.iso8601.date(from: raw) else {
                return nil
            }
            ts = parsed
        } else {
            ts = fileModificationDate
        }

        return UsageEvent(
            ts: ts, provider: .claude, account: account,
            model: decoded.message?.model,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            project: project
        )
    }
}
