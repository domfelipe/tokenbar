import Foundation
import GRDB
import Testing
@testable import TokenBarCore

// ============================================================================
// Red Team F4 (Task 4) — Casos 1 (pacing com DB adversarial) e higiene do
// FileKind. Complementa PacingTests (caminho feliz/boundaries) com os valores
// hostis que um banco corrompido/bugado pode conter: nunca crashar, nunca
// forecast não-finito ou absurdo (saturação documentada vale).
// ============================================================================
@Suite
final class RedTeamF4Tests {
    let utc: Calendar
    /// 2026-08-30T00:00:00Z (meia-noite UTC — dias alinhados, padrão F4).
    let now = Date(timeIntervalSince1970: 1_788_048_000)

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        utc = cal
    }

    func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    func window(
        kind: WindowKind = .weekly, usedFraction: Double?, resetsAt: Date?
    ) -> UsageWindow {
        UsageWindow(kind: kind, usedFraction: usedFraction, resetsAt: resetsAt, label: "RT")
    }

    // MARK: - Caso 1a: totais adversariais na regressão

    @Test("pacing: Int64.max + negativos → sem crash, resultado finito ou nil")
    func hostileTotalsStayFinite() {
        let hostile: [Int64] = [.max, -50, .max, 0, -1]
        let sums = hostile.enumerated().map { (day: day($0.offset - 4), total: $0.element) }
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(3)),
            now: now, calendar: utc)
        // Qualquer forecast devolvido é FINITO e ordenável (saturação 1e6).
        if let forecast = f {
            #expect(forecast.projectedFraction.isFinite)
            #expect(forecast.projectedFraction >= 0)
            #expect(forecast.projectedFraction <= PacingEngine.maxProjectedFraction)
            if let deficit = forecast.deficitPct {
                #expect(deficit.isFinite && deficit >= 0)
            }
            if let exhausted = forecast.exhaustedIn {
                #expect(exhausted.isFinite && exhausted >= 0)
            }
        }
    }

    @Test("pacing: todos os totais negativos são descartados (dados corrompidos → <2 pontos → nil)")
    func allNegativeTotalsYieldNil() {
        let sums = [(-3, Int64(-100)), (-2, Int64(-7)), (-1, Int64(-1_000)), (0, Int64(-42))].map {
            (day: day($0.0), total: $0.1)
        }
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(3)),
            now: now, calendar: utc)
        #expect(f == nil, "negativo é corrupção — descartado, nunca uso negativo")
    }

    @Test("pacing: 1 ponto de dados → nil (sem tendência, mesmo com janela completa)")
    func singlePointYieldsNil() {
        let f = PacingEngine.forecast(
            dailySums: [(day: day(0), total: 4_000_000)],
            window: window(usedFraction: 0.9, resetsAt: day(1)),
            now: now, calendar: utc)
        #expect(f == nil)
    }

    @Test("pacing: resetsAt no PASSADO → projeção = uso atual (horizonte zero, nunca esgotamento negativo)")
    func resetInPastIsFlat() {
        let sums = [(day: day(-2), total: Int64(1_000_000)), (day: day(-1), total: Int64(5_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.74, resetsAt: day(-1)),
            now: now, calendar: utc)
        let forecast = try? #require(f)
        #expect(forecast?.exhaustedIn == nil)
        #expect(forecast?.projectedFraction == 0.74)
        #expect(forecast?.deficitPct == nil)
    }

    @Test("pacing: fração adversarial (NaN, infinito, fora de 0...1) → nil ou saturada, nunca crash")
    func hostileFractionsDegrade() {
        let sums = [(day: day(-1), total: Int64(100)), (day: day(0), total: Int64(200))]
        for fraction: Double in [.nan, .infinity, -.infinity, -0.7, 1.7, .pi * 1_000] {
            let f = PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: fraction, resetsAt: day(2)),
                now: now, calendar: utc)
            if let forecast = f {
                #expect(forecast.projectedFraction.isFinite)
                #expect(forecast.projectedFraction <= PacingEngine.maxProjectedFraction)
            }
        }
        // NaN → nil explícito (isFinite reprova a âncora).
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: .nan, resetsAt: day(2)),
                now: now, calendar: utc) == nil)
    }

    @Test("pacing: resetsAt distante (ano 9999) com taxa gigante → saturação finita, sem overflow")
    func distantResetSaturates() {
        let sums = [(day: day(-1), total: Int64(1)), (day: day(0), total: Int64(Int64.max / 2))]
        let farFuture = Date(timeIntervalSince1970: 253_402_300_799)  // 9999-12-31
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: farFuture),
            now: now, calendar: utc)
        if let forecast = f {
            #expect(forecast.projectedFraction.isFinite)
            #expect(forecast.projectedFraction <= PacingEngine.maxProjectedFraction)
            if let deficit = forecast.deficitPct { #expect(deficit.isFinite) }
        }
    }

    // MARK: - Caso 1b: DB adversarial → pacingInput

    @Test("pacingInput: day strings não-ISO descartadas; ISO leniente rola; agregado negativo só morre no ENGINE")
    func hostileDailyAggRowsAreDiscarded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(at: dir.appendingPathComponent("db.sqlite"), calendar: utc)

        // INSERT hostil DIRETO no daily_agg (por baixo da camada de ingest):
        // dia malformado, dia "-2026-..." (porta fechável do minor T1),
        // ISO leniente ("2026-13-99" ROLA para data real — leniência do
        // Calendar do Foundation, documentada), agregado NEGATIVO e um dia
        // legítimo.
        try db.writer.write { db in
            func row(_ day: String, _ input: Int64, _ output: Int64) throws {
                try db.execute(
                    sql: """
                        INSERT INTO daily_agg
                          (day, provider, account, model, input_tokens, output_tokens,
                           cache_read_tokens, cache_write_tokens, cost_usd)
                        VALUES (?, 'claude', 'local', 'm', ?, ?, 0, 0, NULL)
                        """,
                    arguments: [day, input, output])
            }
            try row("garbage", 10, 10)          // dia não-ISO → descartado
            try row("-2026-08-30", 10, 10)      // dia com prefixo "-" (minor T1) → descartado
            try row("2026-08-30", -5_000, -100)  // agregado NEGATIVO (corrupção)
            try row("2026-08-29", 1_000, 500)   // legítimo: 1_500
        }

        let input = try db.pacingInput(provider: .claude, account: AccountID(provider: .claude, key: "local"), days: 30, now: now)
        // Contrato REAL da query: descarta o que não parseia; agregado cru
        // (mesmo negativo) atravessa — a defesa contra negativo é do ENGINE.
        #expect(input.contains { $0.total == 1_500 }, "dia legítimo presente")
        #expect(input.allSatisfy { $0.day.timeIntervalSinceReferenceDate.isFinite })

        // O PacingEngine NUNCA usa o agregado negativo como uso: o resultado
        // (sobre os pontos válidos que restarem) é finito e não-negativo.
        let f = PacingEngine.forecast(
            dailySums: input, window: window(usedFraction: 0.5, resetsAt: day(3)),
            now: now, calendar: utc)
        if let forecast = f {
            #expect(forecast.projectedFraction.isFinite)
            #expect(forecast.projectedFraction >= 0)
            #expect(forecast.projectedFraction <= PacingEngine.maxProjectedFraction)
        }
        // E com SÓ pontos negativos (tudo corrupção): <2 pontos válidos → nil.
        let onlyNegative = [(day: day(-1), total: Int64(-10)), (day: day(0), total: Int64(-20))]
        #expect(
            PacingEngine.forecast(
                dailySums: onlyNegative, window: window(usedFraction: 0.5, resetsAt: day(3)),
                now: now, calendar: utc) == nil)
    }

    // MARK: - FileKind (higiene compartilhada do caso 4)

    @Test("FileKind: regular file vs. diretório vs. inexistente vs. FIFO")
    func fileKindClassification() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let regular = dir.appendingPathComponent("cred.json")
        try Data("{}".utf8).write(to: regular)
        let sub = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("pipe")
        mkfifo(fifo.path, 0o644)

        #expect(FileKind.isRegularFile(atPath: regular.path))
        #expect(!FileKind.isRegularFile(atPath: sub.path))
        #expect(!FileKind.isRegularFile(atPath: fifo.path), "FIFO nunca é 'legível' — open() bloquearia sem escritor")
        #expect(!FileKind.isRegularFile(atPath: dir.appendingPathComponent("missing").path))
        #expect(FileKind.isDirectory(atPath: sub.path))
        #expect(!FileKind.isDirectory(atPath: regular.path))
        #expect(!FileKind.isDirectory(atPath: fifo.path))

        // Symlink para regular file é regular (leitura legítima); quebrado não é.
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(FileKind.isRegularFile(atPath: link.path))
        let dangling = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: dir.appendingPathComponent("nope.json"))
        #expect(!FileKind.isRegularFile(atPath: dangling.path))

        // Link → FIFO: o tipo FINAL é pipe, nunca regular (link não "lava" o alvo).
        let linkFifo = dir.appendingPathComponent("link-fifo")
        try FileManager.default.createSymbolicLink(at: linkFifo, withDestinationURL: fifo)
        #expect(!FileKind.isRegularFile(atPath: linkFifo.path))
    }
}
