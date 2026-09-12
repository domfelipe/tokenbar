import AppKit
import SwiftUI
import TokenBarCore

/// Label do item da menu bar com LOGOS dos providers (pedido do usuário:
/// "na barra ao lado do relógio quero que fiquem os logos também, não as
/// letras").
///
/// Um par (logo + valor) por provider visível com dado — ex.: [codex]45%
/// [zai]50% [cursor]19%. Provider sem SVG porta o fallback da sigla D5
/// (mesma fonte de verdade do texto). O valor continua o fragmento canônico
/// (`menuBarFragment`: % quando há janela, tokens abreviados quando local).
///
/// Render gate: a view observa `menuBarItems` (deriva de `content`, publicado
/// por ciclo quando há mudança) — o item da menu bar não é re-criado, só
/// re-avaliado; `menuBarText` (string derivada) continua o gate do heartbeat.
/// O label de acessibilidade é a string canônica — leitores de tela e o
/// ui-smoke (AX name "C:…") continuam funcionando.
public struct ProviderMenuBarLabel: View {
    private let store: SnapshotStore

    public init(store: SnapshotStore) {
        self.store = store
    }

    /// SVG do logo escalado p/ 15pt (fora do ViewBuilder — o resize do
    /// SwiftUI nem sempre comprime SVG no menu bar; escalar o NSImage é o
    /// caminho confiável).
    private func scaledLogo(for id: ProviderID) -> NSImage? {
        guard let image = ProviderLogo.image(for: id) else { return nil }
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 15, height: 15)
        return copy
    }

    public var body: some View {
        // UM Text único com logos INLINE (Text + Text(Image) concatenados).
        // O HStack de Image(nsImage:)/Text antigo era medido errado no
        // contexto do MenuBarExtra: os Image(nsImage:) reportavam tamanho
        // ~zero na fase de measurement (repro: panelrender --menulabel), o
        // item recebia largura de ~1 par (49pt) e os providers após o
        // primeiro sumiam do render ("sumiu as infos"). Text concatenado é
        // o mesmo mecanismo do label original `Text(menuBarText)` — cuja
        // medição sempre foi exata — e o logo NSImage de 15pt entra inline
        // no fluxo do texto. (O ScrollView do painel não sofre disso; o
        // bug era específico do sizing do item da status bar.)
        let items = store.menuBarItems
        var label = mergedLabel(for: items)
        if items.isEmpty {
            label = Text("TB")
        }
        return label
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.menuBarText)
    }

    /// Constrói o Text concatenado: [logo]valor [logo]valor … — logo via
    /// `Text(Image)` (inline no fluxo do texto); sem SVG, sigla D5 no lugar
    /// (mesma fonte de verdade do fragmento textual).
    private func mergedLabel(
        for items: [(id: ProviderID, value: String)]
    ) -> Text {
        var parts: [Text] = []
        for (index, item) in items.enumerated() {
            if index > 0 { parts.append(Text(" ")) }
            if let logo = scaledLogo(for: item.id) {
                parts.append(Text(Image(nsImage: logo)))
            } else {
                parts.append(Text(MenuBarContent.sigla(for: item.id)))
            }
            parts.append(Text(item.value))
        }
        return parts.reduce(Text(""), +)
    }
}

// MARK: - Dados derivados (mesma ordenação/visibilidade da string canônica)

extension MenuBarContent {
    /// Pares (provider, valor) exibidos como LOGO+valor na menu bar — mesma
    /// seleção/ordem de `displayString()` (visíveis com dado), valor =
    /// `menuBarFragment` (sem sigla: o logo substitui a letra).
    public var providersWithLogos: [(id: ProviderID, value: String)] {
        orderedProviders().compactMap { id, display in
            guard let value = display.menuBarFragment else { return nil }
            return (id: id, value: value)
        }
    }
}
