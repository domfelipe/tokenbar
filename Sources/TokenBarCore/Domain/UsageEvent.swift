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
    /// Id da mensagem na fonte, quando ela tem id próprio (Gemini: `id` da
    /// linha-raiz, spec F2 §3.3). O provider dedupica por ele — a mesma
    /// mensagem pode vir 2× (reanexo do CLI). `nil` = evento sem dedupe.
    /// Opcional p/ compat: eventos persistidos antes do campo decodificam nil.
    public var dedupeID: String?

    public init(
        ts: Date, provider: ProviderID, account: AccountID, model: String?,
        inputTokens: Int64, outputTokens: Int64,
        cacheReadTokens: Int64, cacheWriteTokens: Int64, project: String?,
        dedupeID: String? = nil
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
        self.dedupeID = dedupeID
    }
}
