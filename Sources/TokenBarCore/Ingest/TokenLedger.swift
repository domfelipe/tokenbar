import Foundation
import os

/// Totais de "hoje" por arquivo, auto-corretivos contra truncamento.
///
/// Classe `Sendable` com lock (`OSAllocatedUnfairLock`, mesmo padrão do
/// `JSONFileOffsetStore`) em vez de actor: o ingest streaming (Red Team F1,
/// caso 2) aplica lotes de eventos sincronamente no hot loop — com actor, cada
/// lote exigiria um hop de concorrência e o callback do ingester teria que ser
/// async, complicando o núcleo sem ganho nenhum (tudo roda na mesma tarefa).
public final class TokenLedger: Sendable {
    private struct FileLedger {
        var todaySums: TokenSums
        var day: Date  // startOfDay em que todaySums acumulou
    }

    private struct State {
        var files: [String: FileLedger] = [:]
        var providerByPath: [String: ProviderID] = [:]
        /// Dia corrente — `nil` até o primeiro `rolloverIfNeeded` (o ledger não
        /// consulta o relógio real no init: o dia vem do `now` do ciclo, senão
        /// um primeiro ciclo com `now` divergente do launch dispararia um
        /// re-scan de rollover espúrio — achado do Red Team F2 caso 7).
        var currentDay: Date?
        var needsFullRescan = false
        /// Restauração do snapshot pós-restart é UMA vez por processo (Red Team
        /// F2 caso 7): o ledger em memória é sempre ≥ o snapshot a partir do
        /// primeiro ciclo, e re-ler um snapshot velho poderia regredir estado.
        var didRestoreDay = false
    }

    private let calendar: Calendar
    private let state: OSAllocatedUnfairLock<State>

    public init(calendar: Calendar) {
        self.calendar = calendar
        self.state = OSAllocatedUnfairLock(initialState: State(currentDay: nil))
    }

    public var needsFullRescan: Bool {
        state.withLock { $0.needsFullRescan }
    }

    public func apply(_ results: [FileIngestResult], now: Date) {
        let today = calendar.startOfDay(for: now)
        // limite [hoje 00:00, amanhã 00:00) — equivalente a
        // startOfDay(event.ts) == today, mas O(1) por evento (1M eventos no
        // corpus gigante: startOfDay por evento custaria ~2 s a mais).
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        state.withLock { s in
            for result in results {
                var ledger = result.resetToZero
                    ? FileLedger(todaySums: .init(), day: today)
                    : (s.files[result.path] ?? FileLedger(todaySums: .init(), day: today))

                var added = TokenSums()
                for event in result.newEvents where event.ts >= today && event.ts < tomorrow {
                    added += TokenSums(
                        input: event.inputTokens, output: event.outputTokens,
                        cacheRead: event.cacheReadTokens, cacheWrite: event.cacheWriteTokens
                    )
                }
                ledger.todaySums += added
                ledger.day = today
                s.files[result.path] = ledger

                if let provider = result.newEvents.first?.provider {
                    s.providerByPath[result.path] = provider
                }
            }
        }
    }

    public func todayTotal(now: Date) -> Int64 {
        todayByProvider(now: now).values.reduce(0, +)
    }

    public func todayByProvider(now: Date) -> [ProviderID: Int64] {
        let today = calendar.startOfDay(for: now)
        return state.withLock { s -> [ProviderID: Int64] in
            var byProvider: [ProviderID: Int64] = [:]
            for (path, ledger) in s.files where ledger.day == today {
                let provider = s.providerByPath[path] ?? .claude
                byProvider[provider, default: 0] += ledger.todaySums.total
            }
            return byProvider.filter { $0.value > 0 }
        }
    }

    public func rolloverIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        state.withLock { s in
            guard s.currentDay != today else { return }
            if s.currentDay == nil {
                // Primeiro ciclo do processo: apenas registra o dia — não é
                // rollover, quem manda nos bytes é o cursor persistido.
                s.currentDay = today
                return
            }
            s.currentDay = today
            s.files = [:]
            s.needsFullRescan = true
        }
    }

    public func clearRescanFlag() {
        state.withLock { $0.needsFullRescan = false }
    }

    // MARK: - Snapshot do dia (Red Team F2, caso 7 — restart mid-day)

    /// Restaura o estado do dia a partir do snapshot persistido, UMA vez por
    /// processo. Entrada por arquivo: o total restaurado pertence aos MESMOS
    /// paths dos cursores persistidos (o par cursor+snapshot é escrito no
    /// mesmo ciclo), então restaurar NÃO duplica — o tail já consumido fica
    /// atrás do cursor. Dia divergente (snapshot de ontem, rollover) → no-op:
    /// o re-scan do rollover reconstrói tudo. Nunca rebaixa entrada viva.
    public func restoreDay(_ snapshot: LedgerSnapshot, provider: ProviderID, now: Date) {
        let today = calendar.startOfDay(for: now)
        state.withLock { s in
            guard !s.didRestoreDay else { return }
            s.didRestoreDay = true
            guard today == s.currentDay, snapshot.day == today else { return }
            for (path, sums) in snapshot.files {
                guard s.files[path] == nil else { continue }
                s.files[path] = FileLedger(todaySums: sums, day: today)
                s.providerByPath[path] = provider
            }
        }
    }

    /// Snapshot do dia corrente p/ persistência. O chamador (provider) salva
    /// ao fim do ciclo, DEPOIS de persistir os cursores — ordem que evita
    /// dupla contagem no crash entre as duas escritas: com cursor novo e
    /// snapshot velho o tail falta no total (subconta honesta, last-good); no
    /// ordem inversa o tail seria relido SOBRE o total restaurado (dobra).
    public func daySnapshot(now: Date) -> LedgerSnapshot? {
        let today = calendar.startOfDay(for: now)
        return state.withLock { s -> LedgerSnapshot? in
            guard today == s.currentDay else { return nil }
            var files: [String: TokenSums] = [:]
            for (path, ledger) in s.files where ledger.day == today {
                files[path] = ledger.todaySums
            }
            return files.isEmpty ? nil : LedgerSnapshot(day: today, files: files)
        }
    }
}
