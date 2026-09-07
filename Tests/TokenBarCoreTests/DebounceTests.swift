import Foundation
import Testing
@testable import TokenBarCore

// VirtualClock e CompletionFlag vivem em TestSupport.swift (compartilhados
// com SchedulerTests na F2; o clock ganhou sleep cancelável).

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
