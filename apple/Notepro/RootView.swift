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
    @State private var selection = Set<URL>()
    @State private var modal: Modal?

    /// All modal sheets routed through ONE presentation slot (SwiftUI only
    /// reliably presents one `.sheet` per view).
    enum Modal: Identifiable {
        case palette(String, String)   // mode ("files"/"content"), seed query
        case semantic, graph, history, shortcuts, transcribe, literature, cowork
        case library, searchReplace
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
            index.buildIfNeeded(vault)
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
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenLiterature)) { _ in modal = .literature }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenCowork)) { _ in modal = .cowork }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenLibrary)) { _ in
            index.buildIfNeeded(vault); modal = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteproOpenSearchReplace)) { _ in
            index.buildIfNeeded(vault); modal = .searchReplace
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
                onOpen: { url in vault.refresh(); selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(vault)
        case .literature:
            LiteratureSearchView(
                onOpen: { url in vault.refresh(); selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(vault).environmentObject(tabs.active)
        case .cowork:
            CoworkView(onClose: { modal = nil }).environmentObject(tabs.active)
        case .library:
            LiteratureLibraryView(
                onOpen: { url in selection = [url]; tabs.open(url); modal = nil },
                onClose: { modal = nil }
            )
            .environmentObject(index)
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
        }
    }

    /// Broadcast the vault's note names to all editors (for `[[` completion +
    /// broken-link flags).
    private func broadcastNoteList() {
        NotificationCenter.default.post(name: .noteproNoteList, object: nil,
                                        userInfo: ["names": index.noteNames()])
    }
}

/// File-explorer sidebar listing the vault's files (Obsidian-style), with
/// right-click file operations: rename / delete / duplicate / new / reveal.
struct VaultSidebar: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var editor: EditorModel
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var semIndex: SemanticIndex
    @EnvironmentObject var projects: ProjectsModel
    @Binding var selection: Set<URL>

    @State private var renameTarget: FileNode?
    @State private var renameText = ""
    @State private var zoteroQuery = ""
    @State private var zoteroResults: [ZoteroItem] = []
    @State private var relatedNotes: [SemHit] = []
    @AppStorage("expand.drafts") private var expDrafts = false
    @AppStorage("expand.formal") private var expFormal = false
    @AppStorage("expand.recent") private var expRecent = true
    // Collapsible sidebar sections (persisted).
    @AppStorage("sec.pinned") private var secPinned = true
    @AppStorage("sec.vault") private var secVault = true
    @AppStorage("sec.smart") private var secSmart = false
    @AppStorage("sec.category") private var secCategory = false
    @AppStorage("sec.tags") private var secTags = false
    @AppStorage("sec.zotero") private var secZotero = false
    @AppStorage("sec.outline") private var secOutline = true
    @AppStorage("sec.related") private var secRelated = false

    private func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        return node.url.pathExtension.lowercased() == "tex" ? "doc.plaintext" : "doc.text"
    }

    /// Directory new items should go into, based on the current selection.
    private var newItemDir: URL? {
        selection.first?.deletingLastPathComponent() ?? vault.rootURL
    }

    var body: some View {
        Group {
            if vault.rootURL == nil {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(LZ("尚未開啟資料夾")).foregroundStyle(.secondary)
                    Button(LZ("開啟資料夾…")) { vault.openVault() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    pinnedSection
                    Section(isExpanded: $secVault) {
                        OutlineGroup(vault.tree, children: \.children) { node in
                            row(node)
                        }
                    } header: { Text(vault.rootURL?.lastPathComponent ?? "Vault") }
                    smartSection
                    categorySection
                    let tags = index.allTags()
                    if !tags.isEmpty {
                        Section(isExpanded: $secTags) {
                            ForEach(tags, id: \.tag) { item in
                                Button {
                                    editor.openPalette(.content, query: "#\(item.tag)")
                                } label: {
                                    HStack {
                                        Image(systemName: "number").foregroundStyle(.secondary)
                                        Text(item.tag)
                                        Spacer()
                                        Text("\(item.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: { Text(LZ("標籤 Tags")) }
                    }
                    zoteroSection
                    outlineSection
                    relatedSection
                }
                .listStyle(.sidebar)
                .contextMenu {
                    Button(LZ("新文件")) { if let u = vault.newNote(in: vault.rootURL) { selection = [u] } }
                    Button(LZ("新資料夾")) { vault.createFolder(in: vault.rootURL) }
                    Divider()
                    Menu(LZ("排序方式")) { sortPicker }
                }
            }
        }
        .onAppear { index.buildIfNeeded(vault); refreshRelated() }
        .onChange(of: editor.currentURL) { _, _ in refreshRelated() }
        .onChange(of: semIndex.ready) { _, _ in refreshRelated() }
        .onReceive(NotificationCenter.default.publisher(for: .noteproNewProject)) { _ in
            guard let root = vault.rootURL else { return }
            let dir = newItemDir ?? root
            let template = UserDefaults.standard.string(forKey: "defaultTemplate") ?? "apj"
            if let p = projects.create(in: dir, name: "新專案", template: template) {
                vault.refresh()
                if let first = ProjectsModel.paperChapters(p).first { selection = [first] }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { if let url = vault.newNote(in: newItemDir) { selection = [url] } } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("新文件").disabled(vault.rootURL == nil)
                Button { vault.createFolder(in: newItemDir) } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("新資料夾").disabled(vault.rootURL == nil)
                Menu {
                    sortPicker
                } label: {
                    Label(sortLabel, systemImage: "arrow.up.arrow.down")
                }
                .menuIndicator(.visible)
                .help("檔案排序：名稱 / 日期 / 類型")
                Button { vault.refresh(); index.forceRebuild(vault) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新整理（含索引）")
            }
        }
        .alert("重新命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("確定") { commitRename() }
        }
    }

    @ViewBuilder
    private var zoteroSection: some View {
        Section(isExpanded: $secZotero) {
            TextField("搜尋 Zotero…", text: $zoteroQuery)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit(searchZotero)
            ForEach(zoteroResults) { it in
                Button { editor.insertCitation(it.citekey) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.title).font(.caption).lineLimit(2)
                        Text("\(it.year.isEmpty ? "" : it.year + " · ")@\(it.citekey)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("點擊插入引用 @\(it.citekey)")
            }
        } header: { Text(LZ("Zotero 文獻")) }
    }

    /// The current sort mode as a human label (shown on the toolbar button).
    private var sortLabel: String {
        switch vault.sortMode {
        case "date": return LZ("修改日期")
        case "type": return LZ("類型")
        default: return LZ("名稱")
        }
    }

    /// Shared file-sort picker (toolbar menu + empty-area right-click). Inline
    /// style → shows a checkmark on the active mode.
    private var sortPicker: some View {
        Picker(LZ("排序方式"), selection: $vault.sortMode) {
            Label(LZ("名稱"), systemImage: "textformat").tag("name")
            Label(LZ("修改日期"), systemImage: "calendar").tag("date")
            Label(LZ("類型"), systemImage: "doc.on.doc").tag("type")
        }
        .pickerStyle(.inline)
    }

    private func searchZotero() {
        ZoteroService.search(zoteroQuery) { zoteroResults = $0 }
    }

    private func refreshRelated() {
        relatedNotes = semIndex.ready ? semIndex.related(to: editor.currentURL) : []
    }

    // MARK: - Projects (folders that compile their .md into one paper)

    /// The live Project for a folder, if it's a project.
    private func project(for folder: URL) -> Project? {
        projects.projects.first { $0.folder == folder } ?? ProjectsModel.load(folder)
    }

    private func moveChapter(_ p: Project, _ filename: String, by delta: Int) {
        guard let i = p.meta.paper.firstIndex(of: filename) else { return }
        let j = i + delta
        guard j >= 0, j < p.meta.paper.count else { return }
        projects.reorderPaper(p, from: IndexSet(integer: i), to: delta < 0 ? j : j + 1)
        vault.refresh()   // re-scan so the tree re-orders + re-badges
    }

    private func importNote(into p: Project) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "匯入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = projects.importNote(url, into: p, addToPaper: false)
    }

    /// Notes semantically similar to the current one (from the local index).
    @ViewBuilder private var relatedSection: some View {
        if !relatedNotes.isEmpty {
            Section(isExpanded: $secRelated) {
                ForEach(relatedNotes) { hit in
                    Button { selection = [hit.url] } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.name).font(.caption).lineLimit(1)
                                Text(hit.snippet).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text(LZ("相關筆記 Related")) }
        }
    }

    /// Document structure of the active editor (headings + figures/tables).
    /// Click a row to scroll the editor there; floats never \ref'd show ⚠.
    @ViewBuilder private var outlineSection: some View {
        if !editor.outline.isEmpty {
            Section(isExpanded: $secOutline) {
                ForEach(editor.outline) { item in
                    Button { editor.scrollTo(pos: item.pos) } label: {
                        HStack(spacing: 5) {
                            if item.kind == "figure" {
                                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                            } else if item.kind == "table" {
                                Image(systemName: "tablecells").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(item.text)
                                .font(item.kind == "heading" ? .caption : .caption2)
                                .lineLimit(1)
                            if item.referenced == false {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9)).foregroundStyle(.orange)
                                    .help("未被 \\ref 引用")
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(item.level) * 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text(LZ("大綱 Outline")) }
        }
    }

    private static let colorNames = ["red", "orange", "yellow", "green", "blue", "purple"]
    private func colorValue(_ name: String?) -> Color? {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return nil
        }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        if node.isDirectory {
            HStack(spacing: 4) {
                Label {
                    Text(node.name)
                } icon: {
                    Image(systemName: node.isProject ? "doc.on.doc.fill" : "folder")
                        .foregroundStyle(node.isProject ? Color.blue : (colorValue(vault.color(for: node.url)) ?? Color.accentColor))
                }
                if node.isProject {
                    Spacer(minLength: 0)
                    Button {
                        if let p = project(for: node.url) { editor.compileProject(p) }
                    } label: { Image(systemName: "hammer") }
                        .buttonStyle(.borderless).help("編譯論文").disabled(editor.isExporting)
                }
            }
            .contextMenu { folderMenu(node) }
            .dropDestination(for: URL.self) { urls, _ in
                for u in urls { vault.move(u, toFolder: node.url) }
                return true
            }
        } else {
            Label {
                HStack(spacing: 4) {
                    if let i = node.paperIndex {
                        Text("\(i)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(minWidth: 14)
                            .padding(.vertical, 1).padding(.horizontal, 3)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(node.name)
                    if vault.isPinned(node.url) {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    }
                }
            } icon: {
                Image(systemName: icon(for: node))
            }
            .tag(node.url)
            .draggable(node.url)
            .contextMenu { fileMenu(node) }
        }
    }

    /// A file row used by the virtual sections (pinned / smart / category).
    @ViewBuilder
    private func virtualRow(_ entry: IndexEntry) -> some View {
        Button { selection = [entry.url] } label: {
            Label {
                Text(entry.name).lineLimit(1)
            } icon: {
                Image(systemName: entry.ext == "tex" ? "doc.plaintext" : "doc.text")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pinnedSection: some View {
        let pins = index.entries.filter { vault.pinned.contains($0.url.path) }
        if !pins.isEmpty {
            Section(isExpanded: $secPinned) {
                ForEach(pins) { virtualRow($0) }
            } header: { Text(LZ("置頂 Pinned")) }
        }
    }

    @ViewBuilder
    private var smartSection: some View {
        Section(isExpanded: $secSmart) {
            DisclosureGroup(isExpanded: $expDrafts) {
                ForEach(index.drafts()) { virtualRow($0) }
            } label: { Label("\(LZ("草稿 (.md)")) · \(index.drafts().count)", systemImage: "doc.text") }
            DisclosureGroup(isExpanded: $expFormal) {
                ForEach(index.formal()) { virtualRow($0) }
            } label: { Label("\(LZ("正式稿 (.tex)")) · \(index.formal().count)", systemImage: "doc.plaintext") }
            DisclosureGroup(isExpanded: $expRecent) {
                ForEach(index.recent(10)) { virtualRow($0) }
            } label: { Label(LZ("最近修改 Recent"), systemImage: "clock") }
        } header: { Text(LZ("智慧分類 Smart")) }
    }

    @ViewBuilder
    private var categorySection: some View {
        let cats = index.categories()
        if !cats.isEmpty {
            Section(isExpanded: $secCategory) {
                ForEach(cats, id: \.name) { c in
                    DisclosureGroup {
                        ForEach(c.entries) { virtualRow($0) }
                    } label: { Label("\(c.name) · \(c.entries.count)", systemImage: "bookmark") }
                }
            } header: { Text(LZ("類別 Category")) }
        }
    }

    @ViewBuilder
    private func fileMenu(_ node: FileNode) -> some View {
        let dir = node.url.deletingLastPathComponent()
        Button(LZ("開啟")) { selection = [node.url] }
        if node.url.pathExtension.lowercased() != "pdf" {
            Button(LZ("在右側並排開啟")) {
                NotificationCenter.default.post(name: .noteproOpenInSplit, object: nil,
                                                userInfo: ["url": node.url])
            }
            Button(LZ("在新分頁開啟")) {
                NotificationCenter.default.post(name: .noteproOpenInNewTab, object: nil,
                                                userInfo: ["url": node.url])
            }
            Button(LZ("在新視窗開啟")) {
                NotificationCenter.default.post(name: .noteproOpenInWindow, object: nil,
                                                userInfo: ["url": node.url])
            }
        }
        if node.url.pathExtension.lowercased() == "md", let p = project(for: dir) {
            if node.paperIndex != nil {
                Button("上移章節") { moveChapter(p, node.name, by: -1) }
                Button("下移章節") { moveChapter(p, node.name, by: 1) }
                Button("移出論文") { projects.removeFromPaper(p, file: node.name); vault.refresh() }
            } else {
                Button("加入論文") { projects.addToPaper(p, file: node.name); vault.refresh() }
            }
            Divider()
        }
        Button(vault.isPinned(node.url) ? "取消置頂" : "置頂") { vault.togglePin(node.url) }
        Button(LZ("重新命名…")) { renameText = node.name; renameTarget = node }
        Button(LZ("複製")) { if let u = vault.duplicate(node) { selection = [u] } }
        Divider()
        Button(LZ("新文件")) { if let u = vault.newNote(in: dir) { selection = [u] } }
        Button(LZ("新資料夾")) { vault.createFolder(in: dir) }
        Divider()
        Button(LZ("在 Finder 顯示")) { vault.reveal(node) }
        Button(LZ("刪除"), role: .destructive) { deleteNode(node) }
    }

    @ViewBuilder
    private func folderMenu(_ node: FileNode) -> some View {
        Button(LZ("新文件")) { if let u = vault.newNote(in: node.url) { selection = [u] } }
        Button(LZ("新資料夾")) { vault.createFolder(in: node.url) }
        Divider()
        if node.isProject {
            Button("編譯論文") { if let p = project(for: node.url) { editor.compileProject(p) } }
            Button("投稿前檢查") { if let p = project(for: node.url) { editor.checkSubmission(p) } }
            Button("投稿打包…") { if let p = project(for: node.url) { editor.exportProjectFlat(p) } }
            Button("匯入筆記…") { if let p = project(for: node.url) { importNote(into: p) } }
            Button("取消論文專案") { projects.unmark(node.url); vault.refresh() }
        } else {
            Button("設為論文專案") {
                let template = UserDefaults.standard.string(forKey: "defaultTemplate") ?? "academic"
                projects.markAsProject(node.url, template: template); vault.refresh()
            }
        }
        Divider()
        Button(LZ("以資料庫開啟")) {
            NotificationCenter.default.post(name: .noteproOpenDatabase, object: nil,
                                            userInfo: ["folder": node.url, "title": node.name])
        }
        Button(LZ("重新命名…")) { renameText = node.name; renameTarget = node }
        Menu(LZ("顏色 Color")) {
            Button(LZ("無")) { vault.setColor(nil, for: node.url) }
            ForEach(Self.colorNames, id: \.self) { c in
                Button(c.capitalized) { vault.setColor(c, for: node.url) }
            }
        }
        Button(LZ("在 Finder 顯示")) { vault.reveal(node) }
        Divider()
        Button(LZ("刪除"), role: .destructive) { deleteNode(node) }
    }

    private func commitRename() {
        guard let node = renameTarget else { return }
        if let newURL = vault.rename(node, to: renameText) {
            if editor.currentURL == node.url { editor.open(newURL) }
            if selection.contains(node.url) { selection.remove(node.url); selection.insert(newURL) }
        }
        renameTarget = nil
    }

    /// Delete the right-clicked node — or the whole selection if it's part of a
    /// multi-selection.
    private func deleteNode(_ node: FileNode) {
        let targets: [URL] = (selection.contains(node.url) && selection.count > 1)
            ? Array(selection) : [node.url]
        for u in targets { vault.delete(url: u) }
        selection.subtract(targets)
    }
}

/// The detail pane: a toolbar + the web editor.
struct EditorPane: View {
    @EnvironmentObject var editor: EditorModel
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var tabs: TabsModel
    @EnvironmentObject var index: IndexService
    @Environment(\.openWindow) private var openWindow

    /// LaTeX templates offered by the toolbar menu (content lives in the web core).
    static let templates: [(id: String, label: String)] = [
        ("article", "Article"),
        ("academic", "Academic (A4)"),
        ("apj", "ApJ (AASTeX)"),
        ("mnras", "MNRAS"),
        ("aanda", "A&A"),
        ("beamer", "Beamer (Slides)"),
    ]

    @State private var tabBarDropTargeted = false
    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs.tabs) { tab in TabChip(tab: tab) }
                    // Trailing flexible spacer so dropping anywhere in the empty
                    // part of the bar still lands a drop (appends to the end).
                    Color.clear.frame(minWidth: 40, maxWidth: .infinity)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            Button { tabs.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("新分頁（檢視選單 ⌘T）")
                .padding(.horizontal, 8)
        }
        // Fixed compact height — a horizontal ScrollView is otherwise greedy in
        // the vertical axis and would balloon the bar to fill the window.
        .frame(height: 34)
        .background(tabBarDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .background(.bar)
        // Drop anywhere on the bar (not just on a chip) → reorder/open at the end.
        .dropDestination(for: URL.self) { items, _ in
            guard let url = items.first, let last = tabs.tabs.last else { return false }
            tabs.handleTabDrop(url, onto: last.id, after: true)
            return true
        } isTargeted: { tabBarDropTargeted = $0 }
    }

    /// Pick a PDF (anywhere on disk) and open it in a reader window.
    private func openPaperPDF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "讀 PDF"
        if panel.runModal() == .OK, let url = panel.url {
            openWindow(id: "pdf", value: url)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { editor.openPalette(.files) } label: {
                    Label(LZ("快速開啟"), systemImage: "magnifyingglass")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("快速開啟檔案 (⌘O)")

                Button { editor.openPalette(.content) } label: {
                    Label(LZ("搜尋"), systemImage: "text.magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("搜尋內容 (⇧⌘F)")

                Divider().frame(height: 18)

                Button { editor.toggleMdLatex(vault: vault) } label: {
                    Label(editor.docMode == .markdown ? LZ("轉 LaTeX") : LZ("回 Markdown"),
                          systemImage: editor.docMode == .markdown
                            ? "arrow.right.doc.on.clipboard" : "arrow.uturn.backward")
                }
                .help(editor.docMode == .markdown ? "轉成 LaTeX — ⌥⌘L" : "切回 Markdown — ⌥⌘L")

                Button { editor.checkLatex() } label: {
                    Label(LZ("檢查"), systemImage: "checkmark.seal")
                }
                .help("檢查 $ / $$ / \\begin 是否配對，並跳到第一個問題")

                Button { editor.exportPDF() } label: {
                    Label(LZ("匯出 PDF"), systemImage: "doc.richtext")
                }
                .disabled(editor.isExporting)
                .help("匯出 PDF (⌘E)")

                Spacer()

                Picker("", selection: Binding(
                    get: { editor.availableViewModes.contains(editor.viewMode) ? editor.viewMode : .split },
                    set: { editor.viewMode = $0 }
                )) {
                    ForEach(editor.availableViewModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if editor.docMode == .markdown {
                    Toggle(isOn: $editor.pdfPreviewOn) {
                        Image(systemName: editor.pdfPreviewOn ? "doc.text.fill" : "doc.text")
                    }
                    .toggleStyle(.button)
                    .help(LZ("即時 PDF 預覽 Live PDF preview"))
                    if let url = editor.currentURL {
                        Button { openWindow(id: "preview", value: url) } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help(LZ("即時預覽彈出視窗"))
                    }
                }

                Menu {
                    // ── 研究 Research ──
                    Section(LZ("研究")) {
                        Button { NotificationCenter.default.post(name: .noteproOpenLiterature, object: nil) } label: {
                            Label(LZ("找文獻 arXiv/ADS"), systemImage: "magnifyingglass.circle")
                        }
                        Button { NotificationCenter.default.post(name: .noteproOpenLibrary, object: nil) } label: {
                            Label(LZ("文獻庫"), systemImage: "books.vertical")
                        }
                        Button { openPaperPDF() } label: { Label(LZ("讀 PDF"), systemImage: "doc.viewfinder") }
                        Button { NotificationCenter.default.post(name: .noteproOpenTranscribe, object: nil) } label: {
                            Label(LZ("錄演講 / 轉文字"), systemImage: "waveform")
                        }
                    }
                    // ── AI ──
                    Section("AI") {
                        Button { editor.triggerSemantic() } label: { Label(LZ("問筆記"), systemImage: "brain") }
                        Button { NotificationCenter.default.post(name: .noteproOpenCowork, object: nil) } label: {
                            Label(LZ("與 Claude 共筆"), systemImage: "sparkles.rectangle.stack")
                        }
                    }
                    // ── 編輯 Edit ──
                    Section(LZ("編輯")) {
                        Button { NotificationCenter.default.post(name: .noteproOpenSearchReplace, object: nil) } label: {
                            Label(LZ("搜尋與取代（跨檔案）"), systemImage: "arrow.2.squarepath")
                        }
                        Button { NotificationCenter.default.post(name: .noteproOpenHistory, object: nil) } label: {
                            Label(LZ("版本歷史 History"), systemImage: "clock.arrow.circlepath")
                        }
                    }
                    // ── 視窗 Window ──
                    Section(LZ("視窗")) {
                        Button { tabs.splitOn.toggle() } label: {
                            Label(LZ("分割"), systemImage: "rectangle.split.2x1")
                        }
                        Button { openWindow(id: "main", value: UUID()) } label: {
                            Label(LZ("新視窗"), systemImage: "macwindow.badge.plus")
                        }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    }
                    Divider()
                    Button { NotificationCenter.default.post(name: .noteproOpenShortcuts, object: nil) } label: {
                        Label(LZ("快捷鍵 Shortcuts"), systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("更多 More")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
            tabBar
            Divider()

            if editor.currentURL != nil { InlineTitleBar() }
            if editor.docMode == .markdown { PropertyPanel() }

            // Editor on the left; compiled-PDF preview on the right (only
            // present in LaTeX or markdown+pdfPreviewOn).
            HSplitView {
                editorStack.frame(minWidth: 240)
                if editor.latexPreviewVisible {
                    pdfPanel.frame(minWidth: 240)
                }
            }
            backlinksBar
            Divider()
            statusBar
        }
    }

    /// The editor surface (every tab's WebView stays alive; only the active
    /// one is shown).
    private var editorStack: some View {
        ZStack {
            ForEach(tabs.tabs) { tab in
                WebView()
                    .environmentObject(tab)
                    .opacity(tab.id == tabs.activeID ? 1 : 0)
                    .allowsHitTesting(tab.id == tabs.activeID)
            }
        }
    }

    /// The compiled-PDF live preview pane (with compile-status overlays).
    private var pdfPanel: some View {
        PDFPreview(url: editor.previewPDF, version: editor.previewVersion,
                   syncTarget: editor.syncTarget,
                   onReverse: { p, x, y in editor.runSyncTeXReverse(page: p, x: x, y: y) })
            // Pop the compiled preview out into its own window (drag to another
            // screen). Reuses the PDF reader window on the live preview file.
            .overlay(alignment: .topLeading) {
                if let pdf = editor.previewPDF {
                    Button { openWindow(id: "pdf", value: pdf) } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("預覽彈出到新視窗")
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if editor.isCompilingPreview || editor.aiFixing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(editor.aiFixing ? "AI 修復中" : "編譯中")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                } else if !editor.lastCompileError.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button { editor.aiFixLatex() } label: {
                            Label("AI 修復", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        if !editor.errorHint.isEmpty {
                            Button { editor.scrollToErrorLine() } label: {
                                Label(editor.errorLine.map { "第 \($0) 行：\(editor.errorHint)" } ?? editor.errorHint,
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).lineLimit(2)
                            }
                            .buttonStyle(.plain).foregroundStyle(.orange)
                            .frame(maxWidth: 260, alignment: .trailing)
                            .disabled(editor.errorLine == nil)
                        }
                    }
                    .padding(8)
                } else if editor.previewPDF == nil {
                    Text("尚未編譯")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
            }
    }

    /// Bottom status bar: message on the left; word count / mode / busy on the right.
    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(editor.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if editor.isExporting || editor.isCompilingPreview || editor.aiFixing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(editor.aiFixing ? "AI" : LZ("編譯中")).font(.caption2).foregroundStyle(.secondary)
            }
            if editor.wordCount > 0 {
                Text("\(editor.wordCount) \(LZ("字"))").font(.caption2).foregroundStyle(.secondary)
            }
            Text(editor.docMode == .latex ? "LaTeX" : "Markdown")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(.bar)
    }

    @ViewBuilder
    private var backlinksBar: some View {
        let links = index.backlinks(for: editor.currentURL)
        if !links.isEmpty {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                Text("反向連結 \(links.count)").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(links) { e in
                            Button(e.url.deletingPathExtension().lastPathComponent) { tabs.open(e.url) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }
}

/// A single tab chip in the tab bar.
struct TabChip: View {
    @EnvironmentObject var tabs: TabsModel
    @ObservedObject var tab: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        let active = tabs.activeID == tab.id
        let chip = HStack(spacing: 6) {
            if tab.isDirty {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .help("未儲存變更")
            }
            Text(tab.displayName)
                .font(.caption)
                .lineLimit(1)
            if tabs.tabs.count > 1 {
                Button { tabs.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            active ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        // Blue edge while a dragged tab/file hovers over this slot.
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { tabs.activate(tab.id) }
        // Drop a dragged tab (or sidebar file) here → reorder / open at this slot.
        .dropDestination(for: URL.self) { items, _ in
            guard let url = items.first else { return false }
            tabs.handleTabDrop(url, onto: tab.id)
            return true
        } isTargeted: { dropTargeted = $0 }

        // A saved tab can be dragged — within the bar to reorder, or into the
        // split pane to open there.
        if let url = tab.currentURL {
            chip.draggable(url)
        } else {
            chip
        }
    }
}

/// The right-hand split pane: a companion editor. Drag a file from the sidebar
/// onto it to open it here (side-by-side with the left editor).
struct SecondaryPane: View {
    @EnvironmentObject var editor: EditorModel   // tabs.secondary
    @EnvironmentObject var tabs: TabsModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.caption).foregroundStyle(.secondary)
                Text(editor.currentURL == nil ? "拖分頁或檔案到此並排" : editor.displayName)
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(editor.currentURL == nil ? .secondary : .primary)
                Spacer()
                Button { editor.save() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("儲存")
                Button { editor.exportPDF() } label: { Image(systemName: "doc.richtext") }
                    .buttonStyle(.borderless).help("匯出 PDF").disabled(editor.isExporting)
                Button { tabs.splitVertical.toggle() } label: {
                    Image(systemName: tabs.splitVertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
                }
                .buttonStyle(.borderless).help(tabs.splitVertical ? "改為左右分割" : "改為上下分割")
                Button { tabs.splitOn = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("關閉分割")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            WebView()   // env editor == tabs.secondary
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first { editor.open(u) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// Obsidian-style inline title: the file name shown as an editable heading at
/// the top of the note. Committing renames the file (keeping its extension).
struct InlineTitleBar: View {
    @EnvironmentObject var editor: EditorModel
    @State private var title = ""
    @FocusState private var focused: Bool

    private var base: String { editor.currentURL?.deletingPathExtension().lastPathComponent ?? "" }

    var body: some View {
        TextField(LZ("未命名"), text: $title)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onAppear { title = base }
            .onChange(of: editor.currentURL) { _, _ in title = base }
            .onChange(of: editor.displayName) { _, _ in if !focused { title = base } }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private func commit() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == base { title = base } else { editor.renameCurrent(to: t) }
    }
}

/// Notion-style "Properties" panel: edits the note's YAML frontmatter as a form.
/// Collapsible; shown above the editor for Markdown notes.
struct PropertyPanel: View {
    @EnvironmentObject var editor: EditorModel
    @AppStorage("showProperties") private var show = true
    @State private var newKey = ""

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { show.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: show ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                    Text(LZ("屬性 Properties")).font(.caption.weight(.medium))
                    if !editor.properties.isEmpty {
                        Text("\(editor.properties.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 5)

            if show {
                VStack(spacing: 4) {
                    ForEach(editor.properties) { field in
                        PropertyRow(field: field)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.caption2).foregroundStyle(.secondary)
                        TextField(LZ("新增屬性…"), text: $newKey)
                            .textFieldStyle(.plain).font(.caption)
                            .onSubmit(addNew)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
        }
        .background(.bar)
    }

    private func addNew() {
        let k = newKey.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        editor.setProperty(k, "")
        newKey = ""
    }
}

/// One editable frontmatter row. Commits on Enter or when focus leaves (not on
/// every keystroke, to avoid rewriting the document mid-type).
private struct PropertyRow: View {
    @EnvironmentObject var editor: EditorModel
    let field: EditorModel.PropertyField
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(field.key)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading).lineLimit(1)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder).font(.caption)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            Button { editor.removeProperty(field.key) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("移除此屬性")
        }
        .onAppear { text = field.value }
        .onChange(of: field.value) { _, v in if !focused { text = v } }
    }

    private func commit() {
        if text != field.value { editor.setProperty(field.key, text) }
    }
}

/// Keyboard-shortcut cheat sheet (⌘/). A simple grouped reference.
struct ShortcutsView: View {
    let onClose: () -> Void

    private let groups: [(String, [(String, String)])] = [
        ("檔案 File", [
            ("⌘N", "新文件 New note"), ("⇧⌘N", "新資料夾 New folder"),
            ("⌥⌘T", "今天的筆記 Daily note"), ("⇧⌘P", "新專案 New project"),
            ("⇧⌘O", "開啟資料夾 Open vault"), ("⌘S", "儲存 Save"),
        ]),
        ("搜尋 Search", [
            ("⌘O", "快速開啟 Quick open"), ("⇧⌘F", "全文搜尋 Search content"),
            ("⌘F", "文件內尋找 Find in document"), ("⌥⌘F", "語意搜尋 / 問筆記 Ask notes"),
            ("⋯ ▸ 搜尋與取代", "跨檔案取代（regex 可用）"),
        ]),
        ("檢視 View", [
            ("⌘1 / ⌘2 / ⌘3", "編輯 / 並排 / 預覽"), ("⌘\\", "分割視窗 Split"),
            ("⌘T", "新分頁 New tab"), ("⌥⌘N", "新視窗 New window"),
            ("⇧⌘] / ⇧⌘[", "下一個 / 上一個分頁"), ("⌃1…⌃9", "跳到第 N 個分頁"),
            ("⇧⌘D", "資料庫 Database"), ("⇧⌘G", "關係圖譜 Graph"),
        ]),
        ("LaTeX / 寫作", [
            ("⌥⌘L", "轉 / 切換 LaTeX ⇄ Markdown"), ("⌘E", "匯出 PDF Export PDF"),
            ("⇧⌘L", "匯出 .tex"), ("⇧⌘H", "版本歷史 History"),
            ("插入 ▸ 表格", "表格：插列 / 插欄 / 對齊 / 格式化"),
        ]),
        ("AI / 引用", [
            ("⌘K", "AI 協助 / 續寫"), ("⌥⌘K", "AI 修復 LaTeX"),
            ("⌘⇧K", "插入引用 Zotero"), ("⌥⇧⌘K", "在 Zotero 開啟游標引用"),
        ]),
        ("預覽 Preview", [
            ("雙擊預覽段落", "跳到原始行"), ("⤢（預覽右上）", "拖出 / 彈出即時預覽"),
            ("雙擊 PDF 預覽", "SyncTeX 跳回編輯器該行"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                Text(LZ("快捷鍵 Shortcuts")).font(.headline)
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.0).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.1, id: \.0) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.0)
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                        .frame(width: 96, alignment: .leading)
                                    Text(row.1).font(.caption)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 440)
        .onExitCommand(perform: onClose)
    }
}

/// Record a talk (or import an audio file) → local Whisper transcription →
/// optional local-AI summary → saved as a note. Fully offline.
struct TranscribeView: View {
    @EnvironmentObject var vault: VaultModel
    @StateObject private var rec = MeetingRecorder()
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    private func writeNote(_ title: String, _ content: String) -> URL? {
        vault.newFile(baseName: title, ext: "md", content: content)
    }
    private func timeStr(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text(LZ("錄演講 / 轉文字")).font(.headline)
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }

            if !TranscriptionService.isAvailable {
                Label("找不到 whisper-cli 或模型。請 `brew install whisper-cpp` 並在設定指定模型路徑。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            switch rec.phase {
            case .idle:
                VStack(spacing: 12) {
                    Toggle("用本地 AI 整理摘要", isOn: $rec.summarize)
                    Toggle("逐字稿含時間戳", isOn: $rec.timestamps)
                    HStack(spacing: 16) {
                        Button {
                            rec.startRecording()
                        } label: {
                            Label("開始錄音", systemImage: "record.circle").font(.title3)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(!TranscriptionService.isAvailable)

                        Button { importAudio() } label: {
                            Label("匯入音檔…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!TranscriptionService.isAvailable)
                    }
                }
            case .recording:
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(.red)
                    Text(timeStr(rec.elapsed)).font(.system(.title, design: .monospaced))
                    Button {
                        rec.stopAndProcess(write: writeNote, open: onOpen)
                    } label: {
                        Label("停止並轉錄", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .transcribing:
                VStack(spacing: 8) {
                    ProgressView(value: rec.transcribeProgress).frame(width: 240)
                    Text("轉錄中… \(Int(rec.transcribeProgress * 100))%（本地 Whisper）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .summarizing:
                VStack(spacing: 8) {
                    if rec.summaryTotal > 1 { ProgressView(value: Double(rec.summaryStep), total: Double(rec.summaryTotal)).frame(width: 240) }
                    else { ProgressView().controlSize(.large) }
                    Text(rec.summaryTotal > 1 ? "本地 AI 整理摘要中… (\(rec.summaryStep)/\(rec.summaryTotal))" : "本地 AI 整理摘要中…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .error(let msg):
                VStack(spacing: 10) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("回到開始") { rec.phase = .idle }
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 440, height: 320)
        .onExitCommand(perform: onClose)
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        panel.prompt = "轉錄"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rec.processFile(url, write: writeNote, open: onOpen)
    }
}

/// Search arXiv / NASA ADS → import a paper as a BibTeX entry (appended to the
/// vault's references.bib) + a literature note, and insert its citation.
struct LiteratureSearchView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var editor: EditorModel
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var source = "arxiv"
    @State private var query = ""
    @State private var results: [Paper] = []
    @State private var busy = false
    @State private var status = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $source) {
                    Text("arXiv").tag("arxiv")
                    Text("NASA ADS").tag("ads")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋論文（標題 / 作者 / 關鍵字）…", text: $query)
                        .textFieldStyle(.plain).font(.title3).focused($focused).onSubmit(run)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                VStack { Spacer()
                    Text(busy ? "搜尋中…" : "輸入關鍵字，按 Enter 搜尋。").foregroundStyle(.secondary)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { p in row(p) }.listStyle(.plain)
            }
            Divider()
            HStack {
                Text(status.isEmpty ? (vault.rootURL == nil ? "請先開啟資料夾" : "匯入會寫進 \(vault.rootURL?.lastPathComponent ?? "")/references.bib + 建文獻筆記") : status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 680, height: 540)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
    }

    private func row(_ p: Paper) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.title).font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text(p.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !p.year.isEmpty { Text("· \(p.year)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { importPaper(p) } label: { Label("匯入並引用", systemImage: "square.and.arrow.down") }
                    .controlSize(.small).disabled(vault.rootURL == nil)
            }
            if !p.abstract.isEmpty {
                Text(p.abstract).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true; status = ""
        if source == "arxiv" {
            LiteratureSearch.arxiv(q) { r in results = r; busy = false; if r.isEmpty { status = "沒有結果" } }
        } else {
            LiteratureSearch.ads(q) { result in
                busy = false
                switch result {
                case .success(let r): results = r; if r.isEmpty { status = "沒有結果" }
                case .failure(let e): status = "⚠ \(e.localizedDescription)"
                }
            }
        }
    }

    private func importPaper(_ p: Paper) {
        guard vault.rootURL != nil else { status = "請先開啟資料夾"; return }
        if p.source == "ADS" {
            LiteratureSearch.adsBibtex(p.identifier) { bib in
                finish(p, bibtex: bib ?? LiteratureSearch.arxivBibtex(p, key: LiteratureSearch.citekey(for: p)))
            }
        } else {
            finish(p, bibtex: LiteratureSearch.arxivBibtex(p, key: LiteratureSearch.citekey(for: p)))
        }
    }

    private func finish(_ p: Paper, bibtex: String) {
        guard let root = vault.rootURL else { return }
        let key = bibKey(bibtex) ?? LiteratureSearch.citekey(for: p)
        // 1. Append to <vault>/references.bib (dedup by key).
        let bibURL = root.appendingPathComponent("references.bib")
        let existing = (try? String(contentsOf: bibURL, encoding: .utf8)) ?? ""
        if !existing.contains("{\(key),") && !existing.contains("{\(key) ,") {
            let merged = existing.isEmpty ? bibtex : existing + "\n" + bibtex
            try? merged.write(to: bibURL, atomically: true, encoding: .utf8)
        }
        // 2. Literature note.
        let body = """
        ---
        type: literature-note
        title: \(p.title)
        authors: \(p.authorLine)
        year: \(p.year)
        cite: \(key)
        source: \(p.source)
        url: \(p.url)
        doi: \(p.doi)
        ---

        # \(p.title)

        \(p.authorLine) (\(p.year)) · [\(p.source)](\(p.url)) · `[@\(key)]`

        ## 摘要

        \(p.abstract)

        ## 筆記


        """
        let safeTitle = String(p.title.prefix(50)).replacingOccurrences(of: "/", with: "-")
        let url = vault.newFile(baseName: "文獻 - \(safeTitle)", ext: "md", content: body)
        // 3. Insert the citation into the active editor.
        editor.insertCitation(key)
        status = "已匯入 [@\(key)] — references.bib + 文獻筆記"
        if let url { onOpen(url) }
    }

    private func bibKey(_ bib: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"@\w+\s*\{\s*([^,\s]+)"#) else { return nil }
        let ns = bib as NSString
        guard let m = re.firstMatch(in: bib, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

/// Cowork with Claude — pick a scope (selection / heading-bounded section /
/// whole note), a preset task, write/edit the prompt, then "Copy & Open
/// claude.ai". Goes via the user's claude.ai subscription — no API key.
struct CoworkView: View {
    @EnvironmentObject var editor: EditorModel
    let onClose: () -> Void
    @State private var scope = "selection"
    @State private var preset = "improve"
    @State private var instruction = ""
    @State private var payload = ""
    @State private var status = ""

    private struct Preset { let id, label, prompt: String }
    private let presets: [Preset] = [
        .init(id: "improve",  label: "改寫得更清楚精煉",
              prompt: "請把下面這段學術寫作改得更清楚精煉(保留術語、數學、引用),用條列點出主要修改原因。\n\n"),
        .init(id: "review",   label: "審稿/找邏輯漏洞",
              prompt: "請以期刊審稿人角度評論下面這段,找邏輯漏洞、過度推論、缺少證據之處,並列改進建議。\n\n"),
        .init(id: "explain",  label: "解釋這個推導/方程式",
              prompt: "請詳細解釋下面這段 LaTeX 公式或推導:每一步在做什麼、用了什麼假設、結果的物理意義。\n\n"),
        .init(id: "summary",  label: "摘要(中文)",
              prompt: "請用 3~5 句中文摘要下面這段,保留關鍵數字與結論。\n\n"),
        .init(id: "translate",label: "翻成英文(學術)",
              prompt: "請把下面這段翻成適合天文期刊的英文(自然、簡練、保留術語):\n\n"),
        .init(id: "outline",  label: "從這段擴寫成段落大綱",
              prompt: "請把下面這個粗胚擴寫成一段論文段落的大綱(每點一句、保留邏輯順序):\n\n"),
        .init(id: "freeform", label: "自訂(下面自己寫)", prompt: ""),
    ]

    private var fullPrompt: String {
        let head = preset == "freeform"
            ? instruction
            : (presets.first { $0.id == preset }?.prompt ?? "") + instruction
        return head + "---\n" + payload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LZ("與 Claude 共筆")).font(.headline)
                Spacer()
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }

            HStack(spacing: 16) {
                Picker(LZ("範圍"), selection: $scope) {
                    Text(LZ("選取")).tag("selection")
                    Text(LZ("本章節")).tag("section")
                    Text(LZ("整篇")).tag("full")
                }.pickerStyle(.segmented).labelsHidden().onChange(of: scope) { _, _ in refresh() }

                Picker("", selection: $preset) {
                    ForEach(presets, id: \.id) { p in Text(LZ(p.label)).tag(p.id) }
                }.labelsHidden().frame(width: 240)
            }

            if preset == "freeform" {
                Text(LZ("自訂指令")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $instruction).frame(minHeight: 60)
                    .font(.system(size: 13)).border(Color.secondary.opacity(0.3))
            } else {
                Text(LZ("附加說明(可空)")).font(.caption).foregroundStyle(.secondary)
                TextField("", text: $instruction).textFieldStyle(.roundedBorder)
            }

            Text(LZ("內容") + "  ·  \(payload.count) " + LZ("字元"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(payload.isEmpty ? "(空 — 換個範圍或先選取文字)" : payload)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.gray.opacity(0.08))
            .frame(maxHeight: 200)

            HStack {
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button(LZ("只複製到剪貼簿")) { copyOnly() }
                Button(LZ("複製 + 開 claude.ai")) { copyAndOpen() }
                    .keyboardShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(payload.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 620, height: 540)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        editor.getCoworkPayload(scope: scope) { p in payload = p }
    }
    private func copyOnly() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPrompt, forType: .string)
        status = LZ("已複製到剪貼簿")
    }
    private func copyAndOpen() {
        copyOnly()
        if let url = URL(string: "https://claude.ai/new") { NSWorkspace.shared.open(url) }
        status = LZ("已複製 — 到 claude.ai 按 ⌘V 貼上")
    }
}

/// A standalone single-note window (drag/right-click ▸ 在新視窗開啟). Lightweight:
/// just an editor + view-mode picker + save, no sidebar/tabs. Good for editing
/// or displaying a second note on another screen.
struct NoteWindowView: View {
    let url: URL
    @EnvironmentObject var vault: VaultModel
    @StateObject private var editor = EditorModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(editor.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Picker("", selection: $editor.viewMode) {
                    ForEach(editor.availableViewModes, id: \.self) { m in Text(LZ(m.label)).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { editor.save() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("儲存 (⌘S)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            WebView().environmentObject(editor)
        }
        .onAppear {
            editor.vaultRoot = vault.rootURL
            editor.open(url)
        }
        .navigationTitle(editor.displayName)
        .focusedSceneValue(\.editorModel, editor)
    }
}

/// A pop-out LIVE preview window (right-side HTML preview detached). Read-only:
/// it opens the note in preview mode and live-updates as the source editor
/// broadcasts content (debounced) — drag it to another screen to watch the
/// rendered note while you type in the main window.
struct PreviewWindowView: View {
    let url: URL
    @EnvironmentObject var vault: VaultModel
    @StateObject private var editor = EditorModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye").font(.caption).foregroundStyle(.secondary)
                Text(editor.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text("即時預覽").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            WebView().environmentObject(editor)
        }
        .onAppear {
            editor.isMirror = true
            EditorModel.mirrorCount += 1
            editor.vaultRoot = vault.rootURL
            editor.open(url)
            editor.viewMode = .preview
        }
        .onDisappear { EditorModel.mirrorCount = max(0, EditorModel.mirrorCount - 1) }
        .onReceive(NotificationCenter.default.publisher(for: .noteproMirrorContent)) { note in
            guard let u = note.userInfo?["url"] as? URL, u == url,
                  let text = note.userInfo?["text"] as? String else { return }
            let src = note.userInfo?["sourceID"] as? String
            // Lock onto the first source that sends content for this file, so a
            // second editor showing the same file can't hijack the mirror.
            if editor.mirrorSourceID == nil { editor.mirrorSourceID = src }
            guard editor.mirrorSourceID == src else { return }
            editor.applyMirrorContent(text)
        }
        .navigationTitle("\(editor.displayName) — 預覽")
    }
}

/// Literature library — every literature note in the vault (frontmatter
/// `type: literature-note`, i.e. PDF annotations + arXiv/ADS imports) in one
/// searchable, sortable list with read/unread tracking.
struct LiteratureLibraryView: View {
    @EnvironmentObject var index: IndexService
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var sortBy = "year"
    @AppStorage("litReadPaths") private var readPathsData = Data()

    private var readPaths: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: readPathsData)) ?? []
    }
    private func setRead(_ url: URL, _ read: Bool) {
        var s = readPaths
        if read { s.insert(url.path) } else { s.remove(url.path) }
        readPathsData = (try? JSONEncoder().encode(s)) ?? Data()
    }

    private var items: [IndexEntry] {
        var list = index.entries.filter { $0.properties["type"] == "literature-note" }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q)
                || ($0.properties["authors"] ?? "").lowercased().contains(q)
                || ($0.properties["cite"] ?? "").lowercased().contains(q)
                || $0.content.lowercased().contains(q)
            }
        }
        switch sortBy {
        case "author": return list.sorted { ($0.properties["authors"] ?? "") < ($1.properties["authors"] ?? "") }
        case "title": return list.sorted { $0.title < $1.title }
        default: return list.sorted { ($0.properties["year"] ?? "") > ($1.properties["year"] ?? "") }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical").foregroundStyle(.secondary)
                TextField(LZ("搜尋標題 / 作者 / citekey…"), text: $query)
                    .textFieldStyle(.plain).font(.title3)
                Picker("", selection: $sortBy) {
                    Text(LZ("年份")).tag("year")
                    Text(LZ("作者")).tag("author")
                    Text(LZ("標題")).tag("title")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(LZ("還沒有文獻筆記")).foregroundStyle(.secondary)
                    Text(LZ("用「找文獻 arXiv/ADS」匯入，或在 PDF 閱讀器按「建立文獻筆記」。"))
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { e in row(e) }.listStyle(.plain)
            }
            Divider()
            HStack {
                Text("\(items.count) \(LZ("篇"))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 680, height: 520)
    }

    private func row(_ e: IndexEntry) -> some View {
        let isRead = readPaths.contains(e.url.path)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                setRead(e.url, !isRead)
            } label: {
                Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isRead ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain).help(isRead ? "標為未讀" : "標為已讀")
            VStack(alignment: .leading, spacing: 3) {
                Text(e.properties["title"] ?? e.title)
                    .font(.callout.weight(isRead ? .regular : .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(e.properties["authors"] ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let y = e.properties["year"], !y.isEmpty {
                        Text("· \(y)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = e.properties["source"], !s.isEmpty {
                        Text(s).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button { onOpen(e.url) } label: { Image(systemName: "doc.text") }
                    .buttonStyle(.borderless).help("開啟筆記")
                if let cite = e.properties["cite"], !cite.isEmpty {
                    Button { EditorModel.openInZotero(citekey: cite) } label: { Image(systemName: "books.vertical.circle") }
                        .buttonStyle(.borderless).help("在 Zotero 開啟")
                }
                if let urlStr = e.properties["url"], let u = URL(string: urlStr) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless).help("開啟連結")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(e.url) }
    }
}

/// Vault-wide search & replace: plain or regex, per-match preview with
/// highlighted context, per-file selection, HistoryStore snapshot before every
/// write so anything is restorable from 版本歷史.
struct SearchReplaceView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var index: IndexService
    let onOpen: (URL) -> Void
    let onReplaced: ([URL]) -> Void
    let onClose: () -> Void

    struct Match: Identifiable {
        let id = UUID()
        let url: URL
        let ordinal: Int   // index of this match within its file (for precise replace)
        let line: Int
        let prefix: String
        let hit: String
        let suffix: String
        var included = true
    }

    @State private var query = ""
    @State private var replacement = ""
    @State private var useRegex = false
    @State private var caseSensitive = false
    @State private var matches: [Match] = []
    @State private var status = ""
    @State private var searched = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(LZ("搜尋整個資料夾…"), text: $query)
                        .textFieldStyle(.plain).font(.title3).onSubmit(runSearch)
                    Toggle(".*", isOn: $useRegex).toggleStyle(.button).help("正則表達式")
                    Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button).help("區分大小寫")
                    Button(LZ("搜尋"), action: runSearch).keyboardShortcut(.return)
                }
                HStack {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                    TextField(LZ("取代為…（regex 可用 $1）"), text: $replacement)
                        .textFieldStyle(.plain)
                }
            }
            .padding(12)
            Divider()
            if matches.isEmpty {
                VStack { Spacer()
                    Text(searched ? LZ("沒有符合的結果") : LZ("輸入關鍵字，按 Enter 搜尋。"))
                        .foregroundStyle(.secondary)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List($matches) { $m in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $m.included).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.url.lastPathComponent):\(m.line)")
                                .font(.caption2).foregroundStyle(.secondary)
                            (Text(m.prefix) + Text(m.hit).bold().foregroundColor(.orange) + Text(m.suffix))
                                .font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        }
                        Spacer()
                        Button { onOpen(m.url) } label: { Image(systemName: "arrow.up.right") }
                            .buttonStyle(.borderless).help("開啟檔案")
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Text(status.isEmpty ? "\(matches.count) \(LZ("個符合")) · \(LZ("取代前會自動存版本快照"))" : status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(LZ("取代勾選的")) { replaceSelected() }
                    .disabled(matches.allSatisfy { !$0.included } || query.isEmpty)
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 720, height: 540)
    }

    private func makeRegex() -> NSRegularExpression? {
        let pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        var opts: NSRegularExpression.Options = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    private func runSearch() {
        matches = []; status = ""; searched = true
        guard !query.isEmpty, let re = makeRegex() else {
            status = LZ("正則表達式無效"); return
        }
        var out: [Match] = []
        for entry in index.entries where entry.ext == "md" || entry.ext == "tex" {
            let ns = entry.content as NSString
            for (ordinal, m) in re.matches(in: entry.content, range: NSRange(location: 0, length: ns.length)).enumerated() {
                let lineStart = ns.substring(to: m.range.location).components(separatedBy: "\n")
                let line = lineStart.count
                let ctxFrom = max(0, m.range.location - 40)
                let ctxTo = min(ns.length, m.range.location + m.range.length + 40)
                out.append(Match(
                    url: entry.url,
                    ordinal: ordinal,
                    line: line,
                    prefix: ns.substring(with: NSRange(location: ctxFrom, length: m.range.location - ctxFrom))
                        .replacingOccurrences(of: "\n", with: " "),
                    hit: ns.substring(with: m.range),
                    suffix: ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                                       length: ctxTo - m.range.location - m.range.length))
                        .replacingOccurrences(of: "\n", with: " ")
                ))
                if out.count >= 500 { break }
            }
            if out.count >= 500 { status = LZ("結果太多，只顯示前 500 筆"); break }
        }
        matches = out
    }

    private func replaceSelected() {
        guard let re = makeRegex() else { return }
        // Group included matches by file; replace ONLY the checked ones, working
        // from the end of the file backwards so earlier ranges stay valid.
        let byFile = Dictionary(grouping: matches.filter(\.included), by: \.url)
        var changed: [URL] = []
        let template = useRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        for (url, ms) in byFile {
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Snapshot BEFORE the change so 版本歷史 can restore it.
            HistoryStore.snapshot(root: vault.rootURL, file: url, content: original)
            let included = Set(ms.map(\.ordinal))
            let all = re.matches(in: original, range: NSRange(location: 0, length: (original as NSString).length))
            var result = original
            for (i, m) in all.enumerated().reversed() where included.contains(i) {
                let rep = re.replacementString(for: m, in: original, offset: 0, template: template)
                result = (result as NSString).replacingCharacters(in: m.range, with: rep)
            }
            if result != original {
                try? result.write(to: url, atomically: true, encoding: .utf8)
                changed.append(url)
            }
        }
        status = "\(LZ("已取代")) \(byFile.count) \(LZ("個檔案"))（\(LZ("可從版本歷史還原")))"
        onReplaced(changed)
        runSearch()   // refresh the list against the new contents
    }
}
