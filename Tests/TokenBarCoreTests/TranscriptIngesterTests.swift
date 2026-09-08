import Foundation
import Testing
@testable import TokenBarCore

@Suite
final class TranscriptIngesterTests: Sendable {
    private let fixedDate = Date(timeIntervalSince1970: 1_788_000_000)
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Parser de teste: linha "T<tokens>" vira evento de output=<tokens>; qualquer outra coisa → nil.
    private func countingParser(_ line: String, _ mod: Date) -> UsageEvent? {
        guard line.hasPrefix("T"), let n = Int64(line.dropFirst()) else { return nil }
        return UsageEvent(
            ts: mod, provider: .claude,
            account: AccountID(provider: .claude, key: "local"), model: nil,
            inputTokens: 0, outputTokens: n, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
        )
    }

    private func identityTag(_ e: UsageEvent, _ path: String) -> UsageEvent { e }

    private func path(_ name: String) -> String { dir.resolvingSymlinksInPath().appendingPathComponent(name).path }

    @Test
    func testFirstIngestReadsWholeFile() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results.count == 1)
        #expect(results[0].newEvents.map(\.outputTokens) == [10, 20, 30])
        #expect(Int(results[0].cursor.offset) == 12, "3 linhas de 4 bytes, tudo consumido")
        #expect(!results[0].resetToZero)
    }

    @Test
    func testSecondIngestReadsOnlyAppend() throws {
        try "T10\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let sizeAfterFirst = try FileManager.default
            .attributesOfItem(atPath: path("a.jsonl"))[.size] as! Int64

        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("a.jsonl"))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("T70\n".utf8))
        try handle.close()

        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(second.count == 1)
        #expect(second[0].newEvents.map(\.outputTokens) == [70])
        #expect(Int(second[0].cursor.offset) == Int(sizeAfterFirst) + 4)
    }

    @Test
    func testIncompleteTrailingLineIsNotConsumed() throws {
        try "T10\nT2".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results[0].newEvents.map(\.outputTokens) == [10], "'T2' sem \\n não vira evento")
        #expect(Int(results[0].cursor.offset) == 4, "cursor para depois do 1º \\n")
    }

    @Test
    func testTruncatedFileResetsToZero() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(first[0].cursor.offset > 0)

        try "T99\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(second[0].resetToZero)
        #expect(second[0].newEvents.map(\.outputTokens) == [99])
    }

    @Test
    func testGarbageLinesAreSkippedButConsumed() throws {
        try "X\nT10\nBROKEN\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results[0].newEvents.map(\.outputTokens) == [10, 20])
    }

    @Test
    func testUnchangedFileIsNotReturned() throws {
        try "T10\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(second.isEmpty)
    }

    @Test
    func testSubdirectoriesAreScanned() throws {
        let sub = dir.appendingPathComponent("proj-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "T10\n".write(to: sub.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results.count == 1)
    }

    /// Orçamento spec §7: ingest de 10k eventos < 1 s.
    @Test
    func testTenThousandEventsUnderOneSecond() throws {
        var big = ""
        big.reserveCapacity(60_000)
        for i in 0..<10_000 { big += "T\(i % 1000)\n" }
        try big.write(to: dir.appendingPathComponent("big.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let start = Date()
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let elapsed = Date().timeIntervalSince(start)
        #expect(results[0].newEvents.count == 10_000)
        #expect(elapsed < 1.0, "ingest de 10k levou \(elapsed)s")
    }

    /// Red Team T8 (P1 NOVO, subconta silenciosa): linha maior que a janela de
    /// streaming (262 KB) ativa o modo skip; quando o ARQUIVO TERMINA perto da
    /// saída do skip, o drainOnce final só religa o modo normal e deixava a
    /// cauda pendente SEM parsear — e o cursor consumiu os bytes: as linhas
    /// seguintes se perdiam PARA SEMPRE (repro real: corpus com linha de 5 MB
    /// zerava o total do arquivo; transcript com paste gigante subcontava).
    @Test
    func linesAfterOversizedLineAreStillCounted() throws {
        let oversized = String(repeating: "a", count: 300_000)  // > windowSize (262_144)
        try (oversized + "\nT42\nT43\n").write(to: dir.appendingPathComponent("ov.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results.count == 1)
        #expect(results[0].newEvents.map(\.outputTokens) == [42, 43], "cauda após linha oversized é perdida")
        let size = try FileManager.default.attributesOfItem(atPath: path("ov.jsonl"))[.size] as! Int64
        #expect(Int(results[0].cursor.offset) == Int(size), "cursor cobre o arquivo inteiro")
    }

    /// Mesma família: múltiplas linhas na cauda pós-oversized dentro da MESMA
    /// leitura final — todas têm de sobreviver.
    @Test
    func multipleLinesAfterOversizedLineSurvive() throws {
        let oversized = String(repeating: "x", count: 500_000)
        try (oversized + "\nT1\nT2\nT3\n").write(to: dir.appendingPathComponent("ov2.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results[0].newEvents.map(\.outputTokens) == [1, 2, 3])
    }

    /// Skip no fim do arquivo SEM \n depois da linha oversized: cursor exato,
    /// sem loop e sem contar lixo.
    @Test
    func oversizedAtEOFWithoutTrailingNewlineKeepsCursorExact() throws {
        let oversized = String(repeating: "y", count: 300_000)  // sem \n final
        try oversized.write(to: dir.appendingPathComponent("ov3.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(results[0].newEvents.isEmpty)
        #expect(Int(results[0].cursor.offset) == 300_000, "cursor consome exatamente a linha descartada")
    }

    // MARK: - Red Team caso 2: núcleo streaming (memória limitada por lote)

    /// Aceita "T<n>,<padding qualquer>" — permite linhas longas (arquivo > chunk)
    /// mantendo um token numérico por linha.
    private func tolerantParser(_ line: String, _ mod: Date) -> UsageEvent? {
        guard line.hasPrefix("T"),
              let n = Int64(line.dropFirst().split(separator: ",", maxSplits: 1).first ?? "")
        else { return nil }
        return UsageEvent(
            ts: mod, provider: .claude,
            account: AccountID(provider: .claude, key: "local"), model: nil,
            inputTokens: 0, outputTokens: n, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
        )
    }

    /// Regressão caso 2: arquivo maior que a janela de chunk (256 KB) precisa
    /// ser entregue em MÚLTIPLOS lotes (propriedade que limita o pico de
    /// memória) sem perder nenhum evento e com cursor idêntico ao da API de array.
    @Test
    func testStreamingDeliversLargeFileInBoundedBatches() throws {
        let lineCount = 6_000  // ~200 B/linha ≈ 1,2 MB > chunk de 256 KB
        var body = ""
        body.reserveCapacity(lineCount * 210)
        for i in 0..<lineCount { body += "T\(i % 1_000),padding____0123456789____0123456789____0123456789\n" }
        try body.write(to: dir.appendingPathComponent("wide.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: tolerantParser)

        var deliveries: [(events: Int, reset: Bool)] = []
        let updates = try ingester.ingestChangedFilesStreaming(
            under: dir,
            cursors: [:],
            makeEvent: identityTag
        ) { _, events, reset, _ in
            deliveries.append((events.count, reset))
        }
        let totalEvents = deliveries.reduce(0) { $0 + $1.events }
        #expect(totalEvents == lineCount, "nenhum evento perdido no streaming")
        #expect(deliveries.count >= 2, "arquivo > chunk precisa de \(deliveries.count) entregas múltiplas")
        #expect(deliveries.allSatisfy { $0.reset == false })
        #expect(updates.count == 1 && !updates[0].resetToZero)
        #expect(Int(updates[0].cursor.offset) == body.utf8.count)
    }

    /// Regressão caso 2/3: truncamento a ZERO emite update de cursor 0 e
    /// callback de reset mesmo sem linhas novas — o ledger zera a soma do
    /// arquivo (antes o cursor ficava retido e o total ficava stale até o
    /// próximo append).
    @Test
    func testTruncateToZeroEmitsResetEvenWithoutNewLines() throws {
        try "T10\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        #expect(first[0].cursor.offset > 0)

        try "".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        var resets = 0
        let updates = try ingester.ingestChangedFilesStreaming(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        ) { _, events, reset, _ in
            if reset { resets += 1 }
            #expect(events.isEmpty)
        }
        #expect(resets == 1, "reset sinalizado sem linhas novas")
        #expect(updates.count == 1)
        #expect(updates[0].cursor.offset == 0)
        #expect(updates[0].resetToZero)

        // API de array mantém o mesmo contrato
        let viaArray = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        )
        #expect(viaArray.count == 1)
        #expect(viaArray[0].resetToZero)
        #expect(viaArray[0].newEvents.isEmpty)
        #expect(viaArray[0].cursor.offset == 0)
    }

    /// Regressão caso 3: truncamento parcial (arquivo encolhe mas permanece com
    /// linhas completas) reinicia do zero e sinaliza reset.
    @Test
    func testStreamingResetFlagOnlyOnFirstBatchOfShrunkFile() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)

        try "T99\nT88\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        var deliveries: [(events: [Int], reset: Bool)] = []
        let updates = try ingester.ingestChangedFilesStreaming(
            under: dir,
            cursors: [first[0].path: first[0].cursor],
            makeEvent: identityTag
        ) { _, events, reset, _ in
            deliveries.append((events.map { Int($0.outputTokens) }, reset))
        }
        let flat = deliveries.flatMap(\.events)
        #expect(flat == [99, 88])
        #expect(deliveries.first?.reset == true, "primeiro lote carrega o reset")
        #expect(deliveries.dropFirst().allSatisfy { !$0.reset }, "reset não se repete entre lotes")
        #expect(updates[0].resetToZero)
    }

    /// Cauda parcial atravessando o limite de chunk não é consumida nem duplicada.
    @Test
    func testStreamingCarriesPartialLineAcrossChunks() throws {
        var body = ""
        for i in 0..<3_000 { body += "T\(i % 1_000),x____0123456789\n" }  // ~75 KB, 1 chunk e pouco
        body += "T7"  // cauda sem \n
        try body.write(to: dir.appendingPathComponent("tail.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: tolerantParser)

        var total = 0
        let updates = try ingester.ingestChangedFilesStreaming(
            under: dir,
            cursors: [:],
            makeEvent: identityTag
        ) { _, events, _, _ in total += events.count }
        #expect(total == 3_000)
        #expect(Int(updates[0].cursor.offset) == body.utf8.count - 2, "cauda 'T7' fica para o próximo ciclo")
    }
}
