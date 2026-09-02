import Foundation

public struct FileIngestResult: Sendable, Equatable {
    public let path: String
    public let newEvents: [UsageEvent]
    public let cursor: FileCursor
    public let resetToZero: Bool
}

public struct TranscriptIngester: Sendable {
    private let parseLine: @Sendable (String, Date) -> UsageEvent?

    public init(parseLine: @escaping @Sendable (String, Date) -> UsageEvent?) {
        self.parseLine = parseLine
    }

    public func ingestChangedFiles(
        under directory: URL,
        cursors: [String: FileCursor],
        makeEvent: (UsageEvent, String) -> UsageEvent
    ) throws -> [FileIngestResult] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        var results: [FileIngestResult] = []
        for path in try Self.scanJSONL(under: directory) {
            let attrs = try fm.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()
            let previous = cursors[path]?.offset ?? 0

            // Inalterado (nada além do cursor): pula. Encolheu: reset.
            guard size != previous else { continue }
            let startOffset: UInt64 = size < previous ? 0 : previous
            let reset = size < previous

            guard size > startOffset, let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            if startOffset > 0 { try? handle.seek(toOffset: startOffset) }
            let chunk = (try? handle.read(upToCount: Int(size - startOffset))) ?? Data()

            // Só consome até o último \n; cauda parcial fica pro próximo ciclo.
            let consumed: Data
            if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                consumed = Data(chunk[chunk.startIndex...lastNewline])
            } else {
                consumed = Data()
            }
            if consumed.isEmpty { continue }

            var events: [UsageEvent] = []
            for lineData in consumed.split(separator: UInt8(ascii: "\n")) {
                let line = String(decoding: lineData, as: UTF8.self)
                if let event = parseLine(line, modified) {
                    events.append(makeEvent(event, path))
                }
            }

            results.append(FileIngestResult(
                path: path,
                newEvents: events,
                cursor: FileCursor(offset: startOffset + UInt64(consumed.count)),
                resetToZero: reset
            ))
        }
        return results
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
