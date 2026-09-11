import AppKit
import SwiftUI
import TokenBarCore
// O harness usa subviews internas do módulo de UI (@testable — só existe em
// build DEBUG; `swift build -c release` (make-app.sh) NÃO pode quebrar por
// causa dele).
#if DEBUG
@testable import TokenBarUI
#endif

/// Harness de render do QA (F5 Task 1): compõe as views REAIS do painel com
/// dados de LAB (lab codex ≈ o screenshot de referência: 74% semanal, déficit
/// 69%, custos hoje/30d, série com pico $282) e renderiza via `ImageRenderer`
/// → PNG no caminho dado. O ScrollView não compõe no ImageRenderer (limitação
/// conhecida desde o QA F4), então o harness monta o MESMO VStack do corpo do
/// `ProviderPanelView` com as subviews reais (chip-bar, conteúdo, rodapé) —
/// inspeção visual do código de view em produção.
///
/// Uso:
///   panelrender <saida.png>                      → render do painel
///   panelrender <ours.png> <ref.png> <out.png>   → evidência lado a lado
///     (renderiza <ours.png> e compõe NOSSO render | referência na mesma
///      altura, com separador — artefato de `docs/qa/evidence/`)
/// Dados de lab apenas (fake-*): nada de rede, nada de credencial.
/// Build release: no-op com aviso (ferramenta de QA é debug-only).
@main
struct PanelRenderMain {
    static func main() {
        let arguments = CommandLine.arguments
        #if !DEBUG
        FileHandle.standardError.write(
            "panelrender é ferramenta de QA debug-only: rode `swift build` (debug).\n"
                .data(using: .utf8)!)
        exit(2)
        #else
        switch arguments.count {
        case 2:
            let image = MainActor.assumeIsolated { render() }
            guard let image else { fail("render falhou") }
            writePNG(image, to: arguments[1])
        case 4:
            MainActor.assumeIsolated {
                composeSideBySide(
                    oursPath: arguments[1], referencePath: arguments[2],
                    outputPath: arguments[3])
            }
        default:
            FileHandle.standardError.write(
                "uso: panelrender <saida.png> | panelrender <ours.png> <ref.png> <out.png>\n"
                    .data(using: .utf8)!)
            exit(2)
        }
        #endif
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    #if DEBUG
    /// "Agora" congelado do lab — determinístico (countdowns estáveis).
    static let labNow = Date(timeIntervalSince1970: 1_789_152_000)

    @MainActor
    static func labDisplay() -> ProviderDisplay {
        var display = ProviderDisplay(
            percent: 74,
            todayTokens: 216_000_000,
            todayCostUsd: 0.0,
            weekTokens: 3_100_000_000,
            weekCostUsd: 585.43,
            weekHistoryAvailable: true,
            authState: .ok,
            source: .api,
            resetsAt: labNow.addingTimeInterval(6 * 86_400 + 16 * 3_600),
            fetchedAt: labNow,
            // Pin EXPLÍCITO do topModel7d no gate (carry-forward review T1):
            // a linha "Top model" entra no render de evidência pelo init, não
            // por mutação pós-init (o estado do lab é todo declarado aqui).
            topModel7d: "gpt-5.6-sonnet")
        display.windows = [
            UsageWindow(
                kind: .weekly, usedFraction: 0.74,
                resetsAt: labNow.addingTimeInterval(6 * 86_400 + 16 * 3_600),
                label: "Semanal"),
        ]
        display.monthTokens = 8_900_000_000
        display.monthCostUsd = 1_116.52
        display.monthHistoryAvailable = true
        display.pacing = PacingForecast(
            exhaustedIn: 2 * 3_600 + 44 * 60, projectedFraction: 1.69, deficitPct: 69)
        // Série 30d de lab: 22 dias com custo, pico $282 no último dia
        // (mesma forma do screenshot de referência).
        var series: [PanelDayPoint] = []
        for offset in stride(from: 21, through: 0, by: -1) {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: labNow)!
            let key = day.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let dayIndex = 21 - offset
            let cost: Double?
            let tokens: Int64
            if dayIndex == 21 {
                cost = 282.0
                tokens = 1_240_000_000
            } else if dayIndex % 3 == 0 {
                cost = nil  // dia sem custo computável (NULL ≠ 0)
                tokens = 40_000_000
            } else {
                cost = 18.0 + Double((dayIndex * 37) % 90)
                tokens = 120_000_000 + Int64((dayIndex * 53) % 400) * 1_000_000
            }
            series.append(PanelDayPoint(day: key, tokens: tokens, costUSD: cost))
        }
        display.monthSeries = series
        // F5 T6: linha "Credits" do painel no lab (dado sintético — o
        // veredito de credits está em docs/specs/f5-providers.md).
        display.credits = CreditsInfo(remaining: 4.20, unlimited: false)
        return display
    }

