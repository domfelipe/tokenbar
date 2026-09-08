import Foundation
import TokenBarCore

/// Ancoragem de teste E2E/diagnóstico: estado vivo por provider — nunca paths
/// nem conteúdo de transcript/credencial (spec §9).
///
/// Formato v3 (F3): v2 + campo OPCIONAL `history7d` por provider —
/// `{"tokens": N, "costUsd": X|null}` (histórico de 7 dias do banco; o e2e
/// valida persistência → consulta). Omitido quando a leitura não ocorreu ou
/// falhou (sem DB — degradação F2 — ou erro transitório; nada fake), enquanto
/// tokens/custo presenciam `todayCostUsd` (F3 Task 2) e o painel mantém o
/// último valor bom.
public enum E2EHeartbeat {
    /// Monta o payload v3. `errors` (selfcheck) é opcional e tokenizado —
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
            // F3 Task 2: custo estimado do dia (número) — omitido quando nil
            // (sem DB / sem evento precificado hoje); nunca vira null "fake".
            if let cost = display.todayCostUsd {
                entry["todayCostUsd"] = cost
            }
            // F3 Task 4 (v3): histórico 7d {"tokens": N, "costUsd": X|null} —
            // presente SOMENTE quando a query do ciclo foi bem-sucedida; custo
            // sem preço computável é null EXPLÍCITO (nulo ≠ omitido: a chave
            // existir prova que a consulta rodou, o valor diz que não há custo).
            if display.weekHistoryAvailable {
                var history7d: [String: Any] = ["tokens": display.weekTokens]
                if let weekCost = display.weekCostUsd {
                    history7d["costUsd"] = weekCost
                } else {
                    history7d["costUsd"] = NSNull()
                }
                entry["history7d"] = history7d
            }
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
