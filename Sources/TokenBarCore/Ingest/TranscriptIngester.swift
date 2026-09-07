import Foundation
import Darwin

public struct FileIngestResult: Sendable, Equatable {
    public let path: String
    public let newEvents: [UsageEvent]
    public let cursor: FileCursor
    public let resetToZero: Bool

    public init(path: String, newEvents: [UsageEvent], cursor: FileCursor, resetToZero: Bool) {
        self.path = path
        self.newEvents = newEvents
        self.cursor = cursor
        self.resetToZero = resetToZero
    }
}

/// Atualização de cursor do núcleo streaming (os eventos já foram entregues
/// via callback `onEvents`; aqui vai só o state de cursor por arquivo).
public struct FileCursorUpdate: Sendable, Equatable {
    public let path: String
    public let cursor: FileCursor
    public let resetToZero: Bool
}

public struct TranscriptIngester: Sendable {
    /// Janela de leitura reutilizada por arquivo. Nenhuma outra alocação
    /// proporcional ao tamanho do arquivo acontece no streaming — buffers
    /// novos por chunk viravam ~200 MB de arena no malloc mesmo liberados
    /// (Red Team F1, caso 2).
    static let windowSize = 262_144

    private let parseLine: @Sendable (String, Date) -> UsageEvent?

    public init(parseLine: @escaping @Sendable (String, Date) -> UsageEvent?) {
        self.parseLine = parseLine
    }

    /// API de array: retém todos os eventos do ciclo em memória. Adequada para
    /// testes e corpora pequenos; o app usa `ingestChangedFilesStreaming`.
    public func ingestChangedFiles(
        under directory: URL,
        cursors: [String: FileCursor],
        makeEvent: (UsageEvent, String) -> UsageEvent
    ) throws -> [FileIngestResult] {
        var eventsByPath: [String: [UsageEvent]] = [:]
        let updates = try ingestChangedFilesStreaming(
            under: directory,
            cursors: cursors,
            makeEvent: makeEvent
        ) { path, events, _ in
            eventsByPath[path, default: []].append(contentsOf: events)
        }
        return updates.map {
            FileIngestResult(
                path: $0.path,
                newEvents: eventsByPath[$0.path] ?? [],
                cursor: $0.cursor,
                resetToZero: $0.resetToZero
            )
        }
    }

