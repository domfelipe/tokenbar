import Foundation

/// Parsing de datas dos payloads F5 (Tasks 4–5): a referência MIT usa ISO8601
/// COM e SEM fração de segundo (Cursor billingCycle*, Antigravity resetTime,
/// Grok period end) e epoch em s ou ms (Alibaba OneConsole). Tolerante: string
/// nula/malformada → `nil` — janela segue sem reset, nunca dado inventado.
enum UsageDates {
    /// ISO8601DateFormatter é thread-safe (docs Apple) — compartilhado como o
    /// JSONDecoder dos parsers (mesmo padrão `nonisolated(unsafe)` do repo).
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    /// ISO8601 com fallback sem fração ("2026-09-10T12:00:00.000Z" e
    /// "2026-09-10T12:00:00Z").
    static func iso8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    /// Número epoch (SEGUNDOS ou MILISSEGUNDOS — ≥1e12 vira ms) ou ISO8601
    /// (padrão OneConsole da referência Alibaba).
    static func epochOrISO(_ raw: Double?) -> Date? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw >= 1_000_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    /// Formatos de data do OneConsole (referência Alibaba): ISO8601 ou
    /// "yyyy-MM-dd[ HH:mm[:ss]]" em UTC.
    static func oneConsole(_ raw: String?) -> Date? {
        guard let iso = iso8601(raw) else {
            guard let raw, !raw.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: raw) { return date }
            }
            return nil
        }
        return iso
    }
}
