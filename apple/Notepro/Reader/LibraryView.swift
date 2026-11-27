import SwiftUI
import AppKit

extension FileEntry: Identifiable { var id: String { name } }

/// The reader's library tab (PAPER-LIBRARY.md §6.4), like Zotero's: sources
/// on the left (all papers, unread, projects, tags, other files), the papers
/// in a sortable table, and the selected paper's details on the right.
/// Double-click or Return opens a paper in a reader tab. Read-only for now.
struct LibraryView: View {
    @ObservedObject var index: LibraryIndex
    @ObservedObject var session: ReaderSession
    @ObservedObject var ctrl: ReaderController

    @AppStorage("libraryTagsExpanded") private var tagsExpanded = true
    @FocusState private var searchFocused: Bool

    private var current: LibrarySource { ctrl.librarySource ?? .all }

    private var rows: [LibraryEntry] {
        let s = current
        return LibraryIndex.search(index.entries.filter { LibraryIndex.matches($0, s) }, ctrl.libraryQuery).sorted(using: ctrl.librarySort)
    }

    private var fileRows: [FileEntry] {
        let words = ctrl.libraryQuery.lowercased().split(whereSeparator: \.isWhitespace)
        return index.files.filter { f in
            let hay = "\(f.name) \(f.collections.joined(separator: " "))".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        HSplitView {
            sources.frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
            VStack(spacing: 0) {
                header
                Divider()
                if current == .files { filesTable } else { papersTable }
            }
            .frame(minWidth: 420)
            info.frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
        }
        .onAppear { index.loadIfNeeded(); focusSearchSoon() }
        .onChange(of: ctrl.focusLibrarySearch) { _, _ in focusSearchSoon() }
    }

    private func focusSearchSoon() { DispatchQueue.main.async { searchFocused = true } }

    // MARK: left column

    private var sources: some View {
        List(selection: $ctrl.librarySource) {
            Section {
                row(LZ("所有論文"), "books.vertical", .all)
                row(LZ("未讀"), "book.closed", .unread)
                row(LZ("最近打開"), "clock", .recent)
                row(LZ("沒有 PDF 的論文"), "doc", .noPDF)
                row(LZ("其他檔案"), "folder", .files)
            }
            let tree = index.projectTree
            if !tree.isEmpty {
                Section(LZ("專案")) {
                    OutlineGroup(tree, children: \.children) { n in
                        row(n.name, "folder.badge.person.crop", .project(n.path))
                    }
                }
            }
            let tags = index.tagCounts
            if !tags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(tags, id: \.tag) { t in
                        HStack {
                            Label(t.tag, systemImage: "tag").lineLimit(1)
                            Spacer()
                            Text("\(t.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(LibrarySource.tag(t.tag))
                    }
                } header: { Text(LZ("標籤")) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ icon: String, _ s: LibrarySource) -> some View {
        HStack {
            Label(title, systemImage: icon).lineLimit(1)
            Spacer()
            Text("\(index.count(s))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(s)
    }

    // MARK: middle

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(LZ("搜尋論文庫：作者、標題、年份、citekey、標籤"), text: $ctrl.libraryQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(openFromSearch)
                if !ctrl.libraryQuery.isEmpty {
                    Button { ctrl.libraryQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text(current == .files ? "\(fileRows.count)" : "\(rows.count) \(LZ("篇論文"))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if index.loading { ProgressView().controlSize(.small) }
            Button { index.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(LZ("重新讀取論文庫"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// Return in the search field opens the selected paper, else the first one shown.
    private func openFromSearch() {
        if current == .files {
            if let f = fileRows.first(where: { ctrl.libraryFileSelection.contains($0.id) }) ?? fileRows.first { openFile(f) }
            return
        }
        let shown = rows
        if let e = shown.first(where: { ctrl.librarySelection.contains($0.id) }) ?? shown.first { open([e.id]) }
    }

    private var papersTable: some View {
        Group {
            if !index.loadedOnce && index.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $ctrl.librarySelection, sortOrder: $ctrl.librarySort) {
                    TableColumn("") { (e: LibraryEntry) in
                        Image(systemName: e.hasPDF ? "doc.richtext" : "doc")
                            .foregroundStyle(e.hasPDF ? Color.secondary : Color.secondary.opacity(0.4))
                    }
                    .width(18)
                    TableColumn(LZ("標題"), value: \LibraryEntry.title) { e in
                        Text(e.title).lineLimit(1)
                            .fontWeight(e.unread ? .semibold : .regular)
                            .foregroundStyle(e.hasPDF ? Color.primary : Color.secondary)
                    }
                    .width(min: 140, ideal: 260)
                    TableColumn(LZ("作者"), value: \LibraryEntry.creators) { e in Text(e.creators).lineLimit(1) }
                        .width(min: 60, ideal: 100)
                    TableColumn(LZ("年份"), value: \LibraryEntry.year) { e in Text(e.year).monospacedDigit() }
                        .width(min: 36, ideal: 44)
                    TableColumn(LZ("期刊"), value: \LibraryEntry.publication) { e in Text(e.publication).lineLimit(1) }
                        .width(min: 60, ideal: 120)
                    TableColumn(LZ("加入日期"), value: \LibraryEntry.added) { e in
                        Text(String(e.added.prefix(10))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 82)
                    TableColumn(LZ("上次打開"), value: \LibraryEntry.lastOpened) { e in
                        Text(String(e.lastOpened.prefix(10))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 82)
                    TableColumn(LZ("標記數"), value: \LibraryEntry.annotationCount) { e in
                        Text(e.annotationCount > 0 ? "\(e.annotationCount)" : "").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 30, ideal: 40)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    contextMenu(ids)
                } primaryAction: { ids in open(ids) }
                .overlay {
                    if index.loadedOnce && rows.isEmpty {
                        Text(index.entries.isEmpty ? LZ("論文庫是空的") : LZ("沒有符合的論文")).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let es = index.entries.filter { ids.contains($0.id) }
        if !es.isEmpty {
            Button(es.count == 1 ? LZ("打開") : "\(LZ("打開")) (\(es.filter(\.hasPDF).count))") { open(ids) }
                .disabled(!es.contains(where: \.hasPDF))
            if es.count == 1, let e = es.first, let url = webURL(e.meta) {
                Button(LZ("打開網頁")) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button(LZ("複製 citekey")) { copy(es.map(\.meta.citekey).joined(separator: ", ")) }
            Button(LZ("複製引用 [@…]")) { copy("[" + es.map { "@\($0.meta.citekey)" }.joined(separator: "; ") + "]") }
            Divider()
            Button(LZ("在 Finder 顯示")) {
                NSWorkspace.shared.activateFileViewerSelecting(es.map { index.store.folder($0.folder) })
            }
        }
    }

    private var filesTable: some View {
        Table(fileRows, selection: $ctrl.libraryFileSelection) {
            TableColumn(LZ("檔名")) { (f: FileEntry) in Text((f.name as NSString).lastPathComponent).lineLimit(1) }
                .width(min: 160, ideal: 320)
            TableColumn(LZ("所屬集合")) { (f: FileEntry) in
                Text(f.collections.joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
            }
            TableColumn(LZ("可能是論文")) { (f: FileEntry) in
                Text(f.paperCandidate ?? "").lineLimit(1).foregroundStyle(.secondary).monospaced()
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(LZ("打開")) { for f in index.files where ids.contains(f.id) { openFile(f) } }
            Button(LZ("在 Finder 顯示")) {
                NSWorkspace.shared.activateFileViewerSelecting(index.files.filter { ids.contains($0.id) }.map(fileURL))
            }
        } primaryAction: { ids in for f in index.files where ids.contains(f.id) { openFile(f) } }
    }

    // MARK: right column

    private var info: some View {
        Group {
            if current == .files {
                fileInfo
            } else {
                let picked = index.entries.filter { ctrl.librarySelection.contains($0.id) }
                if picked.count == 1, let e = picked.first {
                    LibraryInfoPane(entry: e, store: index.store,
                                    open: { open([e.id]) },
                                    selectTag: { t in ctrl.librarySource = .tag(t) },
                                    selectProject: { p in ctrl.librarySource = .project(p) })
                        .id(e.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "books.vertical").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(picked.isEmpty ? LZ("選一篇論文看資訊；按兩下打開") : "\(picked.count) \(LZ("篇論文"))")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if picked.count > 1 {
                            Button("\(LZ("打開")) (\(picked.filter(\.hasPDF).count))") { open(ctrl.librarySelection) }
                                .disabled(!picked.contains(where: \.hasPDF))
                        }
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var fileInfo: some View {
        VStack(spacing: 10) {
            Text(LZ("不是論文的檔案（從 Zotero 匯入）。「可能是論文」的會在之後查 ADS 變成論文。"))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    /// Opens every selected paper that has a PDF; a single paper without one
    /// opens its web page instead (Nebula never downloads on its own).
    private func open(_ ids: Set<String>) {
        let es = rows.filter { ids.contains($0.id) }
        let withPDF = es.filter(\.hasPDF)
        if withPDF.isEmpty {
            if es.count == 1, let url = webURL(es[0].meta) { NSWorkspace.shared.open(url) }
            return
        }
        for e in withPDF { session.openFolder(e.folder) }
    }

    private func fileURL(_ f: FileEntry) -> URL { index.store.filesDir.appendingPathComponent(f.name) }

    private func openFile(_ f: FileEntry) {
        let url = fileURL(f)
        if url.pathExtension.lowercased() == "pdf" { session.open(url) } else { NSWorkspace.shared.open(url) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// The paper's web page: its DOI, else arXiv, else ADS, else its URL.
func webURL(_ m: PaperMeta) -> URL? {
    if let d = m.ids.doi, !d.isEmpty, !d.lowercased().hasPrefix("10.48550/") { return URL(string: "https://doi.org/\(d)") }
    if let a = m.ids.arxiv, !a.isEmpty { return URL(string: "https://arxiv.org/abs/\(a)") }
    if let b = m.ids.bibcode, !b.isEmpty,
       let enc = b.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
        return URL(string: "https://ui.adsabs.harvard.edu/abs/\(enc)/abstract")
    }
    return m.bibliographic.fields["url"].flatMap { URL(string: $0) }
}

// MARK: - Info pane

struct LibraryInfoPane: View {
    let entry: LibraryEntry
    let store: PaperLibraryStore
    let open: () -> Void
    let selectTag: (String) -> Void
    let selectProject: (String) -> Void
    @State private var showAllCreators = false

    private var m: PaperMeta { entry.meta }
    private var f: [String: String] { m.bibliographic.fields }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Self.typeLabel(m.bibliographic.itemType)).font(.caption).foregroundStyle(.secondary)
                Text(entry.title).font(.headline).textSelection(.enabled)
                creators
                actions
                Divider()
                fields
                if !m.projects.isEmpty || !m.tags.isEmpty || !m.keywords.isEmpty { Divider(); organisation }
                Divider()
                activity
                if let abs = f["abstractNote"], !abs.isEmpty {
                    Divider()
                    Text(LZ("摘要")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(abs).font(.callout).textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var creators: some View {
        let cs = m.bibliographic.creators
        let shown = showAllCreators ? cs : Array(cs.prefix(6))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, c in
                Text([c.family, c.given].filter { !$0.isEmpty }.joined(separator: ", ")
                     + (c.role == "author" ? "" : " (\(c.role))"))
                    .font(.callout).textSelection(.enabled)
            }
            if cs.count > shown.count {
                Button("+\(cs.count - shown.count)") { showAllCreators = true }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if entry.hasPDF {
                Button(LZ("打開"), action: open).keyboardShortcut(.defaultAction)
            } else {
                Text(LZ("沒有 PDF")).font(.caption).foregroundStyle(.secondary)
            }
            if let url = webURL(m) {
                Button(LZ("打開網頁")) { NSWorkspace.shared.open(url) }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([store.folder(entry.folder)]) } label: {
                Image(systemName: "folder")
            }
            .help(LZ("在 Finder 顯示"))
        }
        .controlSize(.small)
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            field(LZ("期刊"), entry.publication)
            field(LZ("卷 / 期 / 頁"), [f["volume"], f["issue"], f["pages"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / "))
            field(LZ("日期"), f["date"].map(LibraryEntry.displayDate) ?? m.year)
            GridRow {
                Text("citekey").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                HStack(spacing: 4) {
                    Text(m.citekey).font(.callout.monospaced()).textSelection(.enabled)
                    Button { copy(m.citekey) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help(LZ("複製 citekey"))
                }
            }
            if !m.aliases.isEmpty { field(LZ("別名"), m.aliases.joined(separator: ", "), mono: true) }
            link("DOI", m.ids.doi, m.ids.doi.map { "https://doi.org/\($0)" })
            link("arXiv", m.ids.arxiv, m.ids.arxiv.map { "https://arxiv.org/abs/\($0)" })
            link("ADS", m.ids.bibcode, m.ids.bibcode.flatMap { b in
                b.addingPercentEncoding(withAllowedCharacters: .alphanumerics).map { "https://ui.adsabs.harvard.edu/abs/\($0)/abstract" }
            })
            if m.ids.doi == nil, m.ids.arxiv == nil, let u = f["url"], !u.isEmpty { link("URL", u, u) }
        }
    }

    @ViewBuilder private func field(_ k: String, _ v: String, mono: Bool = false) -> some View {
        if !v.isEmpty {
            GridRow {
                Text(k).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(v).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func link(_ k: String, _ v: String?, _ href: String?) -> some View {
        if let v, !v.isEmpty {
            GridRow {
                Text(k).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                if let href, let url = URL(string: href) {
                    Link(v, destination: url).font(.callout).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(v).font(.callout)
                }
            }
        }
    }

    private var organisation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !m.projects.isEmpty {
                chips(LZ("專案"), m.projects, icon: "folder", action: selectProject)
            }
            if !m.tags.isEmpty {
                chips(LZ("標籤"), m.tags, icon: "tag", action: selectTag)
            }
            if !m.keywords.isEmpty {
                Text(LZ("期刊關鍵字")).font(.caption).foregroundStyle(.secondary)
                Text(m.keywords.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func chips(_ title: String, _ items: [String], icon: String, action: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { t in
                Button { action(t) } label: { Label(t, systemImage: icon).font(.callout) }
                    .buttonStyle(.link)
            }
        }
    }

    private var activity: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            if m.status == "unread" { field(LZ("狀態"), LZ("未讀")) }
            field(LZ("加入日期"), String(m.added.prefix(10)))
            field(LZ("上次打開"), String((m.lastOpened ?? "").prefix(10)))
            if let p = m.lastPage, entry.hasPDF { field(LZ("讀到"), "p. \(p + 1)") }
            field(LZ("標記數"), entry.annotationCount > 0 ? "\(entry.annotationCount)" : "")
            if !entry.notes.isEmpty {
                GridRow {
                    Text(LZ("筆記")).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.notes, id: \.self) { n in
                            Button(n) {
                                NSWorkspace.shared.open(store.folder(entry.folder).appendingPathComponent("notes").appendingPathComponent(n))
                            }
                            .buttonStyle(.link).font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// journalArticle → "Journal Article".
    static func typeLabel(_ t: String) -> String {
        var out = ""
        for ch in t {
            if ch.isUppercase { out += " " }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
