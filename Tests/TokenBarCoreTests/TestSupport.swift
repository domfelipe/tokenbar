import Foundation

/// Clock virtual: sleep registra waiter; advance(by:) desperta os vencidos.
/// Cancellation-aware: cancelar a task tira o waiter da fila e resume com
/// CancellationError — mesma semântica do `ContinuousClock.sleep`. O
/// AdaptiveScheduler (F2) reinicia tasks nos eventos de menu/sleep, então o
/// sleep pendente precisa acordar no cancelamento.
///
/// Extraído de DebounceTests (F1) para support compartilhado entre suítes.
final class VirtualClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    /// Estado de um sleep em curso. Todo acesso acontece sob o lock do
    /// VirtualClock; a classe é `@unchecked Sendable` só por esse invariant.
    private final class Waiter: @unchecked Sendable {
        let deadline: Instant
        var continuation: CheckedContinuation<Void, Error>?

        init(deadline: Instant) {
            self.deadline = deadline
        }
    }

    private let lock = NSLock()
    private var nowValue: Instant
    private var waiters: [Waiter] = []

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
        let waiter = Waiter(deadline: deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                // Deadline já vencido (o now virtual passou dele): retorna na hora,
                // mesma semântica do ContinuousClock p/ sleep no passado.
                if deadline <= nowValue {
                    lock.unlock()
                    continuation.resume(returning: ())
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter.continuation = continuation
                waiters.append(waiter)
                lock.unlock()
            }
        } onCancel: {
            lock.lock(); defer { lock.unlock() }
            guard let continuation = waiter.continuation else { return }
            waiter.continuation = nil
            waiters.removeAll { $0 === waiter }
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Avança o relógio virtual e desperta waiters cujo deadline passou.
    func advance(by duration: Instant.Duration) {
        lock.lock()
        nowValue = nowValue.advanced(by: duration)
        var due: [CheckedContinuation<Void, Error>] = []
        waiters.removeAll { waiter in
            guard waiter.deadline <= nowValue else { return false }
            if let continuation = waiter.continuation {
                waiter.continuation = nil
                due.append(continuation)
            }
            return true
        }
        lock.unlock()
        for continuation in due { continuation.resume(returning: ()) }
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
