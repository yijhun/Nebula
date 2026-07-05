import SwiftUI
import AppKit
import UniformTypeIdentifiers



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
