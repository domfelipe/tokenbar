import Testing
import Observation
import TokenBarCore
@testable import TokenBarUI

// Swift 6: onChange é @Sendable, então var local não pode ser capturado/mutado.
// Box mínimo equivalente ao `var changes = 0` do brief (mesma semântica).
private final class ChangeCounter: @unchecked Sendable {
    var count = 0
}

// Tradução mecânica (RULING SDD-1) do brief XCTest → Swift Testing:
// `import Testing`, @Test, #expect; render gate com @MainActor na função.
struct MenuBarContentTests {
    @Test
    func testAbbrevTokens() {
        #expect(abbrevTokens(0) == "0")
        #expect(abbrevTokens(999) == "999")
        #expect(abbrevTokens(1_000) == "1.0k")
        #expect(abbrevTokens(1_234) == "1.2k")
        #expect(abbrevTokens(12_345) == "12.3k")
        #expect(abbrevTokens(2_300_000) == "2.3M")
        #expect(abbrevTokens(1_200_000_000) == "1.2G")
    }

    @Test
    func testEmptyContentShowsPlaceholder() {
        #expect(MenuBarContent.empty.displayString() == "TB")
    }

    @Test
    func testSingleProviderFormat() {
        #expect(MenuBarContent(todayTokens: [.claude: 12_400]).displayString() == "C:12.4k")
    }

    @Test
    func testMultipleProvidersFormat() {
        // Brief original usava .codex, mas codex → "C" pela interface acordada
        // (rawValue.prefix(1).uppercased()) — colidiria com claude. .openrouter
        // preserva a string esperada do brief ("C:12.4k O:999").
        let content = MenuBarContent(todayTokens: [.claude: 12_400, .openrouter: 999])
        #expect(content.displayString() == "C:12.4k O:999")
    }

    @Test
    @MainActor
    func testRenderGateSkipsEqualContent() {
        let store = SnapshotStore()
        let content = MenuBarContent(todayTokens: [.claude: 12_400])
        store.apply(content)

        let counter = ChangeCounter()
        withObservationTracking {
            _ = store.menuBarText
        } onChange: { counter.count += 1 }

        store.apply(content)                                         // igual → NÃO marca
        #expect(counter.count == 0)
        #expect(store.menuBarText == "C:12.4k")

        // Conteúdo diferente mas mesma string renderizada (12_401 → "C:12.4k"):
        // o runtime de Observation (darwin 25) suprime escrita de mesmo valor.
        store.apply(MenuBarContent(todayTokens: [.claude: 12_401]))
        #expect(counter.count == 0)
        #expect(store.menuBarText == "C:12.4k")

        // String exibida diferente → marca exatamente 1×.
        store.apply(MenuBarContent(todayTokens: [.claude: 12_500]))
        #expect(counter.count == 1)
        #expect(store.menuBarText == "C:12.5k")
    }
}
