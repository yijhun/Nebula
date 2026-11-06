import SwiftUI
import AppKit
import Combine

/// Lets menu commands reach the focused window's tabs (e.g. split toggle).
struct TabsModelKey: FocusedValueKey { typealias Value = TabsModel }
extension FocusedValues {
    var tabsModel: TabsModel? {
        get { self[TabsModelKey.self] }
        set { self[TabsModelKey.self] = newValue }
    }
}

extension Notification.Name {
    /// An editor's web view took keyboard focus (object: the EditorModel), so
    /// the window knows which pane the user is working in.
    static let noteproEditorFocused = Notification.Name("NoteproEditorFocused")
}

/// One row of tabs. Each tab is its own `EditorModel` (and its own WebView),
/// so switching tabs preserves content/cursor/undo. A window has one group,
/// or two side by side when split — like VS Code's editor groups.
final class EditorGroup: ObservableObject {
    @Published var tabs: [EditorModel]
    @Published var activeID: EditorModel.ID

    init() {
        let first = EditorModel()
        tabs = [first]
        activeID = first.id
    }

    var active: EditorModel {
        tabs.first { $0.id == activeID } ?? tabs[0]
    }

    func contains(_ editor: EditorModel) -> Bool { tabs.contains { $0 === editor } }
    func tab(showing url: URL) -> EditorModel? { tabs.first { $0.currentURL == url } }

    func activate(_ id: EditorModel.ID) { activeID = id }

    @discardableResult
    func newTab() -> EditorModel {
        let e = EditorModel()
        e.vaultRoot = tabs.first?.vaultRoot
        tabs.append(e)
        activeID = e.id
        return e
    }

    /// Open a URL here — in a new tab, or replacing the active tab's content.
    /// The window model has already made sure no other group holds it.
    func open(_ url: URL, inNewTab: Bool = false) {
        if let existing = tab(showing: url) {
            activeID = existing.id
            return
        }
        // An untouched blank tab is reused rather than left behind.
        let blank = active.currentURL == nil && !active.isDirty
        let target = inNewTab && !blank ? newTab() : active
        target.open(url)
    }

    /// Close a tab. Its last edits may not be on disk yet (autosave runs ~2s
    /// after typing), so they're saved first; the closure keeps the editor
    /// alive until that's done. If they can't be saved, the tab comes back.
    func close(_ id: EditorModel.ID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[i]
        detach(at: i)
        closing.flushToDisk { [weak self] ok in
            guard !ok, let self else { return }
            self.tabs.append(closing)
            self.activeID = closing.id
            closing.statusText = "無法儲存，分頁沒有關閉"
        }
    }

    private func detach(at i: Int) {
        let id = tabs[i].id
        tabs.remove(at: i)
        if activeID == id {
            activeID = tabs[min(i, tabs.count - 1)].id
        }
    }

