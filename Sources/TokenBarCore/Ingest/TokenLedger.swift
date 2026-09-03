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
        var currentDay: Date
        var needsFullRescan = false
    }

    private let calendar: Calendar
    private let state: OSAllocatedUnfairLock<State>

    public init(calendar: Calendar) {
        self.calendar = calendar
        self.state = OSAllocatedUnfairLock(initialState: State(currentDay: calendar.startOfDay(for: Date())))
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
            guard today != s.currentDay else { return }
            s.currentDay = today
            s.files = [:]
            s.needsFullRescan = true
        }
    }

    public func clearRescanFlag() {
        state.withLock { $0.needsFullRescan = false }
    }
}
