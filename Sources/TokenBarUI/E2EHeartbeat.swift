import Foundation
import TokenBarCore

/// Ancoragem de teste E2E/diagnóstico: estado vivo por provider — nunca paths
/// nem conteúdo de transcript/credencial (spec §9).
///
/// Formato v2 (F2): `{"menuBarText", "providers": {provider: {"menuBar",
/// "percent", "todayTokens", "authState", "fetchedAt"}}, "updatedAt"}` —
/// inclui TODOS os providers passados, mesmo os degradados/sem dado (a string
/// do ícone omiti-ia; o heartbeat é diagnóstico).
public enum E2EHeartbeat {
    /// Monta o payload v2. `errors` (selfcheck) é opcional e tokenizado —
    /// nunca inclui mensagem de erro crua (pode conter URL/shape).
    public static func payload(
        menuBarText: String,
        providers: [ProviderID: ProviderDisplay],
        errors: [ProviderID: String] = [:],
        now: Date = Date()
    ) -> [String: Any] {
        var providerPayload: [String: Any] = [:]
        for (id, display) in providers {
            // Fragmento com sigla ("C:12.4k"); sem dado → null.
            let menuBar: Any? = display.menuBarFragment.map { MenuBarContent.sigla(for: id) + ":\($0)" }
            var entry: [String: Any] = [
                // JSONSerialization só aceita chaves String — ProviderID vira rawValue
                // (com chaves enum o try? engoliria o erro e o state.json nunca apareceria).
                "menuBar": menuBar ?? NSNull(),
                "percent": display.percent.map { Int($0.rounded()) } ?? NSNull(),
                "todayTokens": display.todayTokens,
                "authState": display.authState.rawValue,
                "fetchedAt": ISO8601DateFormatter().string(from: display.fetchedAt),
            ]
            if let error = errors[id] {
                entry["error"] = error
            }
            providerPayload[id.rawValue] = entry
        }
        let payload: [String: Any] = [
            "menuBarText": menuBarText,
            "providers": providerPayload,
            "updatedAt": ISO8601DateFormatter().string(from: now),
        ]
        return payload
    }

    public static func write(
        menuBarText: String,
        providers: [ProviderID: ProviderDisplay],
        directory: URL,
        now: Date = Date()
    ) {
        let payload = payload(menuBarText: menuBarText, providers: providers, now: now)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
}
