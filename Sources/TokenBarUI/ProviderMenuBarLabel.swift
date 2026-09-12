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
        let items = store.menuBarItems
        HStack(spacing: 5) {
            ForEach(items, id: \.id) { item in
                HStack(spacing: 2) {
                    if let nsImage = ProviderLogo.image(for: item.id) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 15, height: 15)
                    } else {
                        Text(MenuBarContent.sigla(for: item.id))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                    Text(item.value)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
            }
            if items.isEmpty {
                Text("TB")
                    .font(.system(size: 11, weight: .medium))
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
