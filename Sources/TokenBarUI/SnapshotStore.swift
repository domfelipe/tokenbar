import Observation
import TokenBarCore

/// Fonte única de verdade da UI. Render gate: `menuBarText` só publica
/// (e re-renderiza o item de menu) quando a string exibida de fato muda.
@MainActor
@Observable
public final class SnapshotStore {
    private var content: MenuBarContent = .empty

    public private(set) var menuBarText: String = "TB"

    public init() {}

    public func apply(_ newContent: MenuBarContent) {
        guard newContent != content else { return }
        content = newContent
        menuBarText = newContent.displayString()
    }
}
