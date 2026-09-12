import AppKit
import Testing
import TokenBarCore
@testable import TokenBarUI

/// Label pré-renderizado da menu bar: medida honesta (largura = conteúdo) e
/// pixels visíveis — Regra 9 em pixels, não em AX.
@Suite
struct MenuBarLabelImageTests {
    @Test
    @MainActor
    func rendersLogosAndValuesWithHonestWidth() {
        let pairs = [
            MenuBarLabelImage.Item(
                logo: ProviderLogo.bitmap(for: .codex, points: 15),
                fallback: "X", text: "62%"),
            MenuBarLabelImage.Item(
                logo: ProviderLogo.bitmap(for: .zai, points: 15),
                fallback: "Z", text: "17%"),
        ]
        let image = MenuBarLabelImage.image(for: pairs, key: "X:62% Z:17%")
        #expect(image.size.height == MenuBarLabelImage.canvasHeight)
        // Largura honesta: passa de texto puro (2 logos de 15pt cabem dentro).
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: MenuBarLabelImage.fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textOnly = ("62%" as NSString).size(withAttributes: attrs).width
            + ("17%" as NSString).size(withAttributes: attrs).width
        #expect(image.size.width > textOnly + 2 * MenuBarLabelImage.logoPoints - 1)
        // Pixels visíveis (nada em branco).
        var visible = 0
        for rep in image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                    if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                        visible += 1
                    }
                }
            }
        }
        #expect(visible > 10)
    }

    @Test
    @MainActor
    func fallbackSiglaPaintsWithoutLogo() {
        let pairs = [
            MenuBarLabelImage.Item(logo: nil, fallback: "K", text: "11%"),
        ]
        let image = MenuBarLabelImage.image(for: pairs, key: "K:11%-fallback")
        #expect(image.size.width > 10)
    }

    @Test
    @MainActor
    func cacheReusesSameContent() {
        let pairs = [
            MenuBarLabelImage.Item(
                logo: ProviderLogo.bitmap(for: .codex, points: 15),
                fallback: "X", text: "7%"),
        ]
        let first = MenuBarLabelImage.image(for: pairs, key: "cache-probe-X:7%")
        let second = MenuBarLabelImage.image(for: pairs, key: "cache-probe-X:7%")
        #expect(first === second)
    }
}
