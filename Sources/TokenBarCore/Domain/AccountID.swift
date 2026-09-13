public struct AccountID: Hashable, Sendable, Codable {
    /// Chave da conta AGREGADA de um provider: usada por eventos que valem para
    /// TODAS as contas (orçamento mensal, F7). Nunca é um caminho real — o
    /// evento de orçamento não pertence a uma conta.
    public static let allAccountsKey = "*"

    public let provider: ProviderID
    public let key: String

    public init(provider: ProviderID, key: String) {
        self.provider = provider
        self.key = key
    }
}
