import Foundation

/// Totais de "hoje" por arquivo, auto-corretivos contra truncamento.
/// actor: chamado pelo ingest loop fora da MainActor.
public actor TokenLedger {
    private struct FileLedger {
        var todaySums: TokenSums
        var day: Date  // startOfDay em que todaySums acumulou
    }

    private let calendar: Calendar
    private var files: [String: FileLedger] = [:]
    private var providerByPath: [String: ProviderID] = [:]
    private var currentDay: Date
    public private(set) var needsFullRescan = false

    public init(calendar: Calendar) {
        self.calendar = calendar
        self.currentDay = calendar.startOfDay(for: Date())
    }

    public func apply(_ results: [FileIngestResult], now: Date) {
        let today = calendar.startOfDay(for: now)
        for result in results {
            var ledger = result.resetToZero
                ? FileLedger(todaySums: .init(), day: today)
                : (files[result.path] ?? FileLedger(todaySums: .init(), day: today))

            var added = TokenSums()
            for event in result.newEvents where calendar.startOfDay(for: event.ts) == today {
                added += TokenSums(
                    input: event.inputTokens, output: event.outputTokens,
                    cacheRead: event.cacheReadTokens, cacheWrite: event.cacheWriteTokens
                )
            }
            ledger.todaySums += added
            ledger.day = today
            files[result.path] = ledger

            if let provider = result.newEvents.first?.provider {
                providerByPath[result.path] = provider
            }
        }
    }

    public func todayTotal(now: Date) -> Int64 {
        todayByProvider(now: now).values.reduce(0, +)
    }

    public func todayByProvider(now: Date) -> [ProviderID: Int64] {
        let today = calendar.startOfDay(for: now)
        var byProvider: [ProviderID: Int64] = [:]
        for (path, ledger) in files where ledger.day == today {
            let provider = providerByPath[path] ?? .claude
            byProvider[provider, default: 0] += ledger.todaySums.total
        }
        return byProvider.filter { $0.value > 0 }
    }

    public func rolloverIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        guard today != currentDay else { return }
        currentDay = today
        files = [:]
        needsFullRescan = true
    }

    public func clearRescanFlag() {
        needsFullRescan = false
    }
}
