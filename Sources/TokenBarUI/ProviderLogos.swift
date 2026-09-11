import AppKit
import SwiftUI
import TokenBarCore

/// Logos por provider (ruling F5-DESIGN — SUPERSEDE F4-LOGOS-autoral):
/// SVGs `ProviderIcon-*.svg` PORTADOS da referência MIT (CodexBar,
/// `Sources/CodexBar/Resources/` — cópias intactas; ver NOTICE na raiz),
/// usados para IDENTIFICAÇÃO visual no painel. Vivem em `Resources/` do
/// módulo, copiados intactos (`.copy` no Package.swift — CLT-safe) e
/// carregados via `NSImage(contentsOf:)`, que lê SVG no macOS 14.
///
/// Contrato: `image(for:)` devolve `nil` quando o provider não tem SVG no
/// bundle (ex.: cursor/openrouter/copilot, que não foram portados) —
/// o painel então cai no FALLBACK: chip com a sigla D5 sobre a cor de marca
/// (`brandColor`). Nunca inventa imagem.
@MainActor
public enum ProviderLogo {
    /// Cache de sessão (a view re-renderiza a cada ciclo; decode de SVG por
    /// render seria desperdício). Isolado na MainActor — só a UI (e testes
    /// @MainActor) tocam aqui.
    private static var cache: [ProviderID: NSImage] = [:]

    /// NSImage do SVG portado da referência; `nil` = sem logo → fallback da
    /// sigla D5. Template image: acompanha light/dark e aceita tint.
    public static func image(for id: ProviderID) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard
            let url = Bundle.module.url(
                forResource: "ProviderIcon-\(id.rawValue)",
                withExtension: "svg",
                subdirectory: "Resources"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[id] = image
        return image
    }

    /// Cores de marca da referência MIT (`ProviderBranding`, CodexBarCore —
    /// hex exato por provider). Alimentam o chip de fallback da sigla, o
    /// indicador de quota do chip e o fill da barra segmentada. Providers sem
    /// entrada → accent do sistema.
    public static func brandColor(for id: ProviderID) -> Color {
        switch id {
        case .claude: Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)   // #CC7C5E
        case .codex: Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)    // #49A3B0
        case .gemini: Color(red: 171 / 255, green: 135 / 255, blue: 234 / 255)  // #AB87EA
        case .zai: Color(red: 232 / 255, green: 90 / 255, blue: 106 / 255)      // #E85A6A
        default: Color.accentColor
        }
    }
}
