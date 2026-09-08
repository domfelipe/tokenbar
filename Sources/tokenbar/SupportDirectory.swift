import Foundation

/// Resolve a support directory (F3 Task 4): `TOKENBAR_SUPPORT_DIR` (e2e/testes)
/// vence; sem override, `~/Library/Application Support/TokenBar`. Cria o
/// diretório se faltar (mesmo comportamento que o AppState sempre teve).
///
/// Fonte ÚNICA da regra — o `history` CLI e o app de menu bar têm que abrir o
/// MESMO `tokenbar.sqlite`; duplicar a lógica permitiria os dois caminhos
/// divergirem (o CLI leria outro banco silenciosamente).
enum SupportDirectory {
    static func resolve(environment: [String: String]) -> URL {
        let url = environment["TOKENBAR_SUPPORT_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
