import Foundation
import os

/// Registro central de providers por `ProviderID`. Thread-safe (mesmo padrão
/// de `OSAllocatedUnfairLock` do `JSONFileOffsetStore`/`TokenLedger`).
/// Re-registro do mesmo id substitui o anterior (útil para testes e para
/// reconfiguração em runtime).
public final class ProviderRegistry: Sendable {
    private let providers: OSAllocatedUnfairLock<[ProviderID: any UsageProvider]>

    public init(providers: [any UsageProvider] = []) {
        let initial = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        self.providers = OSAllocatedUnfairLock(initialState: initial)
    }

    public func register(_ provider: any UsageProvider) {
        providers.withLock { $0[provider.id] = provider }
    }

    public func provider(for id: ProviderID) -> (any UsageProvider)? {
        providers.withLock { $0[id] }
    }

    /// Todos os providers registrados, ordenados por id (ordem estável p/ UI).
    public var all: [any UsageProvider] {
        providers.withLock { state in
            state.values.sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }
}
