import Foundation
import GRDB
import Testing
@testable import TokenBarCore

// ============================================================================
// F4 Task 1 — PacingEngine (regressão sobre agregados diários).
//
// Números esperados calculados À MÃO (mínimos quadrados em papel), nunca
// re-derivados pelo mesmo código do engine. Fixtures em UTC fixo, dias
// alinhados à meia-noite → windowStart (resetsAt − span) cai exato.
// ============================================================================
@Suite
final class PacingEngineTests {
    /// Calendar UTC fixo (determinístico em qualquer máquina/DST).
    let utc: Calendar
    /// now fixo: 2026-08-30T00:00:00Z (meia-noite — dias alinhados).
    let now = Date(timeIntervalSince1970: 1_788_048_000)

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        utc = cal
    }

    /// Dia `offset` relativo a now (UTC, sem DST).
    func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    func window(
        kind: WindowKind = .weekly, usedFraction: Double?, resetsAt: Date?
    ) -> UsageWindow {
        UsageWindow(kind: kind, usedFraction: usedFraction, resetsAt: resetsAt, label: "Teste")
    }

    @Test("crescente que estoura: exhaustedIn finito, projected > 1, deficit > 0")
    func risingExhausts() throws {
        // d-1 = 1M, d0 = 5M → slope EXATA 4M/dia (2 pontos colineares).
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        // Semanal, renova em +4d → início = resetsAt−7d = d-3 → ambos os dias
        // na janela: windowTokens = 6M; capacidade = 6M/0.4 = 15M.
        // Adicional = 4M × 4d = 16M → +16/15 → projected = 1.4666…
        // Dias até 1.0: (15M−6M)/4M = 2.25d → 194_400 s.
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.4, resetsAt: day(4)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        let exhausted = try #require(forecast.exhaustedIn)
        #expect(approx(exhausted, 194_400))
        #expect(approx(forecast.projectedFraction, 22.0 / 15.0))
        let deficit = try #require(forecast.deficitPct)
        #expect(approx(deficit, (7.0 / 15.0) * 100))
    }

    @Test("crescente que NÃO estoura: projected < 1, exhaustedIn e deficit nil")
    func risingWithinBudget() throws {
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        // uf 0.2 → capacidade 30M; adicional 16M → +16/30 → projected 0.7333…
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.2, resetsAt: day(4)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.exhaustedIn == nil)
        #expect(forecast.deficitPct == nil)
        #expect(approx(forecast.projectedFraction, 0.2 + 16.0 / 30.0))
    }

    @Test("flat (taxa zero): projected = usedFraction, exhaustedIn nil")
    func flatIsNoExhaustion() throws {
        let sums = (0...4).map { (day: day($0 - 4), total: Int64(1_000_000)) }
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.6, resetsAt: day(2)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0.6)
        #expect(forecast.exhaustedIn == nil)
        #expect(forecast.deficitPct == nil)
    }

    @Test("decrescente (taxa negativa): projected = usedFraction, exhaustedIn nil")
    func fallingIsNoExhaustion() throws {
        let sums = [(day: day(-1), total: Int64(5_000_000)), (day: day(0), total: Int64(1_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.9, resetsAt: day(4)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0.9)
        #expect(forecast.exhaustedIn == nil)
        #expect(forecast.deficitPct == nil)
    }

    @Test("honestidade: 0 e 1 pontos → nil")
    func tooFewPointsIsNil() {
        let w = window(usedFraction: 0.9, resetsAt: day(4))
        #expect(PacingEngine.forecast(dailySums: [], window: w, now: now, calendar: utc) == nil)
        #expect(
            PacingEngine.forecast(
                dailySums: [(day: day(0), total: 1_000_000)], window: w, now: now, calendar: utc)
                == nil)
    }

    @Test("honestidade: resetsAt nil → nil (nunca chuta)")
    func noResetIsNil() {
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: 0.9, resetsAt: nil),
                now: now, calendar: utc) == nil)
    }

    @Test("honestidade: usedFraction nil ou não-finita → nil")
    func noFractionIsNil() {
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: nil, resetsAt: day(4)),
                now: now, calendar: utc) == nil)
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: .nan, resetsAt: day(4)),
                now: now, calendar: utc) == nil)
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: .infinity, resetsAt: day(4)),
                now: now, calendar: utc) == nil)
    }

    @Test("todos os pontos no mesmo dia: sem variação temporal → nil")
    func sameDayIsNil() {
        let sums = [(day: day(0), total: Int64(1_000_000)), (day: day(0), total: Int64(2_000_000))]
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(4)),
                now: now, calendar: utc) == nil)
    }

    @Test("gap de dias usa DATA real (não zero-fill, não índice): slope = 1M/dia")
    func gapUsesRealDates() throws {
        // d-3 = 1M, d0 = 4M, 3 dias de distância → slope 1M/dia.
        // (Por índice seria 1.5M/dia — este assert distingue.)
        let sums = [(day: day(-3), total: Int64(1_000_000)), (day: day(0), total: Int64(4_000_000))]
        // Semanal +2d → início d-5 → windowTokens 5M; uf 0.5 → capacidade 10M;
        // adicional 1M×2d = 2M → +0.2 → projected 0.7.
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(2)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(approx(forecast.projectedFraction, 0.7))
        #expect(forecast.exhaustedIn == nil)
    }

    @Test("adversarial: subida ~Int64.max → projeção finita, sem crash")
    func int64MaxRiseIsFinite() throws {
        let max = Int64.max
        let sums = [(day: day(-1), total: Int64(0)), (day: day(0), total: max)]
        // windowTokens = max (soma saturante); capacidade = max/0.9;
        // slope = max/dia; adicional = max×1d → +0.9 → projected ≈ 1.8;
        // dias até 1.0: (max/0.9 − max)/max = 1/0.9 − 1 ≈ 0.1111d ≈ 9_600 s.
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.9, resetsAt: day(1)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction.isFinite)
        #expect(approx(forecast.projectedFraction, 1.8))
        let deficit = try #require(forecast.deficitPct)
        #expect(deficit.isFinite)
        #expect(approx(deficit, 80))
        let exhausted = try #require(forecast.exhaustedIn)
        #expect(exhausted.isFinite)
        #expect(approx(exhausted, 9_600))
    }

    @Test("adversarial: dois dias ~Int64.max → flat, sem crash")
    func int64MaxFlatIsNoExhaustion() throws {
        let max = Int64.max
        let sums = [(day: day(-1), total: max), (day: day(0), total: max)]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.9, resetsAt: day(1)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0.9)
        #expect(forecast.exhaustedIn == nil)
        #expect(forecast.deficitPct == nil)
    }

    @Test("adversarial: pontos separados por dias gigantes → finito, sem crash")
    func giantDaySpansAreFinite() throws {
        // d0 e d0 + 1e9 dias → slope = 1M/1e9 dias ≈ 0.001 tok/dia.
        let farFuture = now.addingTimeInterval(1_000_000_000 * 86_400)
        let sums = [(day: day(0), total: Int64(1_000_000)), (day: farFuture, total: Int64(2_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(1)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction.isFinite)
        #expect(approx(forecast.projectedFraction, 0.5))
        #expect(forecast.exhaustedIn == nil)
        #expect(forecast.deficitPct == nil)
    }

    @Test("adversarial: total negativo é dado corrompido → descartado, não vira uso")
    func negativeTotalsAreDiscarded() throws {
        // O dia negativo sai; restam 2 pontos → slope 1M/dia.
        // windowTokens = 1M+2M = 3M; uf 0.5 → capacidade 6M; adicional 2M
        // → projected = 0.5 + 2/6 = 0.8333…
        let sums = [
            (day: day(-2), total: Int64(-5)), (day: day(-1), total: Int64(1_000_000)),
            (day: day(0), total: Int64(2_000_000)),
        ]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(2)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(approx(forecast.projectedFraction, 0.5 + 1.0 / 3.0))
        #expect(forecast.exhaustedIn == nil)
    }

    @Test("adversarial: só totais negativos → <2 pontos válidos → nil")
    func allNegativeIsNil() {
        let sums = [(day: day(-1), total: Int64(-5)), (day: day(0), total: Int64(-7))]
        #expect(
            PacingEngine.forecast(
                dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(2)),
                now: now, calendar: utc) == nil)
    }

    @Test("janela .session: sem span derivável de agregados diários → sem projeção")
    func sessionWindowHasNoProjection() throws {
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums,
            window: window(kind: .session, usedFraction: 0.9, resetsAt: day(1)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0.9)
        #expect(forecast.exhaustedIn == nil)
    }

    @Test("usedFraction 0: relação tokens↔fração inderivável → sem projeção")
    func zeroFractionHasNoProjection() throws {
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0, resetsAt: day(4)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0)
        #expect(forecast.exhaustedIn == nil)
    }

    @Test("resetsAt no passado: horizonte zero → projeção = uso atual")
    func pastResetProjectsNothing() throws {
        let sums = [(day: day(-1), total: Int64(1_000_000)), (day: day(0), total: Int64(5_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.9, resetsAt: day(-1)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0.9)
        #expect(forecast.exhaustedIn == nil)
        #expect(forecast.deficitPct == nil)
    }

    @Test("sem dados dentro do início da janela: relação inderivável → sem projeção")
    func noDataInsideWindowHasNoProjection() throws {
        // Pontos só ANTES do início da janela semanal (d-6): windowTokens = 0.
        let sums = [(day: day(-8), total: Int64(1_000_000)), (day: day(-7), total: Int64(2_000_000))]
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.9, resetsAt: day(1)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(forecast.projectedFraction == 0.9)
        #expect(forecast.exhaustedIn == nil)
    }

    @Test("regressão usa os ÚLTIMOS 14 pontos (boundary de dias)")
    func regressionCapsAt14Points() throws {
        // 15 pontos: d-14 = 100M (fora do cap) e d-13…d0 = 1M…14M (slope 1M).
        var sums = [(day: day(-14), total: Int64(100_000_000))]
        sums += (0...13).map { (day: day($0 - 13), total: Int64(($0 + 1) * 1_000_000)) }
        #expect(sums.count == 15)
        // Início semanal (resetsAt +2d) = d-5 → windowTokens = 9M+…+14M = 69M
        // (d-5 carrega 9M: d0=14M − 5); uf 0.5 → capacidade 138M;
        // adicional 1M×2d = 2M → 0.5 + 2/138 = 0.5 + 1/69.
        let f = PacingEngine.forecast(
            dailySums: sums, window: window(usedFraction: 0.5, resetsAt: day(2)),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(approx(forecast.projectedFraction, 0.5 + 1.0 / 69.0))
    }
}

// ============================================================================
// pacingInput (HistoryQueries) — o dado real alimenta o engine.
// ============================================================================
@Suite
final class PacingInputTests {
    let dir: URL
    /// Calendar UTC FIXO (mesma convenção dos readers da F3).
    let utc: Calendar
    /// now fixo: 2026-08-30T10:40:00Z.
    let now = Date(timeIntervalSince1970: 1_788_086_400)
    let db: AppDatabase

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-pacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        utc = cal
        db = try AppDatabase.open(
            at: dir.appendingPathComponent(AppDatabase.databaseName),
            calendar: utc, pricing: PricingTable(version: 1, updated: "2026-01-01", models: [:]))
        try seed()
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func event(
        _ ts: Date, provider: ProviderID, accountKey: String,
        input: Int64, output: Int64
    ) -> UsageEvent {
        UsageEvent(
            ts: ts, provider: provider,
            account: AccountID(provider: provider, key: accountKey),
            model: nil, inputTokens: input, outputTokens: output,
            cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)
    }

    /// claude/local: d-1 = 1M tok, d0 = 3M tok (1M in + 2M out em 2 eventos).
    /// claude/second: d0 = 1M tok (outra conta). codex/local: d0 = 500k.
    private func seed() throws {
        let today = utc.startOfDay(for: now)
        func day(_ offset: Int) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
        try db.persistBatch(
            provider: .claude, path: "/x/a.jsonl",
            events: [
                event(day(-1).addingTimeInterval(12 * 3_600), provider: .claude, accountKey: "local",
                      input: 400_000, output: 600_000),
                event(day(0).addingTimeInterval(9 * 3_600), provider: .claude, accountKey: "local",
                      input: 1_000_000, output: 0),
                event(day(0).addingTimeInterval(9.5 * 3_600), provider: .claude, accountKey: "local",
                      input: 0, output: 2_000_000),
                event(day(0).addingTimeInterval(10 * 3_600), provider: .claude, accountKey: "second",
                      input: 1_000_000, output: 0),
            ], endOffset: 10_000, resetToZero: false)
        try db.persistBatch(
            provider: .codex, path: "/x/b.jsonl",
            events: [
                event(day(0).addingTimeInterval(11 * 3_600), provider: .codex, accountKey: "local",
                      input: 500_000, output: 0),
            ], endOffset: 5_000, resetToZero: false)
    }

    @Test("pacingInput: série por (provider, conta) com dias no calendar do banco")
    func pacingInputSeriesAndFilters() throws {
        let local = AccountID(provider: .claude, key: "local")
        let rows = try db.pacingInput(provider: .claude, account: local, days: 7, now: now)
        // d-1 00:00Z e d0 00:00Z — início do dia no calendar injetado.
        let expectedDays = [
            Date(timeIntervalSince1970: 1_788_048_000 - 86_400),
            Date(timeIntervalSince1970: 1_788_048_000),
        ]
        #expect(rows.map(\.day) == expectedDays)
        #expect(rows.map(\.total) == [1_000_000, 3_000_000])

        // Filtro por CONTA: a "second" só tem o dia de hoje.
        let second = AccountID(provider: .claude, key: "second")
        let secondRows = try db.pacingInput(provider: .claude, account: second, days: 7, now: now)
        #expect(secondRows.map(\.total) == [1_000_000])

        // Filtro por PROVIDER: codex isolado.
        let codexRows = try db.pacingInput(
            provider: .codex, account: AccountID(provider: .codex, key: "local"), days: 7, now: now)
        #expect(codexRows.map(\.total) == [500_000])

        // Provider sem histórico → vazio.
        let empty = try db.pacingInput(
            provider: .zai, account: AccountID(provider: .zai, key: "local"), days: 7, now: now)
        #expect(empty.isEmpty)
    }

    @Test("pacingInput → PacingEngine: integração com números exatos (estoura)")
    func pacingInputFeedsEngine() throws {
        let rows = try db.pacingInput(
            provider: .claude, account: AccountID(provider: .claude, key: "local"), days: 7, now: now)
        // Semanal uf 0.5, renova em +4d → início = resetsAt−7d = now−3d
        // (2026-08-27 10:40) → AMBOS os dias (d-1 e d0) dentro: windowTokens =
        // 4M; capacidade 8M; slope 2M/dia; adicional 8M → +1.0 → projected
        // 1.5; dias até 1.0: (8M−4M)/2M = 2d = 172_800 s.
        let f = PacingEngine.forecast(
            dailySums: rows,
            window: UsageWindow(
                kind: .weekly, usedFraction: 0.5, resetsAt: now.addingTimeInterval(4 * 86_400),
                label: "Semanal"),
            now: now, calendar: utc)
        let forecast = try #require(f)
        #expect(approx(forecast.projectedFraction, 1.5))
        let deficit = try #require(forecast.deficitPct)
        #expect(approx(deficit, 50))
        let exhausted = try #require(forecast.exhaustedIn)
        #expect(approx(exhausted, 172_800))
    }

    @Test("parse de day string: inverso do dayString; lixo → nil (nunca inventa data)")
    func dayStringParsing() throws {
        let expected = Date(timeIntervalSince1970: 1_788_048_000)
        #expect(AppDatabase.date(fromDayString: "2026-08-30", calendar: utc) == expected)
        #expect(db.dayString(from: expected) == "2026-08-30")
        #expect(AppDatabase.date(fromDayString: "2026/08/30", calendar: utc) == nil)
        #expect(AppDatabase.date(fromDayString: "abc", calendar: utc) == nil)
        #expect(AppDatabase.date(fromDayString: "2026-08", calendar: utc) == nil)
        #expect(AppDatabase.date(fromDayString: "", calendar: utc) == nil)
    }
}

/// Aproximação com tolerância relativa 1e-6 (floating point dos mínimos
/// quadrados) — função, não operador custom: `#expect` do Swift Testing
/// exige operador declarado e a precedência de operadores custom morde.
private func approx(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 1e-6 * max(1.0, abs(a), abs(b))
}
