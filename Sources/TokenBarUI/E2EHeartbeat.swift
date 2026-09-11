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
///
/// F4 (painel rico) é ADITIVO no v3: `monthTokens`/`monthCostUsd` (30d, só
/// quando a query rodou) e `pacing` (forecast contra a janela crítica, só
/// quando existe). A string do menu bar segue intocada.
public enum E2EHeartbeat {
    /// Monta o payload v3. `errors` (selfcheck) é opcional e tokenizado —
    /// nunca inclui mensagem de erro crua (pode conter URL/shape).
    /// Aditivos F5: `credits` por provider (saldo real do snapshot; ausente =
    /// sem dado) e `alertsStatus` top-level (estado honesto do rodapé do
    /// painel; `nil` = não informado — selfcheck). Menu bar intocado.
    public static func payload(
        menuBarText: String,
        providers: [ProviderID: ProviderDisplay],
        errors: [ProviderID: String] = [:],
        alertsStatus: AlertsPanelStatus? = nil,
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
            // F4 (ADITIVO — painel rico): totais 30d. `monthTokens`/`monthCostUsd`
            // presentes SOMENTE quando a query do ciclo rodou (mesma honestidade
            // do history7d); custo sem preço computável → chave ausente (nunca
            // zero fake).
            if display.monthHistoryAvailable {
                entry["monthTokens"] = display.monthTokens
                if let monthCost = display.monthCostUsd {
                    entry["monthCostUsd"] = monthCost
                }
            }
            // F4 (ADITIVO): forecast de pacing contra a janela crítica — só
            // quando existe (`nil` = sem chute → omitido). `exhaustedIn`/
            // `deficitPct` são null EXPLÍCITO quando não se aplicam (a chave
            // existir prova que o forecast existe, o valor diz o estado).
            if let pacing = display.pacing {
                let exhausted: Any = pacing.exhaustedIn ?? NSNull()
                let deficit: Any = pacing.deficitPct ?? NSNull()
                entry["pacing"] = [
                    "exhaustedIn": exhausted,
                    "projectedFraction": pacing.projectedFraction,
                    "deficitPct": deficit,
                ]
            }
            if let credits = display.credits, credits.unlimited || credits.remaining != nil {
                // F5 T6 (ADITIVO): saldo de credits do snapshot — presente só
                // quando há dado UTILIZÁVEL (mesma regra da linha do painel):
                // um objeto credits com balance null (Codex de plano) → chave
                // ausente, nunca null fake; unlimited é false explícito.
                entry["credits"] = [
                    "remaining": credits.remaining.map { $0 as Any } ?? NSNull(),
                    "unlimited": credits.unlimited,
                ]
            }
            if let error = errors[id] {
                entry["error"] = error
            }
            providerPayload[id.rawValue] = entry
        }
        var payload: [String: Any] = [
            "menuBarText": menuBarText,
            "providers": providerPayload,
            "updatedAt": ISO8601DateFormatter().string(from: now),
        ]
        if let alertsStatus {
            payload["alertsStatus"] = String(describing: alertsStatus)
        }
        return payload
    }

    public static func write(
        menuBarText: String,
        providers: [ProviderID: ProviderDisplay],
        directory: URL,
        alertsStatus: AlertsPanelStatus? = nil,
        now: Date = Date()
    ) {
        let payload = payload(
            menuBarText: menuBarText, providers: providers,
            alertsStatus: alertsStatus, now: now)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
}
