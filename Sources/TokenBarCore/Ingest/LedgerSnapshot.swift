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
///
/// `cursorStamp` é a impressão digital do store de cursores no momento do
/// save: a restauração só vale se os cursores atuais baterem. Sem isso, um
/// store de cursores perdido/corrompido (re-ingest completa) dobraria os
/// totais sobre o snapshot restaurado (Red Team F2, caso 5).
public struct LedgerSnapshot: Sendable, Equatable {
    /// `startOfDay` em que o snapshot foi tirado — só restaura se == hoje.
    public let day: Date
    /// Path do arquivo → soma do dia daquele arquivo.
    public let files: [String: TokenSums]
    /// `nil` = snapshot sem stamp (estranho/corrompido) → nunca restaura.
    public let cursorStamp: String?

    public init(day: Date, files: [String: TokenSums], cursorStamp: String? = nil) {
        self.day = day
        self.files = files
        self.cursorStamp = cursorStamp
    }

    /// Restringe o snapshot aos paths que (a) AINDA EXISTEM no store de
    /// cursores e (b) estão sob a RAIZ DE SCAN ATUAL do provider.
    ///
    /// (a) Red Team/e2e T8 (P1): o arquivo de snapshot acumula entradas de
    ///     corpora/instalações anteriores; restaurar entradas cujo cursor sumiu
    ///     ressuscita totais de paths que não são mais escaneados.
    /// (b) Red Team T8, auditoria do 42d42e9: o critério (a) sozinho NÃO cobre
    ///     o cenário do e2e — o store de cursores ACUMULA paths (nunca poda),
    ///     então o cursor do path velho sobrevive e o stamp do snapshot
    ///     carimbado com ele BATE; só o escopo da raiz impede que o total morto
    ///     volte (menu bar dobrava entre runs: C:4.0M→C:7.7M, G:193→G:386).
    public func filtered(toExistingIn cursors: [String: FileCursor], underScanRoot root: String) -> LedgerSnapshot {
        // Os paths nos cursores/snapshot vêm do enumerator do scan, que RESOLVE
        // symlinks da raiz (ex.: /var → /private/var) — os dois lados passam
        // por `resolvingSymlinksInPath` para a comparação ser de verdade.
        let resolvedRoot = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath().path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let alive = files.filter { path, _ in
            guard cursors[path] != nil else { return false }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return resolved == resolvedRoot || resolved.hasPrefix(prefix)
        }
        return LedgerSnapshot(day: day, files: alive, cursorStamp: cursorStamp)
    }
}

/// Impressão digital determinística e bounded do store de cursores: FNV-1a 64
/// sobre os pares `path <US> offset` ordenados por path. Não é criptografia —
/// é só para detectar que o CONJUNTO de cursores mudou (perda, reset,
/// corrupção de arquivo) entre o save do snapshot e a tentativa de restaurar.
public enum LedgerSnapshotStamp {
    public static func make(_ cursors: [String: FileCursor]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func fold(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0x1f
            hash = hash &* 0x100000001b3
        }
        for path in cursors.keys.sorted() {
            fold("\(path)\u{1f}\(cursors[path]?.offset ?? 0)")
        }
        return String(hash, radix: 16)
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
        let cursorStamp: String?
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
        return LedgerSnapshot(day: file.day, files: files, cursorStamp: file.cursorStamp)
    }

    public func save(_ snapshot: LedgerSnapshot?) {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let file = File(
            day: snapshot.day,
            files: snapshot.files.mapValues { [$0.input, $0.output, $0.cacheRead, $0.cacheWrite] },
            cursorStamp: snapshot.cursorStamp
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Conveniência dos providers: grava o snapshot carimbado com o estado dos
/// cursores (chamado DEPOIS de persistir os cursores — ordem anti-dupla-
/// contagem documentada em `TokenLedger.daySnapshot`).
extension LedgerSnapshotStoring {
    public func saveDay(_ snapshot: LedgerSnapshot?, stamping cursors: [String: FileCursor]) {
        save(snapshot.map {
            LedgerSnapshot(day: $0.day, files: $0.files, cursorStamp: LedgerSnapshotStamp.make(cursors))
        })
    }
}
