import Foundation
import os

/// Store de cursores VIVO com backup no banco (F3): o mapa `path → FileCursor`
/// de um provider inteiro vive na tabela `settings`, chave `cursors:<provider>`
/// (JSON, mesmo formato do arquivo legado do F2).
///
/// Por que o banco assume os cursores na F3: a migração (CursorMigrator)
/// RENOMEIA o `<provider>-cursors.json` legado — se o store vivo continuasse
/// sendo o arquivo, cada launch perderia os cursores de todos os paths não
/// atualizados na sessão anterior e re-escanearia a história inteira (CPU por
/// launch fora do orçamento). Com o settings como fonte da verdade, o arquivo
/// vira relicário de uma única migração.
///
/// Mesma disciplina do `JSONFileOffsetStore`: mirror em memória sob
/// `OSAllocatedUnfairLock` (Swift 6 strict), escrita do mapa completo por
/// `set` — custo idêntico ao do arquivo (que também era reescrito inteiro).
public final class DBOffsetStore: Sendable, FileOffsetStoring {
    private let database: AppDatabase
    private let provider: ProviderID
    /// Chave RESOLVIDA na init (evita divergência entre leitura e escrita —
    /// a conta registrada NUNCA pode vazar para a chave legada e vice-versa).
    private let settingsKey: String
    private let state: OSAllocatedUnfairLock<[String: FileCursor]>

    /// Chave do mapa de cursores no `settings`. Conta default (nil/"local")
    /// mantém a chave legada `cursors:<provider>` (obrigação dura F2/F3);
    /// contas registradas (F4) ganham namespace próprio
    /// `cursors:<provider>:<accountKey>` — cursores por CONTA.
    public static func settingsKey(for provider: ProviderID, accountKey: String? = nil) -> String {
        if let accountKey, accountKey != "local" {
            return "cursors:\(provider.rawValue):\(accountKey)"
        }
        return "cursors:\(provider.rawValue)"
    }

    /// Semeia o mirror da tabela `settings` (CursorMigrador plantou lá o
    /// legado; nas sessões seguintes é o próprio store que escreveu).
    public init(database: AppDatabase, provider: ProviderID, accountKey: String? = nil) {
        self.database = database
        self.provider = provider
        self.settingsKey = Self.settingsKey(for: provider, accountKey: accountKey)
        let seed: [String: FileCursor]
        if let raw = try? database.setting(forKey: settingsKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: FileCursor].self, from: data) {
            seed = decoded
        } else {
            seed = [:]
        }
        self.state = OSAllocatedUnfairLock(initialState: seed)
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
        try database.setSetting(String(decoding: data, as: UTF8.self), forKey: settingsKey)
    }
}
