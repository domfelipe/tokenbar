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
/// Extras de pace/reset vivem SÓ no painel ("Renews in…", meta de pacing) —
/// decisão do dono: na barra, apenas logo + % (largura mínima, sem ruído).
/// A string canônica (`menuBarText`, AX, heartbeat, render gate) é a mesma
/// do que pinta.
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
        // Imagem única pré-renderizada (`MenuBarLabelImage`, AppKit): o único
        // formato com medida honesta no host do MenuBarExtra — Text inline
        // com imagem mede ~zero/pinta em branco e HStack clipa após o 1º par
        // (verificados por pixels; o AX mede normal e mente). Reconstruída a
        // cada ciclo com dado novo (cache por string canônica, teto 8).
        let items = store.menuBarItems
        return Group {
            if items.isEmpty {
                Text("TB")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            } else {
                let pairs = items.map { item in
                    MenuBarLabelImage.Item(
                        logo: ProviderLogo.bitmap(for: item.id, points: 15),
                        fallback: MenuBarContent.sigla(for: item.id),
                        text: item.value)
                }
                Image(nsImage: MenuBarLabelImage.image(for: pairs, key: store.menuBarText))
            }
        }
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
