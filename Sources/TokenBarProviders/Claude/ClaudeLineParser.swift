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
    // Decoder reutilizado: criar um JSONDecoder por linha custa caro em corpus
    // grande (Red Team caso 2) — o uso é single-thread no ingest.
    private nonisolated(unsafe) static let decoder = JSONDecoder()

    /// ISO8601 "yyyy-MM-ddTHH:mm:ss[.frac][Z|±HH:MM]" parseado à mão: ~0,06 µs
    /// vs ~30 µs do ISO8601DateFormatter — o formatter dominava o ingest de
    /// corpus grande (Red Team caso 2: 1M linhas = 30 s só de timestamp).
    /// Qualquer forma fora do padrão cai no formatter (fallback de tolerância).
    static func fastISO8601(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 20 else { return nil }
        func digit(_ i: Int) -> Int? {
            let v = b[i]
            return v >= 48 && v <= 57 ? Int(v - 48) : nil
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116, b[13] == 58, b[16] == 58,
              let year = digit(0).map({ $0 * 1000 + digit(1)! * 100 + digit(2)! * 10 + digit(3)! }),
              let month = digit(5).map({ $0 * 10 + digit(6)! }), (1...12).contains(month),
              let day = digit(8).map({ $0 * 10 + digit(9)! }),
              let hour = digit(11).map({ $0 * 10 + digit(12)! }), hour <= 23,
              let minute = digit(14).map({ $0 * 10 + digit(15)! }), minute <= 59,
              let second = digit(17).map({ $0 * 10 + digit(18)! }), second <= 60
        else { return nil }
        // dias por mês com ano bissexto (paridade com o formatter)
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard day <= daysInMonth else { return nil }

        var i = 19
        var fraction = 0.0
        if b.count > i, b[i] == 46 {
            i += 1
            var scale = 0.1
            var sawDigit = false
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                fraction += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
                sawDigit = true
            }
            guard sawDigit else { return nil }
        }

        var offsetSeconds = 0
        if i < b.count, b[i] == 90 || b[i] == 122 {
            i += 1
        } else if i + 5 < b.count, b[i] == 43 || b[i] == 45, b[i + 3] == 58,
                  let oh1 = digit(i + 1), let oh2 = digit(i + 2), let om1 = digit(i + 4), let om2 = digit(i + 5) {
            let sign = b[i] == 43 ? 1 : -1
            offsetSeconds = sign * (oh1 * 10 + oh2) * 3600 + sign * (om1 * 10 + om2) * 60
            i += 6
        } else {
            return nil
        }
        guard i == b.count else { return nil }

        // dias desde a época (algoritmo days-from-civil, Howard Hinnant)
        func daysFromCivil(_ y0: Int, _ m0: Int, _ dd: Int) -> Int {
            var y = y0
            let m = m0
            if m <= 2 { y -= 1 }
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + dd - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097 + doe - 719_468
        }
        let epoch = Double(daysFromCivil(year, month, day)) * 86_400
            + Double(hour * 3600 + minute * 60 + second - offsetSeconds)
            + fraction
        return Date(timeIntervalSince1970: epoch)
    }

    public init(account: AccountID, project: String?) {
        self.account = account
        self.project = project
    }

    public func parse(line: String, fileModificationDate: Date) -> UsageEvent? {
        // Prefilter barato: só linhas de assistant com usage podem virar evento
        // (substrings simples, agnósticas a espaçamento do JSON). Transcripts
        // reais têm maioria de linhas user/progress — pula o decode delas.
        guard line.count <= 5_000_000,
              line.contains("assistant"),
              line.contains("usage"),
              let data = line.data(using: .utf8),
              let decoded = try? Self.decoder.decode(ClaudeTranscriptLine.self, from: data),
              decoded.type == "assistant",
              let usage = decoded.message?.usage
        else { return nil }

        let input = max(0, usage.input_tokens ?? 0)
        let output = max(0, usage.output_tokens ?? 0)
        let cacheRead = max(0, usage.cache_read_input_tokens ?? 0)
        let cacheWrite = max(0, usage.cache_creation_input_tokens ?? 0)
        // Red Team F1 (caso 1): contagens > 10^15 por campo são lixo (não uso real;
        // contextos reais ficam na casa de milhões) e antes estouravam a soma do
        // guard com SIGTRAP. Saneia: rejeita a linha em vez de derrubar o app.
        let cap: Int64 = 1_000_000_000_000_000
        guard input <= cap, output <= cap, cacheRead <= cap, cacheWrite <= cap,
              TokenSums(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite).total > 0
        else { return nil }

        // Timestamp ausente -> fallback para mtime do arquivo.
        // Timestamp presente porém inválido -> nil (contrato: "timestamp inválido" => nil).
        let ts: Date
        if let raw = decoded.timestamp {
            guard let parsed = Self.fastISO8601(raw)
                ?? Self.iso8601Fractional.date(from: raw)
                ?? Self.iso8601.date(from: raw)
            else { return nil }
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
