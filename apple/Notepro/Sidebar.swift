import SwiftUI
import AppKit
import UniformTypeIdentifiers



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
