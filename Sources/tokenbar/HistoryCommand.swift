import Foundation
import TokenBarCore

/// Subcomando `tokenbar history` (F3 Task 4): lê o MESMO banco da UI e imprime
/// a série diária agregada (dia, provider, tokens, custo estimado) no stdout.
///
/// Contrato (brief T4):
/// - `tokenbar history [--days N] [--provider P] [--format csv|json]` —
///   padrão 7 dias, todos os providers, csv.
/// - CSV no formato do `HistorySeriesFormat` (header + linhas, LF); JSON é
///   array de `{day, provider, tokens, costUsd|null}`.
/// - Sem banco ou sem dados → só o header no CSV e `[]` no JSON, exit 0
///   (janela vazia NÃO é erro — o aviso, quando há, vai no STDERR para não
///   poluir o stdout, que é contrato puro).
/// - NUNCA toca credencial: não constrói providers nem lê keychain/arquivos de
///   auth — abre só o SQLite (as migrations idempotentes na abertura são a
///   única escrita possível, a mesma que o app faria no próximo launch).
/// - `--days`/`--format`/`--provider` inválidos → usage no STDERR, exit 2.
enum HistoryCommand {
    static let usage = """
        usage: tokenbar history [--days N] [--provider P] [--format csv|json]

        Prints the aggregated daily series (day, provider, tokens, estimated
        cost) from the TokenBar database — the same source the panel and the
        analytics view read.

        options:
          --days N        window in days ending today (default 7, minimum 1)
          --provider P    filter one provider (claude, codex, gemini, zai, ...)
          --format FMT    csv (default) or json
          -h, --help      show this help

        The database lives in TOKENBAR_SUPPORT_DIR (e2e/tests) or
        ~/Library/Application Support/TokenBar/tokenbar.sqlite. With no
        database or no data the CSV is header-only and the JSON is [] —
        exit 0.
        """

    static func run(arguments: [String]) -> Int32 {
        var days = 7
        var provider: ProviderID?
        var format = "csv"

        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--days", "--provider", "--format":
                index += 1
                guard index < arguments.count else {
                    return fail("flag \(flag) requires a value")
                }
                let value = arguments[index]
                switch flag {
                case "--days":
                    guard let parsed = Int(value), parsed >= 1 else {
                        return fail("--days expects an integer >= 1 (got: \(value))")
                    }
                    days = parsed
                case "--provider":
                    guard let parsed = ProviderID(rawValue: value) else {
                        return fail("""
                            unknown provider: \(value) \
                            (valid: \(ProviderID.allCases.map(\.rawValue).joined(separator: ", ")))
                            """)
                    }
                    provider = parsed
                default:
                    guard value == "csv" || value == "json" else {
                        return fail("--format expects csv or json (got: \(value))")
                    }
                    format = value
                }
            case "--help", "-h":
                print(usage)
                return 0
            default:
                return fail("unknown argument: \(flag)")
            }
            index += 1
        }

        // Mesma query da UI (dailySeries, janela calendar-safe) — processo CLI
        // é síncrono, sem MainActor envolvida. Abertura FALHA (arquivo
        // corrompido, permissão, disco) → degradação honesta: saída vazia,
        // aviso no STDERR, exit 0 — o banco nunca derruba o CLI (mesmo
        // princípio do app: persistência é aditiva, nunca condição de crash).
        let databaseURL = SupportDirectory.resolve(
            environment: ProcessInfo.processInfo.environment
        ).appendingPathComponent(AppDatabase.databaseName)

        var rows: [AppDatabase.DailySeriesRow] = []
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                let database = try AppDatabase.open(at: databaseURL)
                rows = try database.dailySeries(provider: provider, days: days)
            } catch {
                fputs("tokenbar history: database unavailable, printing empty history\n", stderr)
            }
        }

        switch format {
        case "csv":
            fputs(HistorySeriesFormat.csv(from: rows), stdout)  // já termina em LF
        default:  // "json" — validado no parse
            let data = (try? HistorySeriesFormat.json(from: rows)) ?? Data("[]".utf8)
            fputs(String(decoding: data, as: UTF8.self) + "\n", stdout)
        }
        return 0
    }

    /// Erro de uso: mensagem + usage no STDERR, exit 2 (stdout intocado).
    static func fail(_ message: String) -> Int32 {
        fputs("tokenbar history: \(message)\n\n\(usage)\n", stderr)
        return 2
    }
}
