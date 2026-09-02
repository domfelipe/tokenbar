import Foundation

public struct UsageEvent: Sendable, Equatable, Codable {
    public var ts: Date
    public var provider: ProviderID
    public var account: AccountID
    public var model: String?
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var project: String?

    public init(
        ts: Date, provider: ProviderID, account: AccountID, model: String?,
        inputTokens: Int64, outputTokens: Int64,
        cacheReadTokens: Int64, cacheWriteTokens: Int64, project: String?
    ) {
        self.ts = ts
        self.provider = provider
        self.account = account
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.project = project
    }
}
