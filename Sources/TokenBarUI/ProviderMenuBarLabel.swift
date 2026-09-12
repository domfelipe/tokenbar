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

    public var body: some View {
        // UM Text único com logos INLINE (Text + Text(Image) concatenados) —
        // medição exata (mesmo mecanismo do label original Text(menuBarText),
        // verificado pintando por diff de pixels). Os logos são BITMAPS 3x
        // (`ProviderLogo.bitmap`): o SVG original quebrava o render do status
        // item (label media ~zero → item colapsava p/ ~1 par). Sem SVG, sigla
        // D5 no lugar (mesma fonte de verdade do fragmento textual).
        let items = store.menuBarItems
        let label: Text = {
            guard !items.isEmpty else { return Text("TB") }
            var parts: [Text] = []
            for (index, item) in items.enumerated() {
                if index > 0 { parts.append(Text(" ")) }
                if let logo = ProviderLogo.bitmap(for: item.id, points: 15) {
                    parts.append(Text(Image(nsImage: logo)))
                } else {
                    parts.append(Text(MenuBarContent.sigla(for: item.id)))
                }
                parts.append(Text(item.value))
            }
            return parts.reduce(Text(""), +)
        }()
        return label
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.menuBarText)
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
