import Testing
import Foundation
import TokenBarCore
@testable import TokenBarUI

/// View-model da label com LOGOS da menu bar (`ProviderMenuBarLabel`):
/// seleção/ordem/idempotência dos pares (provider, valor) — o visual é
/// SwiftUI puro e o contrato é o MESMO de `displayString()`.
@Suite
struct ProviderMenuBarLabelTests {

    private func display(percent: Int? = nil, tokens: Int64 = 0) -> ProviderDisplay {
        ProviderDisplay(
            percent: percent.map(Double.init),
            todayTokens: tokens,
            authState: .ok,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windows: [])
    }

    @Test
    func logosMatchCanonicalStringSelection() {
        // Mesma entrada da displayString → mesmos providers, valores = fragmento
        // sem sigla (o logo substitui a letra).
        let content = MenuBarContent(
            providers: [
                .claude: display(tokens: 12_400),
                .codex: display(percent: 62),
                .gemini: display(tokens: 0),          // sem dado: fora
                .zai: display(percent: 81),
            ])
        let items = content.providersWithLogos
        #expect(items.map(\.id) == [.claude, .codex, .zai])
        #expect(items.map(\.value) == ["12.4k", "62%", "81%"])
        // A string canônica continua casando com os mesmos dados.
        #expect(content.displayString() == "C:12.4k X:62% Z:81%")
    }

    @Test
    func emptyYieldsNoItems() {
        #expect(MenuBarContent.empty.providersWithLogos.isEmpty)
    }

    @Test
    func visibilityFiltersLogosToo() {
        let content = MenuBarContent(
            providers: [.claude: display(tokens: 5), .codex: display(percent: 10)],
            visibleProviders: [.codex])   // claude escondido nas settings
        #expect(content.providersWithLogos.map(\.id) == [.codex])
    }

    @Test
    @MainActor
    func storeExposesItemsForLabel() {
        let store = SnapshotStore()
        store.apply(MenuBarContent(providers: [.codex: display(percent: 42)]))
        #expect(store.menuBarItems.map(\.value) == ["42%"])
        // Gate intacto: mesma string não re-publica menuBarText.
        #expect(store.menuBarText == "X:42%")
    }
}