    /// Remove a tab even when it's the last one (a blank tab takes its place).
    func remove(_ id: EditorModel.ID) {
        if tabs.count == 1, tabs[0].id == id {
            let blank = EditorModel()
            blank.vaultRoot = tabs[0].vaultRoot
            tabs = [blank]
            activeID = blank.id
        } else if let i = tabs.firstIndex(where: { $0.id == id }) {
            detach(at: i)   // callers have already saved it
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

    /// A URL dropped onto tab `targetID` of this group:
    ///  • already open here → reorder it to that slot;
    ///  • otherwise → open it as a new tab inserted at that slot.
    func handleTabDrop(_ url: URL, onto targetID: EditorModel.ID, after: Bool = false) {
        guard let targetIdx = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        if let srcIdx = tabs.firstIndex(where: { $0.currentURL == url }) {
            let moved = tabs.remove(at: srcIdx)
            var insertAt = tabs.firstIndex(where: { $0.id == targetID }).map { after ? $0 + 1 : $0 } ?? tabs.count
            insertAt = max(0, min(insertAt, tabs.count))
            tabs.insert(moved, at: insertAt)
            activeID = moved.id
        } else {
            let e = EditorModel()
            e.vaultRoot = tabs.first?.vaultRoot
            tabs.insert(e, at: after ? targetIdx + 1 : targetIdx)
            activeID = e.id
            e.open(url)   // deferred until the new tab's WebView is ready
        }
    }
}

/// Per-window editing state: the left group, the right group when split, and
/// which one the user is working in. Commands that aren't aimed at a pane —
/// clicking a file in the sidebar, Quick Open, following a [[link]] — go to the
/// focused pane, so "click into the right side, then pick a file" opens it there.
///
/// A file is open in at most one editor per window. Two editors on one file
/// would each autosave their own buffer over the other's; asking for a file
/// that the other pane shows moves it across instead.
final class TabsModel: ObservableObject {
    let left = EditorGroup()
    let right = EditorGroup()

    @Published var splitOn = false {
        didSet {
            guard oldValue != splitOn else { return }
            if splitOn { right.active.vaultRoot = left.active.vaultRoot } else { closeRight() }
        }
    }
    /// false = side-by-side (left|right), true = stacked (top/bottom).
    @Published var splitVertical = false
    /// The pane keyboard focus is in. Always the left one when not split.
    @Published private(set) var focusedRight = false

    /// The NSWindow showing this model (set by the window tracker), so another
    /// window can bring it forward.
    weak var window: NSWindow?

    /// Every live window's model: a file stays in one editor across windows,
    /// not just within one, for the same autosave reason.
    private static let all = NSHashTable<TabsModel>.weakObjects()

    private var bag = Set<AnyCancellable>()

    init() {
        Self.all.add(self)
        // The groups publish their own changes; re-publish them so views that
        // read through the window (title, focused editor, menus) refresh too.
        for g in [left, right] {
            g.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &bag)
        }
        NotificationCenter.default.publisher(for: .noteproEditorFocused)
            .sink { [weak self] note in
                guard let self, let e = note.object as? EditorModel else { return }
                if self.splitOn, self.right.contains(e) { self.focus(right: true) }
                else if self.left.contains(e) { self.focus(right: false) }
            }
            .store(in: &bag)
    }

    var focused: EditorGroup { splitOn && focusedRight ? right : left }
    var unfocused: EditorGroup { focused === left ? right : left }

    func focus(right: Bool) {
        let r = right && splitOn
        if focusedRight != r { focusedRight = r }
    }
    func isFocused(_ g: EditorGroup) -> Bool { g === focused }

    // ── The focused pane, for call sites that mean "where I'm working" ──
    var active: EditorModel { focused.active }
    var activeID: EditorModel.ID { focused.activeID }
    func newTab() { focused.newTab() }
    func closeActive() { focused.closeActive() }
    func nextTab() { focused.nextTab() }
    func prevTab() { focused.prevTab() }
    func activate(at index: Int) { focused.activate(at: index) }

    /// Every editor in the window, both panes — for save / rename / reload
    /// sweeps that must not miss the right side.
    var allEditors: [EditorModel] { left.tabs + right.tabs }

    /// The window is closing: save every editor with pending edits. Each
    /// closure holds its editor (and so its web view) alive until the save
    /// lands, even though the window and this model are going away.
    func flushAll() {
        for e in allEditors where e.isDirty {
            e.flushToDisk { _ in withExtendedLifetime(e) {} }
        }
    }

    /// Open in the focused pane — or, if the other pane already shows the
    /// file, just go there. A plain click (sidebar, Quick Open, a link) means
    /// "show me this", not "take it away from the other side".
    func open(_ url: URL, inNewTab: Bool = false) {
        if splitOn, let e = unfocused.tab(showing: url) {
            unfocused.activate(e.id)
            focus(right: unfocused === right)
            return
        }
        open(url, in: focused, inNewTab: inNewTab)
    }

    /// If another window shows `url`, bring it forward on that tab.
    @discardableResult
    func showIfOpenElsewhere(_ url: URL) -> Bool {
        guard let (owner, og, e) = elsewhere(url) else { return false }
        og.activate(e.id)
        owner.focus(right: og === owner.right)
        owner.window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// Open in the pane you're NOT working in, splitting first if needed —
    /// ⌥-click in the sidebar, or "Open to the Side".
    func openToSide(_ url: URL) {
        if !splitOn {
            splitOn = true
            open(url, in: right, inNewTab: true)
            focus(right: true)
        } else {
            let target = unfocused
            open(url, in: target, inNewTab: true)
            focus(right: target === right)
        }
    }

    /// Open `url` in group `g`. If the other group shows it, move it over
    /// (after its edits are on disk) rather than opening a second copy. If
    /// another window shows it, bring that window forward on that tab.
    func open(_ url: URL, in g: EditorGroup, inNewTab: Bool = false) {
        if showIfOpenElsewhere(url) { return }
        let other = g === left ? right : left
        guard let src = other.tab(showing: url) else {
            g.open(url, inNewTab: inNewTab)
            return
        }
        src.flushToDisk { [weak self, weak g, weak other] ok in
            guard let self, let g, let other else { return }
            // Couldn't read the buffer: keep the file where it is rather than
            // reload it elsewhere from a disk copy missing the latest edits.
            guard ok else { other.activate(src.id); self.focus(right: other === self.right); return }
            other.remove(src.id)
            g.open(url, inNewTab: inNewTab)
        }
    }

    /// The window, group and editor already showing `url`, if it isn't this one.
    private func elsewhere(_ url: URL) -> (TabsModel, EditorGroup, EditorModel)? {
        for m in Self.all.allObjects where m !== self {
            for g in [m.left, m.right] {
                if let e = g.tab(showing: url) { return (m, g, e) }
            }
        }
        return nil
    }

    /// A tab or file dropped onto group `g`'s tab bar: reorder / insert there,
    /// or move it across if the other pane (or window) has it.
    func drop(_ url: URL, onto targetID: EditorModel.ID, in g: EditorGroup, after: Bool = false) {
        focus(right: g === right)
        let other = g === left ? right : left
        if other.tab(showing: url) != nil || elsewhere(url) != nil {
            open(url, in: g, inNewTab: true)
        } else {
            g.handleTabDrop(url, onto: targetID, after: after)
        }
    }

    /// Send group `g`'s current file to the other pane, splitting if needed.
    func moveToOtherSide(from g: EditorGroup) {
        guard let url = g.active.currentURL else { return }
        if !splitOn { splitOn = true }
        let target = g === left ? right : left
        open(url, in: target, inNewTab: true)
        focus(right: target === right)
    }

    /// Let go of `url` (saved first) so another window can open it. `false`
    /// when its buffer couldn't be saved — the file then stays here.
    func release(_ url: URL, then done: @escaping (Bool) -> Void) {
        guard let g = [left, right].first(where: { $0.tab(showing: url) != nil }),
              let e = g.tab(showing: url) else { done(true); return }
        e.flushToDisk { ok in
            if ok { g.remove(e.id) }
            done(ok)
        }
    }

    /// Closing the split folds the right pane's files back in as tabs on the
    /// left, so nothing you had open disappears.
    private func closeRight() {
        focusedRight = false
        let files = right.tabs.compactMap(\.currentURL)
        let pending = right.tabs.filter { $0.currentURL != nil }
        var remaining = pending.count
        var allSaved = true
        let finish = { [weak self] in
            guard let self else { return }
            // A buffer that couldn't be saved stays where it is: reopen the
            // split rather than drop its edits.
            guard allSaved else { self.splitOn = true; return }
            for e in self.right.tabs { self.right.remove(e.id) }
            for url in files where self.left.tab(showing: url) == nil {
                self.left.open(url, inNewTab: true)
            }
        }
        guard remaining > 0 else { finish(); return }
        for e in pending {
            e.flushToDisk { ok in
                if !ok { allSaved = false }
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }
    }
}
