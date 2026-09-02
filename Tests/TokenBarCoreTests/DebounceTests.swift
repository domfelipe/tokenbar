import Foundation
import Testing
@testable import TokenBarCore

/// Clock virtual: sleep registra waiter; advance(by:) desperta os vencidos.
final class VirtualClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    private let lock = NSLock()
    private var nowValue: Instant
    private var waiters: [(deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Instant = .now) {
        nowValue = start
    }

    var now: Instant {
        lock.lock(); defer { lock.unlock() }
        return nowValue
    }

    var minimumResolution: Instant.Duration { .zero }

    /// Protocolo Clock (toolchain atual) exige sleep(until:tolerance:); o sleep(for:)
    /// da extensão padrão usa este método + o `now` virtual.
    func sleep(until deadline: Instant, tolerance: Instant.Duration? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            waiters.append((deadline, continuation))
            lock.unlock()
        }
    }

    /// Avança o relógio virtual e desperta waiters cujo deadline passou.
    func advance(by duration: Instant.Duration) {
        lock.lock()
        nowValue = nowValue.advanced(by: duration)
        let due = waiters.filter { $0.deadline <= nowValue }
        waiters.removeAll { $0.deadline <= nowValue }
        lock.unlock()
        for waiter in due { waiter.continuation.resume(returning: ()) }
    }
}

/// Sonda de conclusão: substitui `task.isFinished` (inexistente em Task neste toolchain).
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

@Suite
struct DebounceTests {
    @Test
    func testWaitReturnsOnlyAfterQuiesceWindow() async throws {
        let clock = VirtualClock()
        let debouncer = Debouncer(quiesce: .seconds(3), clock: clock)
        let finished = CompletionFlag()

        let task = Task {
            await debouncer.wait()
            finished.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished.isSet, "janela intacta: wait bloqueia")

        await debouncer.touch()
        clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished.isSet, "passou 2 s de 3 s: ainda bloqueia")

        clock.advance(by: .seconds(1))
        _ = await task.value  // chegou aqui = retornou após quiescência
    }

    @Test
    func testTouchResetsWindow() async throws {
        let clock = VirtualClock()
        let debouncer = Debouncer(quiesce: .seconds(3), clock: clock)
        let finished = CompletionFlag()

        let task = Task {
            await debouncer.wait()
            finished.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        await debouncer.touch()
        clock.advance(by: .seconds(2))
        await debouncer.touch()                    // reinicia: deadline vai a +3 s deste ponto
        clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished.isSet, "touch reiniciou a janela: 4 s totais < 3 s do último touch")

        clock.advance(by: .seconds(1))
        _ = await task.value
    }
}
