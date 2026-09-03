import Foundation

public enum WindowKind: String, Sendable, Codable, CaseIterable { case session, weekly, daily }
public enum AuthState: String, Sendable, Codable { case ok, missing, invalid }
public enum DataSource: String, Sendable, Codable { case api, localOnly }

public struct UsageWindow: Sendable, Equatable, Codable {
    public let kind: WindowKind
    /// 0...1; `nil` = desconhecido (modo local sem quota conhecida — spec §5 regra 2).
    public let usedFraction: Double?
    public let resetsAt: Date?
    public let label: String

    public init(kind: WindowKind, usedFraction: Double?, resetsAt: Date?, label: String) {
        self.kind = kind
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.label = label
    }
}

public struct CreditsInfo: Sendable, Equatable, Codable {
    public let remaining: Double?
    public let unlimited: Bool

    public init(remaining: Double?, unlimited: Bool) {
        self.remaining = remaining
        self.unlimited = unlimited
    }
}

/// Estado consolidado de um provider×conta num ciclo de atualização — é isso
/// que a UI consome (janelas, créditos, badge "local", estado de auth).
public struct UsageSnapshot: Sendable, Equatable, Codable {
    public let provider: ProviderID
    public let account: AccountID
    public let windows: [UsageWindow]
    public let credits: CreditsInfo?
    public let fetchedAt: Date
    public let source: DataSource
    public let authState: AuthState

    public init(
        provider: ProviderID,
        account: AccountID,
        windows: [UsageWindow],
        credits: CreditsInfo?,
        fetchedAt: Date,
        source: DataSource,
        authState: AuthState
    ) {
        self.provider = provider
        self.account = account
        self.windows = windows
        self.credits = credits
        self.fetchedAt = fetchedAt
        self.source = source
        self.authState = authState
    }
}

/// Conta referenciada nos métodos do `UsageProvider`: identidade + rótulo de
/// exibição (a descoberta de contas decide o rótulo; a UI não re-deriva).
public struct AccountRef: Sendable, Equatable, Codable, Hashable {
    public let id: AccountID
    public let label: String

    public init(id: AccountID, label: String) {
        self.id = id
        self.label = label
    }
}
