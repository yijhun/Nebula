import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One window: a vault sidebar + an editor pane. The vault is shared across
/// windows; selection and the editor are per-window.
struct RootView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var semIndex: SemanticIndex
    @EnvironmentObject var projects: ProjectsModel
    @StateObject private var tabs = TabsModel()
    /// Owned here (not inside the sheet) so recording keeps running — and the
    /// editor stays interactive — after the setup sheet is dismissed.
    @StateObject private var recorder = MeetingRecorder()
    @State private var selection = Set<URL>()
    @State private var modal: Modal?

    /// All modal sheets routed through ONE presentation slot (SwiftUI only
    /// reliably presents one `.sheet` per view).
    enum Modal: Identifiable {
        case palette(String, String)   // mode ("files"/"content"), seed query
        case semantic, graph, history, shortcuts, transcribe, literature, cowork
        case library, searchReplace, todos
        case database(DBTarget)
        var id: String {
            switch self {
            case .palette: return "palette"
            case .semantic: return "semantic"
            case .graph: return "graph"
            case .history: return "history"
            case .shortcuts: return "shortcuts"
            case .transcribe: return "transcribe"
            case .literature: return "literature"
            case .cowork: return "cowork"
            case .library: return "library"
            case .searchReplace: return "searchReplace"
            case .todos: return "todos"
            case .database(let t): return "db-\(t.id)"
            }
        }
    }
    @AppStorage("theme") private var themeSetting = "system"
    @Environment(\.openWindow) private var openWindow

    private var colorScheme: ColorScheme? {
        switch themeSetting {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        observers(lifecycle(decorated(splitView)))
            .navigationTitle(tabs.active.displayName)
            .sheet(item: $modal) { m in sheetView(m) }
            .overlay(alignment: .bottomTrailing) {
                RecordingHUD(rec: recorder)
                    .padding(.trailing, 18).padding(.bottom, 18)
            }
            // When transcription finishes, surface the review form as a sheet.
            .onChange(of: recorder.phase) { phase in
                if phase == .review { modal = .transcribe }
            }
    }

    private var splitView: some View {
        NavigationSplitView {
            VaultSidebar(selection: $selection)
                .frame(minWidth: 200)
        } detail: {
            Group {
                if tabs.splitOn {
                    if tabs.splitVertical {
                        VSplitView {
                            EditorPane().frame(minHeight: 160)
                            SecondaryPane()
                                .environmentObject(tabs.secondary)
                                .frame(minHeight: 140)
                        }
                    } else {
                        HSplitView {
                            EditorPane().frame(minWidth: 260)
                            SecondaryPane()
                                .environmentObject(tabs.secondary)
                                .frame(minWidth: 240)
                        }
                    }
                } else {
                    EditorPane()
                }
            }
            .frame(minWidth: 420)
            .animation(.easeInOut(duration: 0.2), value: tabs.splitOn)
        }
    }

    private func decorated<V: View>(_ v: V) -> some View {
        v.environmentObject(tabs)
            .environmentObject(tabs.active)   // active tab's editor as the EditorModel env
            .focusedSceneValue(\.editorModel, tabs.active)
            .focusedSceneValue(\.tabsModel, tabs)
            .preferredColorScheme(colorScheme)
    }

    private func lifecycle<V: View>(_ v: V) -> some View {
        v.onAppear {
            vault.onChanged = { [weak vault] in
                guard let vault else { return }
                index.forceRebuild(vault)
                projects.reload(vault: vault.rootURL)
                broadcastNoteList()
            }
            broadcastNoteList()
            projects.reload(vault: vault.rootURL)
            tabs.active.vaultRoot = vault.rootURL
            tabs.secondary.vaultRoot = vault.rootURL
        }
        .onChange(of: vault.rootURL) { _, root in
            tabs.active.vaultRoot = root; tabs.secondary.vaultRoot = root
            projects.reload(vault: root)
        }
        .onChange(of: tabs.activeID) { _, _ in tabs.active.vaultRoot = vault.rootURL }
        .task {
            // Weekly to-do digest: wait for the vault + index to settle, then
            // run at most once per 7 days (Settings-gated).
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            index.buildIfNeeded(vault)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let url = TodoDigest.autoRunIfDue(index.entries, vault: vault) {
                tabs.active.statusText = "已自動彙整本週待辦 → \(url.lastPathComponent)"
            }
        }
        .onChange(of: selection) { _, newValue in
            // Open only on a single selection; multi-select is for batch ops.
            if newValue.count == 1, let url = newValue.first {
                if url.pathExtension.lowercased() == "pdf" {
                    openWindow(id: "pdf", value: url)   // papers open in a reader window
                } else {
                    tabs.open(url)
                }
            }
        }
        .onChange(of: tabs.activeID) { _, _ in
            if let url = tabs.active.currentURL { selection = [url] }   // sync highlight
        }
    }

    // Split into two hops purely so the Swift type-checker copes — one long
    // .onReceive chain times out ("unable to type-check in reasonable time").
    private func observers<V: View>(_ v: V) -> some View {
        observers2(observers1(v))
    }

    private func observers1<V: View>(_ v: V) -> some View {
        v.onReceive(NotificationCenter.default.publisher(for: .noteproRequestNoteList)) { _ in
            broadcastNoteList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenWikilink)) { note in
            guard let target = note.userInfo?["target"] as? String else { return }
            if let url = index.resolveNote(target) { selection = [url]; tabs.open(url) }
            else { tabs.active.statusText = "找不到筆記：\(target)" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenDatabase)) { note in
            flushDirtyEditors(); index.buildIfNeeded(vault)
            let folder = note.userInfo?["folder"] as? URL
            let title = (note.userInfo?["title"] as? String) ?? (folder?.lastPathComponent ?? "資料庫")
            modal = .database(DBTarget(folder: folder, title: title))
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenGraph)) { _ in
            index.buildIfNeeded(vault); modal = .graph
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenHistory)) { _ in modal = .history }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenShortcuts)) { _ in modal = .shortcuts }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenTranscribe)) { _ in modal = .transcribe }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenLiterature)) { _ in
            index.buildIfNeeded(vault); modal = .literature
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenCowork)) { _ in modal = .cowork }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenLibrary)) { _ in
            flushDirtyEditors(); index.buildIfNeeded(vault); modal = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenSearchReplace)) { _ in
            flushDirtyEditors(); index.buildIfNeeded(vault); modal = .searchReplace
        }
    }

    private func observers2<V: View>(_ v: V) -> some View {
        v.onReceive(NotificationCenter.default.publisher(for: .noteproOpenInSplit)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            tabs.splitOn = true
            tabs.secondary.vaultRoot = vault.rootURL
            tabs.secondary.open(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenInNewTab)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            selection = [url]
            tabs.open(url, inNewTab: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenInWindow)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            openWindow(id: "note", value: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenPreviewWindow)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            openWindow(id: "preview", value: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenSemantic)) { _ in modal = .semantic }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenPalette)) { note in
            modal = .palette(note.userInfo?["mode"] as? String ?? "files",
                             note.userInfo?["query"] as? String ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenTodos)) { _ in
            flushDirtyEditors(); index.buildIfNeeded(vault); modal = .todos
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproFileRenamed)) { note in
            guard let old = note.userInfo?["old"] as? URL,
                  let new = note.userInfo?["new"] as? URL else { return }
            for t in tabs.tabs { t.fileRenamed(from: old, to: new) }
            tabs.secondary.fileRenamed(from: old, to: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenClaudeCode)) { _ in
            if let err = ClaudeCodeLauncher.open(vault: vault.rootURL) {
                tabs.active.statusText = err
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproVaultFilesChanged)) { note in
            let paths = Set((note.userInfo?["paths"] as? [String] ?? [])
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            // Empty (FSEvents overflow) → check every open editor to be safe.
            func hit(_ e: EditorModel) -> Bool {
                guard let cur = e.currentURL?.standardizedFileURL.path else { return false }
                return paths.isEmpty || paths.contains(cur)
            }
            for t in tabs.tabs where hit(t) { t.reloadIfExternallyChanged() }
            if hit(tabs.secondary) { tabs.secondary.reloadIfExternallyChanged() }
        }
    }

    /// Persist unsaved edits in every pane before opening a modal whose actions
    /// read/rewrite vault files from disk (to-do tick, backfill, replace) —
    /// otherwise they'd operate on a file missing the last ~2s of typing. The
    /// sheet blocks further typing, so flushing here closes the race window.
    private func flushDirtyEditors() {
        for t in tabs.tabs { t.saveIfDirty() }
        tabs.secondary.saveIfDirty()
    }

    @ViewBuilder
    private func sheetView(_ m: Modal) -> some View {
        switch m {
        case .palette(let mode, let q):
            CommandPalette(
                mode: mode == "content" ? .content : .files, initialQuery: q,
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(index)
        case .semantic:
            SemanticSearchView(
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(index).environmentObject(semIndex)
        case .database(let t):
            DatabaseView(
                target: t,
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(index)
        case .graph:
            GraphView(
                current: tabs.active.currentURL,
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(index)
        case .history:
            HistoryView(onClose: { modal = nil }).environmentObject(tabs.active)
        case .shortcuts:
            ShortcutsView(onClose: { modal = nil })
        case .transcribe:
            TranscribeView(
                rec: recorder,
                onOpen: { url in vault.refresh(); selection = [url]; tabs.open(url); modal = nil },
                onDismiss: { modal = nil },      // hide the sheet, keep recording
                onClose: { modal = nil }
            )
            .environmentObject(vault)
        case .literature:
            LiteratureSearchView(
                onOpen: { url in vault.refresh(); selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(tabs.active).environmentObject(index)
        case .cowork:
            CoworkView(onClose: { modal = nil }).environmentObject(tabs.active)
        case .library:
            LiteratureLibraryView(
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onChanged: { url in
                    for t in tabs.tabs where t.currentURL == url { t.open(url) }
                    if tabs.secondary.currentURL == url { tabs.secondary.open(url) }
                    index.forceRebuild(vault)
                },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(index)
        case .searchReplace:
            SearchReplaceView(
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onReplaced: { urls in
                    // Reload any open tab whose file we rewrote on disk.
                    for t in tabs.tabs where t.currentURL.map(urls.contains) == true { if let u = t.currentURL { t.open(u) } }
                    if tabs.secondary.currentURL.map(urls.contains) == true, let u = tabs.secondary.currentURL { tabs.secondary.open(u) }
                    index.forceRebuild(vault)
                },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(index)
        case .todos:
            TodoLibraryView(
                onOpen: { url, line in selection = [url]; tabs.open(url)
                          if let line { NotificationCenter.default.post(
                              name: .noteproMirrorJump, object: nil,
                              userInfo: ["url": url, "line": line]) }
                          modal = nil },
                onChanged: { url in
                    for t in tabs.tabs where t.currentURL == url { t.open(url) }
                    if tabs.secondary.currentURL == url { tabs.secondary.open(url) }
                    index.forceRebuild(vault)
                },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(index)
        }
    }

    /// Broadcast the vault's note names to all editors (for `[[` completion +
    /// broken-link flags).
    private func broadcastNoteList() {
        NotificationCenter.default.post(name: .noteproNoteList, object: nil,
                                        userInfo: ["names": index.noteNames()])
    }
}