    @MainActor
    static func render() -> NSImage? {
        let display = labDisplay()
        let providers: [ProviderID: ProviderDisplay] = [
            .claude: ProviderDisplay(
                percent: 18, todayTokens: 45_600, authState: .ok, source: .localOnly),
            .codex: display,
            .gemini: ProviderDisplay(percent: 3, todayTokens: 193),
            .zai: ProviderDisplay(percent: 81),
        ]
        let content = MenuBarContent(providers: providers)
        let tabs = ProviderPanelModel.tabOrder(providers: content.providers)
        let selected = ProviderPanelModel.effectiveSelection(
            selected: .codex, providers: content.providers)

        // MESMA composição do corpo de `ProviderPanelView` (ScrollView →
        // VStack direto; altura livre para o render inspecionar tudo).
        let panel = VStack(alignment: .leading, spacing: 0) {
            ProviderChipBar(
                tabs: tabs, selected: selected, select: { _ in },
                providers: content.providers)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            Divider()
            ProviderDetailContent(
                provider: .codex, display: display, now: labNow,
                accounts: nil, addAccountAction: { _ in },
                analyticsAction: {}, exportAction: {})
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 6)
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                MenuRowView(icon: "arrow.clockwise", title: "Refresh", shortcut: "⌘R", action: {})
                MenuRowView(icon: "gearshape", title: "Settings…", shortcut: "⌘,", isEnabled: false, action: {})
                MenuRowView(icon: "info.circle", title: "About TokenBar", action: {})
                MenuRowView(icon: "power", title: "Quit TokenBar", shortcut: "⌘Q", action: {})
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
        }
        .frame(width: 310, alignment: .leading)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        return renderer.nsImage
    }

    // MARK: Evidência lado a lado

    @MainActor
    static func composeSideBySide(oursPath: String, referencePath: String, outputPath: String) {
        guard let rendered = render() else { fail("render falhou") }
        writePNG(rendered, to: oursPath)
        guard let ref = NSImage(contentsOfFile: referencePath) else { fail("referência não carregou") }
        guard let oursRep = rendered.representations.first else { fail("render sem representação") }

        // Pixels reais do nosso render (ImageRenderer em escala 2).
        let oursW = CGFloat(oursRep.pixelsWide)
        let oursH = CGFloat(oursRep.pixelsHigh)
        let refRep = ref.representations.first
        let refPW = CGFloat(refRep?.pixelsWide ?? Int(ref.size.width))
        let refPH = CGFloat(refRep?.pixelsHigh ?? Int(ref.size.height))
        // Referência escala para a ALTURA do nosso render (proporção mantida).
        let targetRefW = refPW * (oursH / refPH)
        let gap: CGFloat = 28
        let outW = Int(oursW + gap + targetRefW)
        let outH = Int(oursH)

        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fail("bitmap da evidência falhou") }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: outRep) else {
            fail("contexto da evidência falhou")
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: outW, height: outH)).fill()

        // Nosso render à esquerda (1:1 em pixels); referência à direita,
        // alinhada pelo topo (mesma altura de desenho).
        rendered.draw(in: NSRect(x: 0, y: 0, width: oursW, height: oursH))
        ref.draw(in: NSRect(x: oursW + gap, y: 0, width: targetRefW, height: oursH))

        guard let png = outRep.representation(using: .png, properties: [:]) else {
            fail("encode PNG da evidência falhou")
        }
        try? png.write(to: URL(fileURLWithPath: outputPath))
        FileHandle.standardOutput.write("side-by-side: \(outputPath)\n".data(using: .utf8)!)
    }

    static func writePNG(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { fail("encode PNG falhou") }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write("render: \(path)\n".data(using: .utf8)!)
    }
    #endif  // DEBUG
}
