import Observation
import TokenBarCore

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

    public init() {}

    /// Estado de exibição por provider (inclui os sem dados — heartbeat v2).
    public var providers: [ProviderID: ProviderDisplay] { content.providers }

    /// Linhas do painel (uma por provider ativo); vazio quando nada a mostrar.
    public var menuLines: [String] { content.menuLines() }

    public func apply(_ newContent: MenuBarContent) {
        guard newContent != content else { return }
        let newString = newContent.displayString()
        content = newContent
        // Gate: mesma string exibida → NÃO toca no label observado.
        guard newString != menuBarText else { return }
        menuBarText = newString
    }
}
