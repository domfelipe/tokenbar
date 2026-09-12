import Observation
import TokenBarCore

/// Estado de alertas EXIBIDO no painel (F5 T2) — honesto: o que a UI diz
/// tem que ser verdade sobre permissão/config, não otimismo. Fora do render
/// gate (não toca no label do menu bar nem no heartbeat).
public enum AlertsPanelStatus: Sendable, Equatable {
    /// Alerts ligados e notificação autorizada — painel não precisa dizer nada.
    case enabled
    /// Alerts desligados nas settings (default — ruling F5-NOTIF).
    case disabled
    /// Alerts ligados, permissão de notificação ainda não pedida/decidida.
    case notConfigured
    /// Alerts ligados, permissão NEGADA pelo sistema.
    case blocked
}

/// Fonte única de verdade da UI (F2): estado POR provider (`providers`) mais a
/// string derivada. Render gate: `menuBarText` só publica (e re-renderiza o
/// item de menu) quando a string exibida de fato muda — ciclos que só mexem em
/// `fetchedAt`/totais sem mudar o texto não tocam no label. `providers` e
/// `menuLines` são derivados do conteúdo e re-renderizam o painel aberto.
@MainActor
@Observable
public final class SnapshotStore {
    private var content: MenuBarContent = .empty

    public private(set) var menuBarText: String = "TB"

    /// Aba selecionada no painel rico (F4): `nil` = automática (primeira com
    /// dado, ordem D5 — o painel resolve via `effectiveSelection`). Estado de
    /// UI do painel: nunca entra na string do menu bar nem no render gate.
    public private(set) var selectedProvider: ProviderID?

    /// Estado de alertas para a linha honesta do rodapé (F5 T2). Escrito pelo
    /// coordinator a cada ciclo (degradado sem DB/gateway → `.disabled`).
    public private(set) var alertsStatus: AlertsPanelStatus = .disabled

    /// Escrita separada da `apply` — estado de UI, nunca entra no render gate.
    public func setAlertsStatus(_ status: AlertsPanelStatus) {
        alertsStatus = status
    }

    public init() {}

    /// Estado de exibição por provider (inclui os sem dados — heartbeat v2).
    public var providers: [ProviderID: ProviderDisplay] { content.providers }

    /// Pares (provider, valor) para a label com LOGOS da menu bar
    /// (`ProviderMenuBarLabel`): mesma seleção/ordem da string canônica,
    /// valor = `menuBarFragment` (o logo substitui a sigla). Observa
    /// `content` (publicação por ciclo), não só `menuBarText` — o par
    /// logo+valor precisa do conjunto de providers, que a string sozinha
    /// não carrega.
    public var menuBarItems: [(id: ProviderID, value: String)] {
        content.providersWithLogos
    }

    /// Linhas do painel (uma por provider ativo); vazio quando nada a mostrar.
    public var menuLines: [String] { content.menuLines() }

    /// Seleção de aba do painel (F4). `nil` volta ao automático.
    public func select(_ id: ProviderID?) {
        guard selectedProvider != id else { return }
        selectedProvider = id
    }

    public func apply(_ newContent: MenuBarContent) {
        guard newContent != content else { return }
        let newString = newContent.displayString()
        content = newContent
        // Gate: mesma string exibida → NÃO toca no label observado.
        guard newString != menuBarText else { return }
        menuBarText = newString
    }
}
