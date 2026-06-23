import SwiftUI

/// Lets menu commands reach the focused window's tabs (e.g. split toggle).
struct TabsModelKey: FocusedValueKey { typealias Value = TabsModel }
extension FocusedValues {
    var tabsModel: TabsModel? {
        get { self[TabsModelKey.self] }
        set { self[TabsModelKey.self] = newValue }
    }
}

/// Per-window collection of editor tabs. Each tab is its own `EditorModel`
/// (and its own WebView), so switching tabs preserves content/cursor/undo.
final class TabsModel: ObservableObject {
    @Published var tabs: [EditorModel]
    @Published var activeID: EditorModel.ID

    /// Split view: a companion editor shown to the right when `splitOn`.
    @Published var splitOn = false
    let secondary = EditorModel()

    init() {
        let first = EditorModel()
        tabs = [first]
        activeID = first.id
    }

    var active: EditorModel {
        tabs.first { $0.id == activeID } ?? tabs[0]
    }

    func activate(_ id: EditorModel.ID) { activeID = id }

    @discardableResult
    func newTab() -> EditorModel {
        let e = EditorModel()
        tabs.append(e)
        activeID = e.id
        return e
    }

    /// Open a URL — in a new tab, or replacing the active tab's content.
    func open(_ url: URL, inNewTab: Bool = false) {
        // If a tab already shows this file, just focus it.
        if let existing = tabs.first(where: { $0.currentURL == url }) {
            activeID = existing.id
            return
        }
        let target = inNewTab ? newTab() : active
        target.open(url)
    }

    func close(_ id: EditorModel.ID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if activeID == id {
            activeID = tabs[min(i, tabs.count - 1)].id
        }
    }

    func closeActive() { close(activeID) }
}
