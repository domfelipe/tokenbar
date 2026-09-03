import Foundation
import TokenBarCore
import TokenBarProviders
import TokenBarUI

enum SelfCheck {
    static func run(arguments: [String]) async throws {
        let dir = arguments.count > 1 ? arguments[1] : nil
        let locator = dir.map { ClaudeTranscriptLocator(projectsDirectory: URL(filePath: $0)) }
            ?? ClaudeTranscriptLocator.resolve()
        let provider = ClaudeProvider(
            projectsDirectory: locator.projectsDirectory,
            offsetStore: SelfCheckOffsetStore(),
            calendar: .current
        )
        let outcome = try await provider.ingestOnce(now: Date())
        let content = MenuBarContent(todayTokens: outcome.providerTotals)
        // ProviderID não faz bridge para NSString: JSONSerialization exige chaves String.
        let todayTokens = [String: Int64](
            uniqueKeysWithValues: outcome.providerTotals.map { ($0.key.rawValue, $0.value) }
        )
        let payload: [String: Any] = [
            "menuBarText": content.displayString(),
            "todayTokens": todayTokens,
            "eventsApplied": outcome.eventsApplied,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

private final class SelfCheckOffsetStore: FileOffsetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: FileCursor] = [:]

    func cursors() -> [String: FileCursor] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ cursor: FileCursor?, for path: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let cursor { storage[path] = cursor } else { storage.removeValue(forKey: path) }
    }
}
