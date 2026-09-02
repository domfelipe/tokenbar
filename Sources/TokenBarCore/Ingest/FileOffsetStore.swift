import Foundation
import os

public protocol FileOffsetStoring: Sendable {
    func cursors() -> [String: FileCursor]
    func set(_ cursor: FileCursor?, for path: String) throws
}

/// Persiste cursores como JSON. Arquivo ausente ou corrompido = estado vazio
/// (re-ingest completa; sem crash).
///
/// Nota: o brief usava `NSLock` + `var cache`, mas sob Swift 6 (strict
/// concurrency) propriedade mutável em classe Sendable-conforme é erro de
/// compilação mesmo protegida por lock. `OSAllocatedUnfairLock` dá a mesma
/// disciplina com verificação do compilador.
public final class JSONFileOffsetStore: FileOffsetStoring {
    private let url: URL
    private let state = OSAllocatedUnfairLock<[String: FileCursor]>(initialState: [:])

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: FileCursor].self, from: data) {
            state.withLock { $0 = decoded }
        }
    }

    public func cursors() -> [String: FileCursor] {
        state.withLock { $0 }
    }

    public func set(_ cursor: FileCursor?, for path: String) throws {
        let snapshot = state.withLock { cache -> [String: FileCursor] in
            if let cursor { cache[path] = cursor } else { cache.removeValue(forKey: path) }
            return cache
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
