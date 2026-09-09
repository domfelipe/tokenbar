import AppKit
import SwiftUI
import TokenBarCore

/// Logos por provider (ruling F4-LOGOS): SVGs AUTORAIS simplificados —
/// interpretações vetoriais originais deste projeto, minimalistas (estilo
/// CodexBar), usados apenas para IDENTIFICAÇÃO visual no painel; sem vínculo
/// com as marcas (disclaimer no README). Vivem em `Resources/` do módulo,
/// copiados intactos (`.copy` no Package.swift — CLT-safe) e carregados via
/// `NSImage(contentsOf:)`, que lê SVG no macOS 14.
///
/// Contrato: `image(for:)` devolve `nil` quando o provider não tem SVG no
/// bundle (ex.: cursor/openrouter/copilot, que ainda não ganharam marca) —
/// o painel então cai no FALLBACK: chip com a sigla D5 sobre a cor de marca
/// (`brandColor`). Nunca inventa imagem.
@MainActor
public enum ProviderLogo {
    /// Cache de sessão (a view re-renderiza a cada ciclo; decode de SVG por
    /// render seria desperdício). Isolado na MainActor — só a UI (e testes
    /// @MainActor) tocam aqui.
    private static var cache: [ProviderID: NSImage] = [:]

    /// NSImage do SVG autoral; `nil` = sem logo → fallback da sigla D5.
    /// Template image: acompanha light/dark e aceita tint do SwiftUI.
    public static func image(for id: ProviderID) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard
            let url = Bundle.module.url(
                forResource: "logo-\(id.rawValue)",
                withExtension: "svg",
                subdirectory: "Resources"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[id] = image
        return image
    }

    /// Cor de marca (escolha própria deste projeto, aproximação do tom
    /// associado a cada provider) — alimenta o chip de fallback da sigla e
    /// pode accentar o provider no painel. Providers sem marca → accent do
    /// sistema.
    public static func brandColor(for id: ProviderID) -> Color {
        switch id {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)  // terracota
        case .codex: Color(red: 0.12, green: 0.13, blue: 0.15)   // quase-preto
        case .gemini: Color(red: 0.29, green: 0.56, blue: 0.96)  // azul
        case .zai: Color(red: 0.49, green: 0.35, blue: 0.93)     // violeta
        default: Color.accentColor
        }
    }
}
