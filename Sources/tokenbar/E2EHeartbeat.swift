import Foundation
import TokenBarCore

/// Ancoragem de teste E2E: escreve estado vivo só quando TOKENBAR_E2E_DIR está setado.
/// Conteúdo: somas e string de exibição — nunca paths nem conteúdo de transcript.
enum E2EHeartbeat {
    static func write(menuBarText: String, totals: [ProviderID: Int64], directory: URL) {
        // JSONSerialization só aceita chaves String — ProviderID vira rawValue
        // (com chaves enum o try? engoliria o erro e o state.json nunca apareceria).
        let todayTokens = totals.reduce(into: [String: Int64]()) { $0[$1.key.rawValue] = $1.value }
        let payload: [String: Any] = [
            "menuBarText": menuBarText,
            "todayTokens": todayTokens,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
}
