import Foundation
import Testing
@testable import TokenBarCore

/// Contador de fires com barreira: start/finish contam entrada/saída de onFire;
/// park() bloqueia o fire em curso até releaseAll() (p/ provar single-flight).
private actor FireRecorder {
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var maxConcurrent = 0
    private var current = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    func start() {
        started += 1
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func finish() {
        current -= 1
        finished += 1
    }

    func park() async {
        await withCheckedContinuation { parked.append($0) }
    }

    func releaseAll() {
        for continuation in parked { continuation.resume() }
        parked.removeAll()
    }
}

/// Roteiro de resultados que o onFire reporta ao scheduler (mesma ordem do
/// wiring real: noteResult acontece dentro do fire, antes de ele terminar).
private actor ResultScript {
    private let entries: [(ok: Bool, pressure: Double?)]
    private var index = 0

    init(_ entries: [(ok: Bool, pressure: Double?)]) {
        self.entries = entries
    }

    func next() -> (ok: Bool, pressure: Double?) {
        defer { index += 1 }
        return index < entries.count ? entries[index] : (true, nil)
    }
}

/// Sequência de intervalos do AdaptiveScheduler (spec §7) com clock virtual.
/// `random: { 0 }` elimina o jitter (intervalo exato); `{ ±1 }` trava os
/// bounds de ±10%.
@Suite
struct SchedulerTests {
    /// Tempo real mínimo para o pool cooperativo processar os wakeups virtuais.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func idleCadenceFiresEveryFiveMinutes() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(299))
        try await settle()
        #expect(await recorder.started == 0, "299 s < 5 min: ainda não disparou")

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 1, "primeiro fire aos 5 min")

        clock.advance(by: .seconds(299))
        try await settle()
        #expect(await recorder.started == 1)

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 2, "cadência ociosa: 5 em 5 min")
    }

    @Test func menuOpenedSwitchesToSixtySecondCadenceAndDecaysBackToIdle() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await recorder.started == 1)

        await scheduler.noteMenuOpened()
        try await settle()  // loop re-agendado registra o sleep ANTES de avançar o clock
        clock.advance(by: .seconds(59))
        try await settle()
        #expect(await recorder.started == 1)

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 2, "60 s após abrir o menu")

        clock.advance(by: .seconds(60))
        try await settle()
        #expect(await recorder.started == 3, "cadência do menu: 60 em 60 s")

        // Menu fechou (wiring para de reafirmar) → primeiro resultado ocioso decai.
        await scheduler.noteResult(provider: .codex, ok: true, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(299))
        try await settle()
        #expect(await recorder.started == 3)

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 4, "decaiu de volta p/ 5 min")
    }

    @Test func pressureCadenceIsThirtySecondsWithBoundaryAtPointEight() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        // noteResult dentro do fire (ordem do wiring real); 0.8 exato conta como pressão.
        let script = ResultScript([(true, 0.8), (true, 0.79)])
        await scheduler.register(provider: .codex) {
            await recorder.start()
            let result = await script.next()
            await scheduler.noteResult(provider: .codex, ok: result.ok, pressure: result.pressure)
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await recorder.started == 1)

        clock.advance(by: .seconds(29))
        try await settle()
        #expect(await recorder.started == 1, "29 s < 30 s de pressão")

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 2, "pressão 0.8 → 30 s")

        // fire2 reporta 0.79 → decai p/ ocioso (próximo fire em 300 s)
        clock.advance(by: .seconds(299))
        try await settle()
        #expect(await recorder.started == 2)

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 3, "pressão 0.79 → decaiu p/ 5 min")
    }

    @Test func errorBackoffDoublesWithThirtyMinuteCeilingAndSuccessResets() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await recorder.started == 1)

        // 1º erro: 300 → 600
        await scheduler.noteResult(provider: .codex, ok: false, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(599))
        try await settle()
        #expect(await recorder.started == 1)
        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 2)

        // 2º erro: 600 → 1200
        await scheduler.noteResult(provider: .codex, ok: false, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(1199))
        try await settle()
        #expect(await recorder.started == 2)
        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 3)

        // 3º erro: 1200 × 2 = 2400 → teto 1800
        await scheduler.noteResult(provider: .codex, ok: false, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(1799))
        try await settle()
        #expect(await recorder.started == 3)
        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 4)

        // 4º erro: permanece no teto de 30 min
        await scheduler.noteResult(provider: .codex, ok: false, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(1799))
        try await settle()
        #expect(await recorder.started == 4)
        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 5)

        // Sucesso reseta o backoff → volta a 5 min
        await scheduler.noteResult(provider: .codex, ok: true, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(299))
        try await settle()
        #expect(await recorder.started == 5)
        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 6)
    }

    @Test func backoffGrowsFromCurrentIntervalEvenInMenuMode() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        await scheduler.noteMenuOpened()
        try await settle()
        clock.advance(by: .seconds(60))
        try await settle()
        #expect(await recorder.started == 2)

        // Erro com menu aberto: 60 → 120 (×2 do intervalo atual)
        await scheduler.noteResult(provider: .codex, ok: false, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(119))
        try await settle()
        #expect(await recorder.started == 2)
        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 3)
    }

    @Test func pressureBeatsMenuInterval() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        await scheduler.noteMenuOpened()
        try await settle()
        await scheduler.noteResult(provider: .codex, ok: true, pressure: 0.9)
        try await settle()

        clock.advance(by: .seconds(29))
        try await settle()
        #expect(await recorder.started == 1)

        clock.advance(by: .seconds(1))
        try await settle()
        #expect(await recorder.started == 2, "pressão ≥ 0.8 vence o menu: 30 s")
    }

    @Test func jitterUpperBoundIsPlusTenPercent() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, jitterFraction: 0.1, random: { 1 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(329))
        try await settle()
        #expect(await recorder.started == 0, "330 s = 300 × 1.1: não dispara antes")

        // +2 s: o produto 300 × 1.1 em Duration×Double carrega poeira de fp
        // (ex.: 66.00000000000001) — o bound "não antes" é exato; o disparo
        // no próprio bound tolera 1e-14.
        clock.advance(by: .seconds(2))
        try await settle()
        #expect(await recorder.started == 1)
    }

    @Test func jitterLowerBoundIsMinusTenPercent() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, jitterFraction: 0.1, random: { -1 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(269))
        try await settle()
        #expect(await recorder.started == 0, "270 s = 300 × 0.9: não dispara antes")

        clock.advance(by: .seconds(2))
        try await settle()
        #expect(await recorder.started == 1)
    }

    @Test func jitterAppliesToMenuInterval() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, jitterFraction: 0.1, random: { 1 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(330))
        try await settle()
        await scheduler.noteMenuOpened()
        try await settle()

        clock.advance(by: .seconds(65))
        try await settle()
        #expect(await recorder.started == 1, "66 s = 60 × 1.1: não dispara antes")

        clock.advance(by: .seconds(2))
        try await settle()
        #expect(await recorder.started == 2)
    }

    @Test func singleFlightNeverRunsTwoFiresForSameProvider() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.park()
            await recorder.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await recorder.started == 1)

        // 20 intervalos passam com o fire 1 travado → nada novo dispara em paralelo
        clock.advance(by: .seconds(6000))
        try await settle()
        #expect(await recorder.started == 1, "fire em curso bloqueia novo fire")
        #expect(await recorder.maxConcurrent == 1)

        await recorder.releaseAll()
        try await settle()
        #expect(await recorder.finished == 1)

        // O fire enfileirado acontece no próximo tick, sequencial
        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await recorder.started == 2)
        #expect(await recorder.maxConcurrent == 1)
    }

    @Test func pauseStopsAllFiresAndResumeFiresImmediately() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let recorder = FireRecorder()
        await scheduler.register(provider: .codex) {
            await recorder.start()
            await recorder.finish()
        }
        try await settle()

        await scheduler.pauseForSleep()
        clock.advance(by: .seconds(30_000))
        try await settle()
        #expect(await recorder.started == 0, "pausa dispara nada (rede zero em sleep)")

        await scheduler.resumeFromSleep()
        try await settle()
        #expect(await recorder.started == 1, "resume dispara refresh imediato, sem avanço de clock")

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await recorder.started == 2, "cadência normal retomada após o refresh")
    }

    @Test func providersAreIndependent() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let codexFires = FireRecorder()
        let zaiFires = FireRecorder()
        await scheduler.register(provider: .codex) {
            await codexFires.start()
            await codexFires.finish()
        }
        await scheduler.register(provider: .zai) {
            await zaiFires.start()
            await zaiFires.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await codexFires.started == 1)
        #expect(await zaiFires.started == 1)

        // Backoff só no codex
        await scheduler.noteResult(provider: .codex, ok: false, pressure: nil)
        try await settle()
        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await codexFires.started == 1, "codex em backoff de 600 s")
        #expect(await zaiFires.started == 2, "zai segue em 300 s")

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await codexFires.started == 2, "codex dispara aos 900 s")
        #expect(await zaiFires.started == 3)
    }

    @Test func reregisterReplacesHandlerWithoutDoubleFiring() async throws {
        let clock = VirtualClock()
        let scheduler = AdaptiveScheduler(clock: clock, random: { 0 })
        let oldFires = FireRecorder()
        let newFires = FireRecorder()
        await scheduler.register(provider: .codex) {
            await oldFires.start()
            await oldFires.finish()
        }
        await scheduler.register(provider: .codex) {
            await newFires.start()
            await newFires.finish()
        }
        try await settle()

        clock.advance(by: .seconds(300))
        try await settle()
        #expect(await oldFires.started == 0, "handler antigo não dispara após re-register")
        #expect(await newFires.started == 1, "um único loop por provider")
    }

    @Test func noteResultForUnknownProviderDoesNotCrash() async throws {
        let scheduler = AdaptiveScheduler(clock: VirtualClock(), random: { 0 })
        await scheduler.noteResult(provider: .gemini, ok: false, pressure: nil)
        await scheduler.noteResult(provider: .gemini, ok: true, pressure: 0.9)
        await scheduler.noteMenuOpened()
        await scheduler.pauseForSleep()
        await scheduler.resumeFromSleep()
    }
}
