import SwiftUI
import PDFKit
import AppKit

/// The paper reader (PAPER-LIBRARY.md §6): one window, Nebula's own tab bar,
/// a sidebar (thumbnails / outline / annotations) and one PDFView that shows
/// the active tab. Library papers keep annotations in annotations.json.
struct ReaderWindowView: View {
    @EnvironmentObject var vault: VaultModel
    @ObservedObject private var session = ReaderSession.shared
    @StateObject private var ctrl = ReaderController()

    var body: some View {
        VStack(spacing: 0) {
            ReaderTabBar(session: session, ctrl: ctrl)
            Divider()
            ReaderToolbar(ctrl: ctrl)
            Divider()
            if session.tabs.isEmpty {
                emptyState
            } else {
                HSplitView {
                    if ctrl.showSidebar {
                        ReaderSidebar(ctrl: ctrl)
                            .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                    }
                    ReaderPDFRep(ctrl: ctrl)
                        .frame(minWidth: 420, minHeight: 400)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(WindowAccessor { w in ctrl.installKeys(window: w) })
        .onAppear { ctrl.vault = vault; if session.requestQuickOpen { ctrl.showQuickOpen = true; session.requestQuickOpen = false } }
        .onChange(of: session.requestQuickOpen) { _, v in if v { ctrl.showQuickOpen = true; session.requestQuickOpen = false } }
        .onDisappear { ctrl.detachCurrent(); session.saveAll() }
        .sheet(isPresented: $ctrl.showQuickOpen) {
            ReaderQuickOpen(store: session.store) { folder in
                ctrl.showQuickOpen = false
                if let f = folder { session.openFolder(f) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(LZ("沒有開啟的論文")).foregroundStyle(.secondary)
            Button(LZ("打開論文…")) { ctrl.showQuickOpen = true }.keyboardShortcut("t", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab bar

struct ReaderTabBar: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var ctrl: ReaderController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(session.tabs) { t in
                    let active = t.id == session.activeID
                    HStack(spacing: 4) {
                        Text(t.title).lineLimit(1).font(.caption)
                            .foregroundStyle(active ? .primary : (session.isLive(t.id) ? .secondary : .tertiary))
                        Button { ctrl.detachCurrentIf(t.id); session.close(t.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help(LZ("關閉分頁"))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: 220)
                    .background(active ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { session.select(t.id) }
                    .help(session.isLive(t.id) ? t.url.path : "\(t.url.path)\n\(LZ("休眠中：點了才載入"))")
                }
                Button { ctrl.showQuickOpen = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).padding(.horizontal, 8)
                    .help(LZ("打開論文（⌘T）"))
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }
}

extension ReaderController {
    func detachCurrentIf(_ id: UUID) { if session.activeID == id { detachCurrent() } }
}

// MARK: - Toolbar

struct ReaderToolbar: View {
    @ObservedObject var ctrl: ReaderController
    @FocusState private var findFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { ctrl.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(LZ("側欄"))
            Divider().frame(height: 16)
            Button { ctrl.highlight() } label: {
                Label(LZ("螢光標記"), systemImage: "highlighter")
            }
            .help(LZ("標記選取的文字（⌘E）"))
            Menu {
                ForEach(ReaderAnnotations.palette, id: \.hex) { c in
                    Button { ctrl.highlightHex = c.hex } label: {
                        Text((ctrl.highlightHex == c.hex ? "✓ " : "   ") + LZ(c.name))
                    }
                }
            } label: {
                Circle().fill(Color(nsColor: NSColor(hex: ctrl.highlightHex) ?? .systemYellow)).frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton).frame(width: 34)
            .help(LZ("標記顏色"))
            Toggle(isOn: $ctrl.noteMode) { Image(systemName: "text.bubble") }
                .toggleStyle(.button).help(LZ("加便利貼：點頁面上的位置"))
            Toggle(isOn: $ctrl.captureMode) { Image(systemName: "crop") }
                .toggleStyle(.button).help(LZ("框選圖：存進筆記，並複製 PDF 給 Keynote"))
            Divider().frame(height: 16)
            Button { ctrl.zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }.help(LZ("縮小"))
            Button { ctrl.zoom(0) } label: { Image(systemName: "arrow.left.and.right") }.help(LZ("符合寬度"))
            Button { ctrl.zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }.help(LZ("放大"))
            Toggle(isOn: Binding(get: { ctrl.twoUp }, set: { ctrl.setTwoUp($0) })) { Image(systemName: "book") }
                .toggleStyle(.button).help(LZ("雙頁"))
            Toggle(isOn: Binding(get: { ctrl.dark }, set: { _ in ctrl.toggleDark() })) { Image(systemName: "moon") }
                .toggleStyle(.button).help(LZ("深色模式（圖保留原色）"))
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(LZ("搜尋全文"), text: $ctrl.findQuery)
                    .textFieldStyle(.plain).frame(width: 150)
                    .focused($findFocused)
                    .onSubmit { ctrl.findResults.isEmpty ? ctrl.runFind() : ctrl.findStep(1) }
                    .onChange(of: ctrl.findQuery) { _, _ in ctrl.clearFind() }
                if !ctrl.findResults.isEmpty {
                    Text("\(ctrl.findIndex + 1)/\(ctrl.findResults.count)").font(.caption).monospacedDigit()
                    Button { ctrl.findStep(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { ctrl.findStep(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button("") { findFocused = true }.keyboardShortcut("f", modifiers: .command).hidden().frame(width: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - Sidebar

struct ReaderSidebar: View {
    @ObservedObject var ctrl: ReaderController

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ctrl.sidebar) {
                Image(systemName: "square.grid.2x2").tag(ReaderController.SidebarMode.thumbnails)
                Image(systemName: "list.bullet.indent").tag(ReaderController.SidebarMode.outline)
                Image(systemName: "highlighter").tag(ReaderController.SidebarMode.annotations)
            }
            .pickerStyle(.segmented).labelsHidden().padding(6)
            Divider()
            switch ctrl.sidebar {
            case .thumbnails: ReaderThumbnails(ctrl: ctrl)
            case .outline: outline
            case .annotations: annotations
            }
        }
    }

    private var outline: some View {
        Group {
            if ctrl.outline.isEmpty {
                Text(LZ("這篇沒有目錄")).font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                List(ctrl.outline) { r in
                    Button { ctrl.jump(toPage: r.page) } label: {
                        HStack {
                            Text(r.label).lineLimit(2)
                            Spacer()
                            Text("\(r.page + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(r.depth) * 12)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var annotations: some View {
        Group {
            if ctrl.rows.isEmpty {
                Text(LZ("還沒有標記。選取文字後按 ⌘E。")).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding().frame(maxHeight: .infinity)
            } else {
                List(ctrl.rows) { r in ReaderAnnotationRow(row: r, ctrl: ctrl) }
                    .listStyle(.sidebar)
            }
        }
    }
}

struct ReaderAnnotationRow: View {
    let row: ReaderAnnotations.Row
    @ObservedObject var ctrl: ReaderController
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: NSColor(hex: row.color) ?? .systemYellow)).frame(width: 9, height: 9)
                Text("p. \(row.page + 1)").font(.caption2).foregroundStyle(.secondary)
                if row.author == "claude" { Text("Claude").font(.caption2).foregroundStyle(.purple) }
                Spacer()
                Menu {
                    ForEach(ReaderAnnotations.palette, id: \.hex) { c in Button(LZ(c.name)) { ctrl.setColor(c.hex, id: row.id) } }
                    Divider()
                    Button(LZ("刪除"), role: .destructive) { ctrl.delete(id: row.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 22)
            }
            if !row.text.isEmpty {
                Text(row.text).font(.callout).lineLimit(4)
            } else if row.kind == .note {
                Text(LZ("便利貼")).font(.caption).foregroundStyle(.secondary)
            } else if row.kind == .ink {
                Text(LZ("手繪")).font(.caption).foregroundStyle(.secondary)
            }
            TextField(LZ("加註解…"), text: $comment, axis: .vertical)
                .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .onSubmit { ctrl.setComment(comment, id: row.id) }
                .onChange(of: comment) { _, v in if v != row.comment { ctrl.setCommentLater(v, id: row.id) } }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { ctrl.jump(toAnnotation: row.id) }
        .onAppear { comment = row.comment }
        .onChange(of: row.comment) { _, v in if v != comment { comment = v } }
    }
}

extension ReaderController {
    /// Comments save a moment after typing stops, without re-listing rows on every key.
    func setCommentLater(_ c: String, id: String) {
        guard let d = pdfView?.document else { return }
        ReaderAnnotations.setComment(c, id: id, in: d)
        annotationsChanged()
    }
}

struct ReaderThumbnails: NSViewRepresentable {
    @ObservedObject var ctrl: ReaderController
    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.thumbnailSize = CGSize(width: 120, height: 160)
        v.backgroundColor = .clear
        v.pdfView = ctrl.pdfView
        return v
    }
    func updateNSView(_ v: PDFThumbnailView, context: Context) {
        if v.pdfView !== ctrl.pdfView { v.pdfView = ctrl.pdfView }
    }
}

// MARK: - PDF view

struct ReaderPDFRep: NSViewRepresentable {
    @ObservedObject var ctrl: ReaderController

    func makeNSView(context: Context) -> ReaderPDFView {
        let v = ReaderPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.captureActive = { [weak ctrl] in ctrl?.captureMode ?? false }
        v.onCapture = { [weak ctrl] r in ctrl?.capture(r) }
        v.noteActive = { [weak ctrl] in ctrl?.noteMode ?? false }
        v.onNote = { [weak ctrl] page, p in ctrl?.noteClicked(page: page, point: p) }
        let nc = NotificationCenter.default
        context.coordinator.tokens = [
            nc.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak ctrl] _ in ctrl?.pageChanged() },
            nc.addObserver(forName: .PDFViewScaleChanged, object: v, queue: .main) { [weak ctrl] _ in ctrl?.pageChanged() },
        ]
        ctrl.pdfView = v
        return v
    }

    func updateNSView(_ v: ReaderPDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// Hands the hosting NSWindow to a closure once it exists.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Quick open

struct ReaderQuickOpen: View {
    let store: PaperLibraryStore
    let done: (String?) -> Void
    @State private var query = ""
    @State private var papers: [(folder: String, meta: PaperMeta)] = []
    @State private var selection: String?

    private var shown: [(folder: String, meta: PaperMeta)] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return Array(papers.prefix(200)) }
        return papers.filter { p in
            let hay = "\(p.meta.citekey) \(p.meta.title) \(p.meta.year) \(p.meta.bibliographic.creators.map(\.family).joined(separator: " "))".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }.prefix(200).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(LZ("搜尋論文庫：作者、標題、年份、citekey"), text: $query)
                .textFieldStyle(.roundedBorder).padding(10)
                .onSubmit { done(selection ?? shown.first?.folder) }
            List(shown, id: \.folder, selection: $selection) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.meta.title.isEmpty ? p.meta.citekey : p.meta.title).lineLimit(1)
                    Text("\(p.meta.bibliographic.creators.first?.family ?? "") \(p.meta.year) · \(p.meta.citekey)\(p.meta.pdf == nil ? " · \(LZ("沒有 PDF"))" : "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(p.folder)
                .onTapGesture(count: 2) { done(p.folder) }
            }
            HStack {
                Text("\(shown.count) / \(papers.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(LZ("取消")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(LZ("打開")) { done(selection ?? shown.first?.folder) }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 620, height: 460)
        .onAppear { papers = store.allPapers().filter { $0.meta.pdf != nil } }
    }
}
