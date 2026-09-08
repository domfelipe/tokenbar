import Foundation

/// Migração de cursores legados F1/F2 (spec F3): lê o
/// `<provider>-cursors.json` da support directory, copia o mapa para a
/// tabela `settings` (chave `cursors:<provider>`) e renomeia o arquivo para
/// `<nome>.json.migrated`.
///
/// Idempotência (obrigatória — roda a cada abertura do app):
/// - arquivo ausente (nunca existiu ou já migrado) → no-op;
/// - `cursors:<provider>` é reescrito com o MESMO conteúdo do arquivo
///   (fonte única: o arquivo; após o rename ele não muda mais);
/// - as marcas d'água (`hwm:<provider>:<path>`) usam INSERT OR IGNORE —
///   re-executar nunca REBAIXA uma marca d'água que a ingest já avançou
///   (rebajar faria o re-persist duplicar eventos).
///
/// Falha em qualquer etapa: log estruturado + `false`, NUNCA throw/crash —
/// o app segue com o que tem (o arquivo fica no lugar e a migração é
/// tentada de novo na próxima abertura; convergente pelas regras acima).
public enum CursorMigrator {
    /// `true` = migração executada agora; `false` = no-op ou falha (logada).
    @discardableResult
    public static func migrate(
        provider: ProviderID,
        jsonURL: URL,
        database: AppDatabase,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: jsonURL.path) else { return false }

        do {
            let data = try Data(contentsOf: jsonURL)
            let cursors = try JSONDecoder().decode([String: FileCursor].self, from: data)

            let key = DBOffsetStore.settingsKey(for: provider)
            let json = String(decoding: try JSONEncoder().encode(cursors), as: UTF8.self)
            try database.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                    arguments: [key, json])
                // Marca d'água inicial = offset já consumido pelo F2: bytes
                // atrás do cursor legado foram contados no display antes da
                // F3 e NÃO viram eventos retroativos (backfill fora de escopo
                // — decisão documentada no relatório da Task 1).
                for (path, cursor) in cursors {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
                        arguments: [highWaterKey(provider: provider, path: path), String(cursor.offset)])
                }
            }
        } catch {
            // Arquivo ilegível/DB falhou: mantém o .json no lugar (retry na
            // próxima abertura). Sem paths/credenciais no log.
            persistenceLog.error("cursor migration failed for \(provider.rawValue, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            return false
        }

        // Rename por último: só sai da apreensão do legado depois que o
        // settings já tem o mapa (crash entre as etapas → re-migração no-op).
        let migratedURL = URL(fileURLWithPath: jsonURL.path + ".migrated")
        do {
            if fileManager.fileExists(atPath: migratedURL.path) {
                try fileManager.removeItem(at: migratedURL)
            }
            try fileManager.moveItem(at: jsonURL, to: migratedURL)
        } catch {
            persistenceLog.error("cursor migration rename failed for \(provider.rawValue, privacy: .public)")
            return false
        }
        persistenceLog.info("cursor migration done for \(provider.rawValue, privacy: .public)")
        return true
    }
}
