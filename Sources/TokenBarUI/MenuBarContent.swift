import Foundation
import TokenBarCore

public func abbrevTokens(_ n: Int64) -> String {
    switch n {
    case ..<1_000:
        return String(n)
    case ..<1_000_000:
        return String(format: "%.1fk", Double(n) / 1_000)
    case ..<1_000_000_000:
        return String(format: "%.1fM", Double(n) / 1_000_000)
    default:
        return String(format: "%.1fG", Double(n) / 1_000_000_000)
    }
}

public struct MenuBarContent: Equatable, Sendable {
    public let todayTokens: [ProviderID: Int64]

    public static let empty = MenuBarContent(todayTokens: [:])

    public init(todayTokens: [ProviderID: Int64]) {
        self.todayTokens = todayTokens
    }

    public func displayString() -> String {
        guard !todayTokens.isEmpty else { return "TB" }
        return todayTokens
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue.prefix(1).uppercased()):\(abbrevTokens($0.value))" }
            .joined(separator: " ")
    }
}
