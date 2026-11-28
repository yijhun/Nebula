import SwiftUI
import PDFKit
import AppKit

/// The paper reader (PAPER-LIBRARY.md §6): one window, Nebula's own tab bar
/// with the library tab first, a sidebar (thumbnails / outline / annotations)
/// and one PDFView that shows the active tab. Library papers keep
/// annotations in annotations.json.
struct ReaderWindowView: View {
    @EnvironmentObject var vault: VaultModel
    @ObservedObject private var session = ReaderSession.shared
    @StateObject private var ctrl: ReaderController

    init(controller: ReaderController? = nil) {
        _ctrl = StateObject(wrappedValue: controller ?? ReaderController())
    }

    var body: some View {
        VStack(spacing: 0) {
            ReaderTabBar(session: session, ctrl: ctrl)
            Divider()
            if !session.showLibrary {
                ReaderToolbar(ctrl: ctrl)
                Divider()
            }
            ZStack {
                // The paper stays attached under the library tab, so going
                // back to it is instant and keeps its place.
                if !session.tabs.isEmpty {
                    reader
                        .opacity(session.showLibrary ? 0 : 1)
                        .allowsHitTesting(!session.showLibrary)
                        .disabled(session.showLibrary)      // out of the Tab-key loop too
                        .accessibilityHidden(session.showLibrary)
                }
                if session.showLibrary {
                    LibraryView(index: session.library, session: session, ctrl: ctrl)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(WindowAccessor { w in ctrl.installKeys(window: w) })
        .onAppear { ctrl.vault = vault; if session.requestQuickOpen { ctrl.openLibrarySearch(); session.requestQuickOpen = false } }
        .onChange(of: session.requestQuickOpen) { _, v in if v { ctrl.openLibrarySearch(); session.requestQuickOpen = false } }
        .onDisappear { ctrl.detachCurrent(); session.saveAll() }
    }

    private var reader: some View {
        HSplitView {
            if ctrl.showSidebar {
                ReaderSidebar(ctrl: ctrl)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
            }
            ReaderPDFRep(ctrl: ctrl)
                .frame(minWidth: 420, minHeight: 400)
            if ctrl.showChat {
                Group {
                    if ctrl.chatAvailable {
                        ChatWebView(ctrl: ctrl.chat)
                    } else {
                        Text(LZ("Claude 只能讀論文庫裡的論文。用 ⌘T 從論文庫打開。"))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 560)
            }
        }
    }
}

// MARK: - Tab bar

struct ReaderTabBar: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var ctrl: ReaderController

    var body: some View {
        HStack(spacing: 2) {
            libraryTab
            Divider().frame(height: 16).padding(.horizontal, 2)
            ScrollView(.horizontal, showsIndicators: false) { tabs }
        }
        .padding(.leading, 6)
    }

    /// Always first and never closes, like Zotero's library tab.
    private var libraryTab: some View {
        Label(LZ("論文庫"), systemImage: "books.vertical")
            .font(.caption).labelStyle(.titleAndIcon)
            .foregroundStyle(session.showLibrary ? .primary : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(session.showLibrary ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { session.showLibrary = true }
            .help(LZ("論文庫：所有論文、專案、標籤（⌘T 搜尋）"))
    }

    private var tabs: some View {
            HStack(spacing: 2) {
                ForEach(session.tabs) { t in
                    let active = t.id == session.activeID && !session.showLibrary
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
                Button { ctrl.openLibrarySearch() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).padding(.horizontal, 8)
                    .help(LZ("從論文庫打開論文（⌘T）"))
            }
            .padding(.trailing, 6).padding(.vertical, 4)
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
            Divider().frame(height: 16)
            Button { ctrl.briefMe() } label: { Label(LZ("導讀"), systemImage: "sparkles") }
                .disabled(!ctrl.chatAvailable).help(LZ("Brief me：三行摘要、重要的圖、相關論文"))
            Menu {
                Button(LZ("這一頁")) { ctrl.suggestHighlights(wholePaper: false) }
                Button(LZ("整篇論文")) { ctrl.suggestHighlights(wholePaper: true) }
            } label: { Label(LZ("建議重點"), systemImage: "wand.and.stars") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(!ctrl.chatAvailable).help(LZ("請 Claude 建議重點，你逐一確認"))
            Toggle(isOn: $ctrl.showChat) { Image(systemName: "bubble.left.and.bubble.right") }
                .toggleStyle(.button).help(LZ("和 Claude 討論這篇（⌥⌘I）"))
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
                if row.id.hasPrefix("s:") {
                    Button { ctrl.acceptSuggestion(row.id) } label: { Image(systemName: "checkmark.circle") }
                        .buttonStyle(.borderless).help(LZ("留下這個重點"))
                    Button { ctrl.rejectSuggestion(row.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help(LZ("不要"))
                }
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