    /// Núcleo streaming: leitura em janela única reutilizada (`read(2)` + memmove
    /// da cauda parcial), parse por segmento com autoreleasepool e entrega dos
    /// eventos por lote via `onEvents(path, events, reset)` — memória limitada
    /// independentemente do tamanho do arquivo (Red Team F1, caso 2).
    ///
    /// `reset` vem `true` no primeiro callback relativo a um arquivo que
    /// ENCOLHEU desde o último ciclo (inclusive truncado a zero, mesmo sem
    /// linhas novas) — o ledger usa isso para zerar a soma daquele arquivo e
    /// os totais se autocorrigirem.
    public func ingestChangedFilesStreaming(
        under directory: URL,
        cursors: [String: FileCursor],
        makeEvent: (UsageEvent, String) -> UsageEvent,
        onEvents: (String, [UsageEvent], Bool) throws -> Void
    ) throws -> [FileCursorUpdate] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        var updates: [FileCursorUpdate] = []
        for path in try Self.scanJSONL(under: directory) {
            // Sumiu entre o scan e o stat (churn concorrente): pula este ciclo;
            // o próximo evento do watcher reprocessa. Antes o erro subia e
            // descartava o ciclo inteiro (try? no provider zerava o heartbeat).
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()
            let previous = cursors[path]?.offset ?? 0

            // Inalterado (nada além do cursor): pula. Encolheu: reset.
            guard size != previous else { continue }
            let reset = size < previous
            let startOffset: UInt64 = reset ? 0 : previous

            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            if startOffset > 0 && lseek(fd, off_t(startOffset), SEEK_SET) < 0 { continue }

            // Snapshot do tamanho no momento do stat; se o arquivo encolher
            // DEPOIS (truncamento concorrente), read devolve menos bytes e o
            // cursor fica consistente com o que de fato foi lido.
            let limit = size &- startOffset
            var window = [UInt8](repeating: 0, count: Self.windowSize)  // reutilizada
            var pending = 0            // bytes válidos em window[0..<pending] sem \n processado
            var skipping = false       // linha maior que a janela: descarta até o \n
            var consumed: UInt64 = 0   // bytes até o último \n
            var readTotal: UInt64 = 0
            var resetSignaled = false

            // Drena um ciclo de segmentos completos da janela.
            // Em modo normal usa o ÚLTIMO \n (um lote grande por chamada); em
            // modo skip usa o primeiro \n (fim da linha oversized).
            func drainOnce() throws {
                if skipping {
                    guard let idx = window[0..<pending].firstIndex(of: UInt8(ascii: "\n")) else { return }
                    consumed += UInt64(idx + 1)  // consumida sem parse
                    let tail = pending - idx - 1
                    if tail > 0 {
                        window.withUnsafeMutableBytes { raw in
                            memmove(raw.baseAddress!, raw.baseAddress!.advanced(by: idx + 1), tail)
                        }
                    }
                    pending = tail
                    skipping = false
                } else {
                    guard let idx = window[0..<pending].lastIndex(of: UInt8(ascii: "\n")) else { return }
                    try Self.processSegment(
                        window[0...idx],
                        path: path,
                        modified: modified,
                        reset: reset && !resetSignaled,
                        parseLine: parseLine,
                        makeEvent: makeEvent,
                        onEvents: onEvents
                    )
                    if reset { resetSignaled = true }
                    consumed += UInt64(idx + 1)
                    let tail = pending - idx - 1
                    if tail > 0 {
                        window.withUnsafeMutableBytes { raw in
                            memmove(raw.baseAddress!, raw.baseAddress!.advanced(by: idx + 1), tail)
                        }
                    }
                    pending = tail
                }
            }

            while readTotal < limit {
                try drainOnce()
                // Janela cheia sem nenhum \n: linha maior que a janela —
                // descarta o conteúdo (cursor exato) e segue em modo skip.
                if pending == window.count {
                    consumed += UInt64(pending)
                    pending = 0
                    skipping = true
                }
                let free = window.count - pending
                let want = Int(min(UInt64(free), limit &- readTotal))
                guard want > 0 else { break }
                let n = window.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress!.advanced(by: pending), want)
                }
                guard n > 0 else { break }  // EOF ou erro (ex.: truncou durante a leitura)
                readTotal += UInt64(n)
                pending += n
            }
            try drainOnce()  // conteúdo da última leitura
            // Red Team T8 (P1, subconta silenciosa): o drainOnce acima pode
            // ter só SAÍDO do modo skip (achou o \n que encerra a linha
            // oversized) sem parsear a cauda — o fim do arquivo coincide com a
            // saída do skip e as linhas seguintes se perdiam para sempre (o
            // cursor já as consumia). Drena até esvaziar a janela. Sem \n à
            // frente: skip consome o restante (cursor exato); linha
            // incompleta em modo normal fica fora do cursor (semântica F1 —
            // só \n-terminado é consumido).
            while pending > 0 {
                guard window[0..<pending].contains(UInt8(ascii: "\n")) else {
                    if skipping {
                        consumed += UInt64(pending)
                        pending = 0
                    }
                    break
                }
                try drainOnce()
            }
            // Encolheu sem nenhuma linha completa (ex.: truncado a 0): ainda
            // sinaliza o reset para o ledger zerar a soma daquele arquivo.
            if reset && !resetSignaled {
                try onEvents(path, [], true)
            }

            let finalCursor = startOffset + consumed
            if finalCursor != previous || reset {
                updates.append(FileCursorUpdate(path: path, cursor: FileCursor(offset: finalCursor), resetToZero: reset))
            }
        }
        return updates
    }

    /// Parseia um segmento que termina em \n e entrega os eventos de uma vez.
    /// autoreleasepool drena objetos autoreleased do Foundation (formatters,
    /// bridging) a cada segmento — sem ele, 1M de linhas acumulam centenas de MB.
    private static func processSegment(
        _ segment: ArraySlice<UInt8>,
        path: String,
        modified: Date,
        reset: Bool,
        parseLine: @Sendable (String, Date) -> UsageEvent?,
        makeEvent: (UsageEvent, String) -> UsageEvent,
        onEvents: (String, [UsageEvent], Bool) throws -> Void
    ) throws {
        var batch: [UsageEvent] = []
        try autoreleasepool {
            for lineData in segment.split(separator: UInt8(ascii: "\n")) {
                let line = String(decoding: lineData, as: UTF8.self)
                if let event = parseLine(line, modified) {
                    batch.append(makeEvent(event, path))
                }
            }
        }
        if !batch.isEmpty {
            try onEvents(path, batch, reset)
        } else if reset {
            // Segmento sem eventos em arquivo que encolheu: o primeiro callback
            // carrega o sinal de reset (ledger zera a soma do arquivo).
            try onEvents(path, [], true)
        }
    }

    private static func scanJSONL(under directory: URL) throws -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        )
        while let item = enumerator?.nextObject() as? URL {
            let isRegular = (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegular && item.pathExtension == "jsonl" {
                files.append(item.path)
            }
        }
        return files.sorted()
    }
}
