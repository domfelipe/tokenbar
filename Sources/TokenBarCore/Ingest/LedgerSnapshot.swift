import Foundation
import os

/// Estado do ledger de "hoje" de UM provider — o que persiste além do restart
/// (Red Team F2, caso 7: os cursores sobrevivem ao relançamento, o ledger era
/// volátil; restart no meio do dia perdia o total até o rollover de meia-noite).
///
/// Granularidade POR ARQUIVO com os componentes de `TokenSums` (não um total
/// agregado): restaurar por arquivo preserva a auto-correção contra
/// truncamento da F1 — o reset de UM arquivo zera só a contribuição dele, sem
/// perder a dos outros nem ressuscitar a do truncado.
public struct LedgerSnapshot: Sendable, Equatable {
    /// `startOfDay` em que o snapshot foi tirado — só restaura se == hoje.
    public let day: Date
    /// Path do arquivo → soma do dia daquele arquivo.
    public let files: [String: TokenSums]

    public init(day: Date, files: [String: TokenSums]) {
        self.day = day
        self.files = files
    }
}

/// Store do snapshot do dia (um arquivo por provider, ao lado dos cursores).
/// `load() == nil` = ausente/corrompido/ilegível → o chamador segue sem
/// restaurar (nunca crash); `save(nil)` limpa (dia sem total não ressuscita
/// estado velho no restart seguinte).
public protocol LedgerSnapshotStoring: Sendable {
    func load() -> LedgerSnapshot?
    func save(_ snapshot: LedgerSnapshot?)
}

/// JSON no App Support (`<provider>-ledger.json`), mesmo padrão do
/// `JSONFileOffsetStore`: decode tolerante (arquivo truncado/corrompido =
/// estado vazio) e escrita atômica. Introspecção simples: os paths são os
/// mesmos do `<provider>-cursors.json` — nunca conteúdo de transcript.
public final class JSONLedgerSnapshotStore: LedgerSnapshotStoring {
    private struct File: Codable {
        let day: Date
        // [input, output, cacheRead, cacheWrite] — array fixo de 4 (compacto).
        let files: [String: [Int64]]
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> LedgerSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.files.values.allSatisfy({ $0.count == 4 })
        else { return nil }
        var files: [String: TokenSums] = [:]
        files.reserveCapacity(file.files.count)
        for (path, sums) in file.files {
            files[path] = TokenSums(
                input: sums[0], output: sums[1], cacheRead: sums[2], cacheWrite: sums[3]
            )
        }
        return LedgerSnapshot(day: file.day, files: files)
    }

    public func save(_ snapshot: LedgerSnapshot?) {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let file = File(
            day: snapshot.day,
            files: snapshot.files.mapValues { [$0.input, $0.output, $0.cacheRead, $0.cacheWrite] }
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
