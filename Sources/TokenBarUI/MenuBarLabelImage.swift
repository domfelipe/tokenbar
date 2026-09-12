import AppKit
import TokenBarCore

/// Label INTEIRO da menu bar pré-renderizado numa imagem AppKit só.
///
/// Por que não SwiftUI: no host do `MenuBarExtra` (macOS 26) imagens inline
/// em `Text` medem ~zero e pintam em branco, e `HStack` é enquadrado na
/// largura do 1º par (resto clipa) — ambos verificados por pixels (o AX mede
/// normal e mente). Uma imagem única tem tamanho honesto (pixels reais) e o
/// item enquadra certo. O painel segue com os SVGs vetoriais (nítidos).
///
/// Look = silhueta branca + texto branco (equivalente ao template, que o
/// host não pinta): fills dos SVGs são mistos (alibaba #111/deepseek
/// currentColor sumiriam na barra escura). Limite: barra CLARA precisaria de
/// tinta escura ou NSStatusItem AppKit (follow-up).
@MainActor
public enum MenuBarLabelImage {
    /// Métricas do layout (pt): logo 15 (igual ao bitmap), texto 11 medium.
    static let logoPoints: CGFloat = 15
    static let fontSize: CGFloat = 11
    static let logoTextGap: CGFloat = 3
    static let itemGap: CGFloat = 8
    static let canvasHeight: CGFloat = 18

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8  // 1 entrada por string exibida; ciclo reescreve
        return cache
    }()

    /// Um item = logo (já branco) + valor. Sem logo (ex.: copilot, sem SVG na
    /// referência) a `fallback` (sigla D5) é desenhada como texto — pintura e
    /// AX nunca divergem.
    public struct Item: Sendable {
        public let logo: NSImage?
        public let fallback: String
        public let text: String
        public init(logo: NSImage?, fallback: String, text: String) {
            self.logo = logo
            self.fallback = fallback
            self.text = text
        }
    }

    public static func image(for items: [Item], key: String) -> NSImage {
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) { return cached }
        let rendered = render(items: items)
        cache.setObject(rendered, forKey: nsKey)
        return rendered
    }

    static func render(items: [Item]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let widths = items.map { item -> CGFloat in
            let lead = item.logo != nil
                ? logoPoints
                : (item.fallback as NSString).size(withAttributes: attrs).width
            let textSize = (item.text as NSString).size(withAttributes: attrs)
            return lead + logoTextGap + textSize.width
        }
        let totalWidth = max(1, widths.reduce(0, +) + itemGap * CGFloat(max(0, items.count - 1)))
        let scale: CGFloat = 2
        let image = NSImage(size: NSSize(width: totalWidth, height: canvasHeight))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(totalWidth * scale), pixelsHigh: Int(canvasHeight * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        var x: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { x += itemGap }
            // Logo 15pt (ou sigla de fallback) + valor, centralizados.
            let textWidth = (item.text as NSString).size(withAttributes: attrs).width
            let leadWidth = widths[index] - logoTextGap - textWidth
            if let logo = item.logo {
                logo.draw(
                    in: NSRect(
                        x: x, y: (canvasHeight - logoPoints) / 2,
                        width: logoPoints, height: logoPoints))
            } else {
                let lead = item.fallback as NSString
                let leadSize = lead.size(withAttributes: attrs)
                lead.draw(
                    at: NSPoint(x: x, y: (canvasHeight - leadSize.height) / 2),
                    withAttributes: attrs)
            }
            let textSize = (item.text as NSString).size(withAttributes: attrs)
            (item.text as NSString).draw(
                at: NSPoint(x: x + leadWidth + logoTextGap, y: (canvasHeight - textSize.height) / 2),
                withAttributes: attrs)
            x += widths[index]
        }
        context.flushGraphics()
        NSGraphicsContext.current = nil
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        out.isTemplate = false
        return out
    }
}
