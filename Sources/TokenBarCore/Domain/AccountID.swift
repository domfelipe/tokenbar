public struct AccountID: Hashable, Sendable, Codable {
    public let provider: ProviderID
    public let key: String

    public init(provider: ProviderID, key: String) {
        self.provider = provider
        self.key = key
    }
}
