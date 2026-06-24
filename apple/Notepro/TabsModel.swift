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

    // ── Tab navigation (multi-tab jumping) ──────────────────────────────
    /// Move focus to the next tab (wraps to the first).
    func nextTab() {
        guard let i = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        activeID = tabs[(i + 1) % tabs.count].id
    }
    /// Move focus to the previous tab (wraps to the last).
    func prevTab() {
        guard let i = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        activeID = tabs[(i - 1 + tabs.count) % tabs.count].id
    }
    /// Jump to the 1-indexed N-th tab (no-op if out of range).
    func activate(at index: Int) {
        guard index >= 1, index <= tabs.count else { return }
        activeID = tabs[index - 1].id
    }

    /// Handle a URL dropped onto the tab `targetID`:
    ///  • if an open tab already shows that URL → reorder it to that slot;
    ///  • otherwise → open the file as a new tab inserted at that slot.
    /// Used for drag-to-reorder in the tab bar (and dropping a sidebar file).
    func handleTabDrop(_ url: URL, onto targetID: EditorModel.ID) {
        guard let targetIdx = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        if let srcIdx = tabs.firstIndex(where: { $0.currentURL == url }) {
            if srcIdx == targetIdx { return }
            let moved = tabs.remove(at: srcIdx)
            let insertAt = tabs.firstIndex(where: { $0.id == targetID }) ?? targetIdx
            tabs.insert(moved, at: insertAt)
            activeID = moved.id
        } else {
            let e = EditorModel()
            e.vaultRoot = tabs.first?.vaultRoot
            e.open(url)
            tabs.insert(e, at: targetIdx)
            activeID = e.id
        }
    }
}
