import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

/// One document-structure item (heading / figure / table) for the sidebar outline.
struct OutlineEntry: Identifiable, Hashable {
    let id = UUID()
    let kind: String      // "heading" | "figure" | "table"
    let level: Int
    let text: String
    let pos: Int
    let referenced: Bool? // floats only: false → never \ref'd (orphan)
}

/// Per-tab editor state: the open file, the web editor, view mode, and the
/// native file/PDF operations. One instance per tab (a window has many).
final class EditorModel: ObservableObject, Identifiable {
    let id = UUID()
    /// Tab title (filename, or "未命名" when unsaved).
    @Published private(set) var displayName: String = LZ("未命名")
    enum ViewMode: String, CaseIterable, Identifiable {
        case edit, live, split, preview, tex
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return LZ("編輯")
            case .live: return LZ("即時")
            case .split: return LZ("並排")
            case .preview: return LZ("預覽")
            case .tex: return "LaTeX"
            }
        }
    }

    enum DocMode { case markdown, latex }

    /// View modes valid for the current document. The inline Markdown views
    /// (Live / LaTeX-source) make no sense for a `.tex` file, so hide them there.
    var availableViewModes: [ViewMode] {
        docMode == .latex ? [.edit, .split, .preview] : ViewMode.allCases
    }
    enum PaletteMode { case files, content }

    /// Open the command palette (quick-open / search). RootView presents it.
    func openPalette(_ mode: PaletteMode, query: String = "") {
        NotificationCenter.default.post(name: .noteproOpenPalette, object: nil,
            userInfo: ["mode": mode == .content ? "content" : "files", "query": query])
    }

    /// Open the semantic search / "ask your notes" sheet.
    func triggerSemantic() {
        NotificationCenter.default.post(name: .noteproOpenSemantic, object: nil)
    }

    /// Document structure (headings + figures/tables) pushed from the web core,
    /// shown in the sidebar's outline section.
    @Published var outline: [OutlineEntry] = []

    /// Editable YAML frontmatter ("properties", Notion-style) of the current note.
    struct PropertyField: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }
    @Published var properties: [PropertyField] = []

    /// Current vault root (set by RootView) — used to place generated LaTeX in
    /// the hidden output folder + resolve preview images. Re-push to the web on change.
    var vaultRoot: URL? { didSet { pushBasePaths() } }

    @Published var statusText: String = "就緒 Ready"
    /// Unsaved-changes indicator (dot on the tab chip). Set on edit, cleared
    /// on save / open.
    @Published var isDirty: Bool = false
    /// Live word count of the current document (pushed from the web core).
    @Published private(set) var wordCount: Int = 0
    @Published var isExporting: Bool = false
    @Published private(set) var docMode: DocMode = .markdown
    @Published private(set) var previewPDF: URL?
    @Published private(set) var previewVersion: Int = 0
    @Published private(set) var isCompilingPreview: Bool = false
    /// Last LaTeX compile error log (empty when the last compile succeeded).
    @Published private(set) var lastCompileError: String = ""
    @Published var aiFixing = false
    /// Editor line of the last compile error (mapped from the compiled file) + message.
    @Published private(set) var errorLine: Int?
    @Published private(set) var errorHint: String = ""
    @Published var viewMode: ViewMode =
        ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "split") ?? .split {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")  // remember last mode
            applyViewMode()
            if latexPreviewVisible { scheduleLatexPreview() }
        }
    }

    private weak var webView: WKWebView?
    private(set) var currentURL: URL?
    private var webReady = false
    private var pendingOpenURL: URL?   // open() called before the WebView booted

    /// Mirror (pop-out preview) plumbing. A mirror editor is read-only — it
    /// never saves or re-broadcasts, so source↔mirror can't loop. The source
    /// only bothers broadcasting while at least one mirror window is open.
    var isMirror = false
    static var mirrorCount = 0
    /// On a mirror: the id of the source editor it locked onto (so a dblclick
    /// jump goes back to that exact editor, not every tab showing the file).
    var mirrorSourceID: String?
    private var mirrorWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?

    /// SyncTeX forward target: which PDF page + box to highlight when the
    /// editor's cursor moves. `version` ticks every push so the PDFPreview
    /// re-scrolls even when the cursor revisits the same line. `nil` means
    /// no target / clear the highlight.
    struct SyncTarget: Equatable {
        var page: Int
        var rect: CGRect    // PDF point coords, top-left origin
        var version: Int
    }
    @Published var syncTarget: SyncTarget?

    private var syncTexWork: DispatchWorkItem?

    private func runSyncTeXForward(line: Int) {
        // Throttle: cursor moves can fire 60+/s while scrolling; coalesce to a
        // single call per ~150ms.
        syncTexWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let pdf = self.previewPDF, let src = self.syncTeXSourceURL() else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let r = SyncTeX.forward(line: line, source: src, pdf: pdf) else { return }
                DispatchQueue.main.async {
                    let next = (self.syncTarget?.version ?? 0) + 1
                    self.syncTarget = SyncTarget(
                        page: r.page,
                        rect: CGRect(x: r.x, y: r.y, width: max(r.width, 50), height: max(r.height, 12)),
                        version: next)
                }
            }
        }
        syncTexWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// SyncTeX reverse: the user clicked at (page, x, y) in the PDF preview —
    /// look up the matching source line and jump the editor there.
    func runSyncTeXReverse(page: Int, x: CGFloat, y: CGFloat) {
        guard let pdf = previewPDF, let _ = syncTeXSourceURL() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let r = SyncTeX.reverse(pdf: pdf, page: page, x: x, y: y) else { return }
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript("window.notepro.jumpToLine(\(r.line))")
            }
        }
    }

    /// The .tex file that synctex resolved against. For .tex docs it's the
    /// file on disk; for Markdown drafts it's the hidden `.notepro-preview.tex`
    /// that `compileLatexPreview` writes alongside the note.
    private func syncTeXSourceURL() -> URL? {
        guard let cur = currentURL else { return nil }
        if docMode == .latex { return cur }
        let dir = cur.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent(".notepro-preview.tex")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Toggle to show the compiled-PDF live preview alongside a Markdown note —
    /// the Overleaf-style "right pane shows the rendered paper as you draft."
    /// LaTeX mode has it implicitly via split/preview view modes; this flag
    /// brings the same panel into Markdown mode without changing view mode.
    @Published var pdfPreviewOn: Bool = false {
        didSet {
            UserDefaults.standard.set(pdfPreviewOn, forKey: "pdfPreviewOn")
            if latexPreviewVisible { scheduleLatexPreview() }
        }
    }

    /// True when a compiled-PDF preview should be shown.
    var latexPreviewVisible: Bool {
        (docMode == .latex && viewMode != .edit) || (docMode == .markdown && pdfPreviewOn)
    }

    static func mode(for url: URL) -> DocMode {
        url.pathExtension.lowercased() == "tex" ? .latex : .markdown
    }

    private var themeObserver: NSObjectProtocol?
    private var vimObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var noteListObserver: NSObjectProtocol?
    private var noteNamesCache: [String] = []
    init() {
        pdfPreviewOn = UserDefaults.standard.bool(forKey: "pdfPreviewOn")
        themeObserver = NotificationCenter.default.addObserver(
            forName: .noteproThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.applyTheme() }
        vimObserver = NotificationCenter.default.addObserver(
            forName: .noteproVimChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.applyVim() }
        configObserver = NotificationCenter.default.addObserver(
            forName: .noteproConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.applyConfig() }
        noteListObserver = NotificationCenter.default.addObserver(
            forName: .noteproNoteList, object: nil, queue: .main
        ) { [weak self] note in
            self?.noteNamesCache = note.userInfo?["names"] as? [String] ?? []
            self?.pushNoteList()
        }
        // A popped-out preview window double-clicked → jump THIS editor (the
        // source) if it's showing the same file.
        mirrorJumpObserver = NotificationCenter.default.addObserver(
            forName: .noteproMirrorJump, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.isMirror,
                  let line = note.userInfo?["line"] as? Int else { return }
            // Match the exact source the mirror locked onto so only one editor
            // jumps (avoids every tab with this file fighting for key window).
            let targetID = note.userInfo?["targetID"] as? String ?? ""
            guard targetID == self.id.uuidString else { return }
            self.webView?.evaluateJavaScript("window.notepro.jumpToLine(\(line))")
            self.webView?.window?.makeKeyAndOrderFront(nil)
        }
    }
    private var mirrorJumpObserver: NSObjectProtocol?

    /// Push the current note dir + vault root so the preview can resolve images.
    func pushBasePaths() {
        guard webReady else { return }
        let note = currentURL?.deletingLastPathComponent().path ?? ""
        let vault = vaultRoot?.path ?? ""
        webView?.evaluateJavaScript(
            "window.notepro.setBasePaths(\(Self.jsStringLiteral(note)),\(Self.jsStringLiteral(vault)))")
    }

    /// Insert text at the cursor (drag-and-drop image, etc.).
    func insertText(_ text: String) {
        webView?.evaluateJavaScript("window.notepro.insertText(\(Self.jsStringLiteral(text)))")
    }

    /// Save a dropped image (data URL) into the vault's Assets/ and insert `![[name]]`.
    /// Where a dropped image is saved, per the "attachment location" setting:
    /// "note" = the current note's folder, "root" = vault root, else (default)
    /// a named folder under the vault (`attachmentFolder`, default "Assets").
    private func attachmentDir(vaultRoot root: URL) -> URL {
        let d = UserDefaults.standard
        switch d.string(forKey: "attachmentMode") ?? "folder" {
        case "note": return currentURL?.deletingLastPathComponent() ?? root
        case "root": return root
        default:
            let name = (d.string(forKey: "attachmentFolder") ?? "Assets")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? root : root.appendingPathComponent(name, isDirectory: true)
        }
    }

    private func saveDroppedImage(_ body: [String: Any]) {
        guard let root = vaultRoot,
              let name = body["name"] as? String,
              let dataURL = body["data"] as? String,
              let comma = dataURL.firstIndex(of: ","),
              let bytes = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            statusText = "圖片拖入失敗（請先開啟資料夾）"; return
        }
        let fm = FileManager.default
        let dir = attachmentDir(vaultRoot: root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.isEmpty ? "image.png" : name
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension.isEmpty ? "png" : (safe as NSString).pathExtension
        var dest = dir.appendingPathComponent(safe)
        var n = 1
        while fm.fileExists(atPath: dest.path) { dest = dir.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1 }
        do {
            try bytes.write(to: dest)
            pushBasePaths()   // ensure the preview knows the vault path before rendering
            insertText("![[\(dest.lastPathComponent)]]\n")
            statusText = "已插入圖片 \(dest.lastPathComponent)"
        } catch {
            statusText = "圖片寫入失敗: \(error.localizedDescription)"
        }
    }

    /// Push the vault's note names to the web core (for `[[` completion + broken-link flags).
    func pushNoteList() {
        guard webReady,
              let data = try? JSONSerialization.data(withJSONObject: noteNamesCache),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.notepro.setNoteList(\(Self.jsStringLiteral(json)))")
    }

    /// Push user settings (presets / cite format / appearance / snippets) to the web core.
    func applyConfig() {
        guard webReady else { return }
        let d = UserDefaults.standard
        var cfg: [String: Any] = [
            "citeLatexCommand": d.string(forKey: "citeLatexCommand") ?? "autocite",
            "previewCiteStyle": d.string(forKey: "previewCiteStyle") ?? "author-year",
            "fontSize": d.object(forKey: "fontSize") as? Double ?? 14,
            "fontFamily": d.string(forKey: "fontFamily") ?? "ui-monospace, \"SF Mono\", Menlo, monospace",
            "lineHeight": d.object(forKey: "lineHeight") as? Double ?? 1.6,
            "snippets": Self.parsePairs(d.string(forKey: "snippetsText") ?? "", valueKey: "template"),
            "defaultTemplate": d.string(forKey: "defaultTemplate") ?? "apj",
        ]
        let presets = Self.parsePairs(d.string(forKey: "aiPresetsText") ?? "", valueKey: "instruction")
        if !presets.isEmpty { cfg["aiPresets"] = presets }
        guard let data = try? JSONSerialization.data(withJSONObject: cfg),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.notepro.configure(\(Self.jsStringLiteral(json)))")
    }

    /// Parse "label | value" lines into [{label, <valueKey>}].
    static func parsePairs(_ text: String, valueKey: String) -> [[String: String]] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { return nil }
            let label = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1...].joined(separator: "|").trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : ["label": label, valueKey: value]
        }
    }

    /// Apply the Vim-mode setting to the webview editor.
    func applyVim() {
        guard webReady else { return }
        let on = UserDefaults.standard.bool(forKey: "vimMode")
        webView?.evaluateJavaScript("window.notepro.setVim(\(on))")
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    /// Apply the appearance from settings ("system"/"light"/"dark") to the webview.
    func applyTheme() {
        guard webReady else { return }
        let setting = UserDefaults.standard.string(forKey: "theme") ?? "system"
        let resolved: String
        switch setting {
        case "light": resolved = "light"
        case "dark": resolved = "dark"
        default:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            resolved = dark ? "dark" : "light"
        }
        webView?.evaluateJavaScript("window.notepro.setTheme('\(resolved)')")
    }

    // MARK: - Messages from the web core

    func handleMessage(_ body: [String: Any]) {
        let type = body["type"] as? String ?? ""
        if type == "jserror" {
            let msg = body["message"] as? String ?? "?"
            statusText = "⚠ JS 錯誤: \(msg.prefix(80))"
            let line = "[\(Date())] \(msg)\n"
            let log = URL(fileURLWithPath: "/tmp/notepro-jserror.log")
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(data); try? h.close() }
                else { try? data.write(to: log) }
            }
            return
        }
        if type == "dropImage" { saveDroppedImage(body); return }
        if type == "outline" { updateOutline(body["items"]); return }
        if type == "stats" { wordCount = (body["words"] as? NSNumber)?.intValue ?? 0; return }
        if type == "openLink" {
            if let target = body["target"] as? String {
                NotificationCenter.default.post(name: .noteproOpenWikilink, object: nil,
                                                userInfo: ["target": target])
            }
            return
        }
        if type == "openCite" {
            if let key = body["key"] as? String { Self.openInZotero(citekey: key) }
            return
        }
        if type == "popoutPreview" {
            if let url = currentURL {
                NotificationCenter.default.post(name: .noteproOpenPreviewWindow, object: nil,
                                                userInfo: ["url": url])
            }
            return
        }
        if type == "previewJump" {
            // Only meaningful from a popped-out preview: route the jump to the
            // exact source editor this mirror locked onto.
            if isMirror, let url = currentURL, let line = body["line"] as? Int {
                NotificationCenter.default.post(name: .noteproMirrorJump, object: nil,
                                                userInfo: ["url": url, "line": line,
                                                           "targetID": mirrorSourceID ?? ""])
            }
            return
        }
        switch type {
        case "ready":
            webReady = true
            applyMode()
            applyViewMode()
            applyTheme()
            applyVim()
            applyConfig()
            webView?.evaluateJavaScript("window.notepro.setLang('\(currentlyEnglish() ? "en" : "zh")')")
            pushBasePaths()
            pushNoteList()
            NotificationCenter.default.post(name: .noteproRequestNoteList, object: nil)
            if latexPreviewVisible { scheduleLatexPreview() }
            refreshProperties()
            statusText = currentURL?.lastPathComponent ?? "新文件 Untitled"
            // A file requested before the WebView booted — load it now.
            if let p = pendingOpenURL { pendingOpenURL = nil; open(p) }
            if let t = pendingMirrorText { pendingMirrorText = nil; setContent(t) }
        case "dirty":
            guard !isMirror else { break }   // mirror previews are read-only
            isDirty = true
            statusText = "已編輯 • \(currentURL?.lastPathComponent ?? "Untitled")"
            if latexPreviewVisible { scheduleLatexPreview() }
            scheduleAutoSave()
            scheduleMirrorBroadcast()
        case "loaded":
            statusText = currentURL?.lastPathComponent ?? "新文件 Untitled"
            refreshProperties()
        case "cursorLine":
            // SyncTeX forward — only meaningful when the PDF preview is up.
            if latexPreviewVisible, let line = body["line"] as? Int {
                runSyncTeXForward(line: line)
            }
        default:
            break
        }
    }

    // MARK: - Bridge RPC (request/response, e.g. ai.edit)

    func handleRPC(_ body: [String: Any]) {
        guard let id = body["id"] as? Int, let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        switch method {
        case "ai.edit":
            let text = params["text"] as? String ?? ""
            let instruction = params["instruction"] as? String ?? ""
            AIProvider.shared.edit(text: text, instruction: instruction) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let out): self?.resolveRPC(id, ok: true, payload: out)
                    case .failure(let err): self?.resolveRPC(id, ok: false, payload: err.localizedDescription)
                    }
                }
            }
        case "ai.generate":
            let context = params["context"] as? String ?? ""
            let instruction = params["instruction"] as? String ?? ""
            AIProvider.shared.generate(context: context, instruction: instruction) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let out): self?.resolveRPC(id, ok: true, payload: out)
                    case .failure(let err): self?.resolveRPC(id, ok: false, payload: err.localizedDescription)
                    }
                }
            }
        case "vault.readText":
            // Read a text file from the vault (chart `data: obs.csv`). Resolved
            // like images: note dir → vault root → basename search. 2MB cap.
            // SECURITY: reject path escapes and anything resolving OUTSIDE the
            // vault (a note must not read arbitrary files via the bridge).
            let ref = params["ref"] as? String ?? ""
            let base = currentURL?.deletingLastPathComponent().path ?? vaultRoot?.path ?? ""
            let vaultPath = vaultRoot?.path ?? ""
            guard !ref.isEmpty, !ref.contains("..") else {
                resolveRPC(id, ok: false, payload: "不允許的路徑：\(ref)"); return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var payload = "找不到或無法讀取：\(ref)"
                var ok = false
                if let url = ImageSchemeHandler.resolve(ref: ref, base: base, vault: vaultPath) {
                    let resolved = url.standardizedFileURL.path
                    // Must live inside the vault (or the note's own folder).
                    let insideVault = !vaultPath.isEmpty && resolved.hasPrefix(vaultPath + "/")
                    let insideNote = !base.isEmpty && resolved.hasPrefix(base + "/")
                    if insideVault || insideNote,
                       let data = try? Data(contentsOf: url), data.count <= 2_000_000,
                       let text = String(data: data, encoding: .utf8) {
                        payload = text; ok = true
                    } else if !(insideVault || insideNote) {
                        payload = "檔案在 vault 之外，已拒絕：\(ref)"
                    }
                }
                DispatchQueue.main.async { self?.resolveRPC(id, ok: ok, payload: payload) }
            }
        case "zotero.search":
            let query = params["query"] as? String ?? ""
            ZoteroService.search(query) { [weak self] items in
                let arr = items.map { ["citekey": $0.citekey, "title": $0.title,
                                       "authors": $0.authors, "year": $0.year] }
                let data = (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
                self?.resolveRPCJSON(id, ok: true, rawJSON: String(data: data, encoding: .utf8) ?? "[]")
            }
        case "zotero.bib":
            let keys = params["keys"] as? [String] ?? []
            ZoteroService.exportBib(keys) { [weak self] bib in
                self?.resolveRPC(id, ok: true, payload: bib)
            }
        case "zotero.meta":
            let keys = params["keys"] as? [String] ?? []
            ZoteroService.meta(keys) { [weak self] map in
                let data = (try? JSONSerialization.data(withJSONObject: map)) ?? Data("{}".utf8)
                self?.resolveRPCJSON(id, ok: true, rawJSON: String(data: data, encoding: .utf8) ?? "{}")
            }
        default:
            resolveRPC(id, ok: false, payload: "unknown method: \(method)")
        }
    }

    private func resolveRPC(_ id: Int, ok: Bool, payload: String) {
        let literal = Self.jsStringLiteral(payload)
        webView?.evaluateJavaScript("window.notepro._rpcResolve(\(id), \(ok), \(literal))")
    }

    /// Resolve an RPC with a raw JSON value (array/object), not a string.
    private func resolveRPCJSON(_ id: Int, ok: Bool, rawJSON: String) {
        webView?.evaluateJavaScript("window.notepro._rpcResolve(\(id), \(ok), \(rawJSON))")
    }

    /// Insert a citation for `key` at the editor's cursor (used by the native
    /// Zotero sidebar panel; the web cite popup inserts directly).
    func insertCitation(_ key: String) {
        webView?.evaluateJavaScript("window.notepro.insertCitation(\(Self.jsStringLiteral(key)))")
    }

    /// Menu-invoked: open the AI overlay / Zotero cite picker in this editor.
    func triggerAI() { webView?.evaluateJavaScript("window.notepro.ai()") }
    func triggerCite() { webView?.evaluateJavaScript("window.notepro.cite()") }

    /// Run a Markdown-table command at the cursor (insert/delete row/col …).
    func tableOp(_ op: String) {
        let safe = op.filter { $0.isLetter }
        webView?.evaluateJavaScript("window.notepro.tableOp('\(safe)')") { [weak self] result, _ in
            if (result as? String) == "no-table" {
                self?.statusText = "游標不在表格內（先點進一個 Markdown 表格）"
            }
        }
    }

    /// Open the interactive chart studio for the ```chart block at the cursor.
    func chartStudio() {
        webView?.evaluateJavaScript("window.notepro.chartStudio()")
    }

    /// Open the geometry/diagram editor (points/arrows/circles → TikZ).
    func diagramStudio() {
        webView?.evaluateJavaScript("window.notepro.diagramStudio()")
    }

    /// Open the 3D figure editor (drag to rotate the view → baked TikZ).
    func diagram3dStudio() {
        webView?.evaluateJavaScript("window.notepro.diagram3dStudio()")
    }

    /// Translate the ```chart block at the cursor into a ```tikz block below it.
    func chartToTikz() {
        webView?.evaluateJavaScript("window.notepro.chartToTikz()") { [weak self] result, _ in
            switch result as? String {
            case "no-chart": self?.statusText = "游標不在 chart 區塊內（先點進一個 ```chart）"
            case let s? where s.hasPrefix("error:"):
                self?.statusText = "chart 轉換失敗：\(s.dropFirst(6))"
            default: self?.statusText = "已插入 TikZ 版（原 chart 草稿保留）"
            }
        }
    }

    /// Open the citation under the cursor in Zotero (Better BibTeX select URI).
    func openCiteAtCursorInZotero() {
        webView?.evaluateJavaScript("window.notepro.citeAtCursor()") { result, _ in
            guard let key = result as? String, !key.isEmpty else {
                self.statusText = "游標不在引用上（把游標移到 [@key] 內）"; return
            }
            Self.openInZotero(citekey: key)
        }
    }

    /// Open a citekey in Zotero. Better BibTeX resolves `@citekey`; if Zotero
    /// isn't running, macOS launches it first. Falls back to selecting by the
    /// raw key (works for Zotero's own keys too).
    static func openInZotero(citekey: String) {
        let escaped = citekey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? citekey
        guard let url = URL(string: "zotero://select/items/@\(escaped)") else { return }
        NSWorkspace.shared.open(url)
    }
    /// Open the in-document find bar (⌘F) inside the editor.
    func find() { webView?.evaluateJavaScript("window.notepro.find()") }

    /// Rename the current file (keeping its extension), Obsidian-style, from the
    /// inline title. Keeps the editor buffer (no reload) and lets the file
    /// watcher refresh the sidebar.
    func renameCurrent(to newBase: String) {
        guard let url = currentURL else { return }
        let trimmed = newBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldBase = url.deletingPathExtension().lastPathComponent
        guard !trimmed.isEmpty,
              !trimmed.contains("/"), !trimmed.hasPrefix("."),
              trimmed != oldBase else { return }
        let ext = url.pathExtension
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? trimmed : "\(trimmed).\(ext)")
        // APFS is case-INSENSITIVE by default — `Foo` → `foo` makes `fileExists`
        // see the existing source file at `dest` and abort. Detect a pure
        // case-only rename and route through a temp filename so APFS lets it
        // through.
        let isCaseOnlyRename = trimmed.lowercased() == oldBase.lowercased()
        let fm = FileManager.default
        if !isCaseOnlyRename, fm.fileExists(atPath: dest.path) {
            statusText = "已有同名檔：\(dest.lastPathComponent)"; return
        }
        do {
            if isCaseOnlyRename {
                let temp = url.deletingLastPathComponent()
                    .appendingPathComponent(".nebula-rename-\(UUID().uuidString).\(ext)")
                try fm.moveItem(at: url, to: temp)
                try fm.moveItem(at: temp, to: dest)
            } else {
                try fm.moveItem(at: url, to: dest)
            }
            currentURL = dest
            displayName = dest.lastPathComponent
            statusText = "已重新命名為 \(dest.lastPathComponent)"
        } catch {
            statusText = "重新命名失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - Properties (frontmatter form)

    /// Re-read the note's YAML frontmatter into `properties`.
    func refreshProperties() {
        webView?.evaluateJavaScript("window.notepro.getFrontmatter()") { [weak self] result, _ in
            guard let self, let json = result as? String, let data = json.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String]] else { return }
            let fields = arr.compactMap { pair -> PropertyField? in
                pair.count == 2 ? PropertyField(key: pair[0], value: pair[1]) : nil
            }
            if fields != self.properties { self.properties = fields }
        }
    }

    func setProperty(_ key: String, _ value: String) {
        webView?.evaluateJavaScript(
            "window.notepro.setFrontmatterField(\(Self.jsStringLiteral(key)),\(Self.jsStringLiteral(value)))")
        if let i = properties.firstIndex(where: { $0.key == key }) { properties[i].value = value }
        else { properties.append(PropertyField(key: key, value: value)) }
    }

    func removeProperty(_ key: String) {
        webView?.evaluateJavaScript("window.notepro.removeFrontmatterField(\(Self.jsStringLiteral(key)))")
        properties.removeAll { $0.key == key }
    }

    /// Check the document for unbalanced $ / $$ / \begin…\end (the usual cause of
    /// "Missing $ inserted"). Jumps to the first issue and reports the count.
    func checkLatex() {
        guard let webView else { return }
        webView.evaluateJavaScript("window.notepro.lintLatex()") { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                self.statusText = "檢查失敗"; return
            }
            if let first = arr.first, let line = first["line"] as? Int,
               let msg = first["message"] as? String {
                self.statusText = "⚠ \(msg)" + (arr.count > 1 ? "（共 \(arr.count) 處）" : "")
                webView.evaluateJavaScript("window.notepro.scrollToLine(\(line))")
            } else {
                self.statusText = "✓ 配對正常（$ / $$ / \\begin 都成對）"
            }
        }
    }
    /// Scroll the editor to a structure item (called from the sidebar outline).
    func scrollTo(pos: Int) { webView?.evaluateJavaScript("window.notepro.scrollToPos(\(pos))") }

    /// Jump the editor to the line of the last compile error.
    func scrollToErrorLine() { if let l = errorLine { webView?.evaluateJavaScript("window.notepro.scrollToLine(\(l))") } }

    /// Parse the tectonic error for "preview.tex:NN: message", and map line NN
    /// back to the EDITOR's line by matching the offending line's text (avoids
    /// brittle preamble-offset math).
    private func locateError(log: String, preparedTex: String, editorText: String) {
        errorLine = nil; errorHint = ""
        guard let re = try? NSRegularExpression(pattern: #"\.notepro-preview\.tex:(\d+):\s*([^\n]+)"#) else { return }
        let ns = log as NSString
        guard let m = re.firstMatch(in: log, range: NSRange(location: 0, length: ns.length)) else { return }
        let pl = Int(ns.substring(with: m.range(at: 1))) ?? 0
        errorHint = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let texLines = preparedTex.components(separatedBy: "\n")
        guard pl >= 1, pl <= texLines.count else { return }
        let target = texLines[pl - 1].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        let edLines = editorText.components(separatedBy: "\n")
        errorLine = edLines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == target }.map { $0 + 1 }
    }

    private func updateOutline(_ raw: Any?) {
        guard let arr = raw as? [[String: Any]] else { outline = []; return }
        outline = arr.map { d in
            OutlineEntry(
                kind: d["kind"] as? String ?? "heading",
                level: (d["level"] as? NSNumber)?.intValue ?? 0,
                text: d["text"] as? String ?? "",
                pos: (d["pos"] as? NSNumber)?.intValue ?? 0,
                referenced: d["referenced"] as? Bool
            )
        }
    }

    /// If `text` is a LaTeX fragment (no `\documentclass`), wrap it in a minimal
    /// standalone document so it can be previewed/compiled on its own.
    static func wrapLatexFragment(_ text: String) -> String {
        if text.contains("\\documentclass") {
            // Complete doc: if it lacks Unicode handling, inject it before
            // \begin{document} so pasted ×/−/Greek compile (e.g. older conversions).
            guard !text.contains("newunicodechar"),
                  let r = text.range(of: "\\begin{document}") else { return text }
            let uni = unicodeMap(for: text)
            guard !uni.isEmpty else { return text }
            return text.replacingCharacters(
                in: r.lowerBound ..< r.lowerBound,
                with: "\\usepackage{newunicodechar}\n\(uni)\n")
        }
        let uni = Self.unicodeMap(for: text)
        let uniBlock = uni.isEmpty ? "" : "\\usepackage{newunicodechar}\n\(uni)\n"
        return """
        \\documentclass[11pt,a4paper]{article}
        \\usepackage{amsmath,amssymb,bm}
        \\usepackage{graphicx}
        \\usepackage{hyperref}
        \\usepackage{ctex}
        \(uniBlock)\\begin{document}
        \(text)
        \\end{document}
        """
    }

    /// Map common scientific/Greek Unicode characters so pasted text (×, −, Å,
    /// M⊙, αβγ…) compiles under XeLaTeX instead of failing as "missing character".
    /// Build the `\newunicodechar` block for only the Unicode chars present in
    /// `text` (so the preamble stays short — was dumping all ~80 every time).
    static func unicodeMap(for text: String) -> String {
        let math: [(String, String)] = [
            ("×", "\\times"), ("−", "-"), ("≈", "\\approx"), ("≃", "\\simeq"),
            ("≤", "\\le"), ("≥", "\\ge"), ("≠", "\\neq"), ("∼", "\\sim"),
            ("∝", "\\propto"), ("·", "\\cdot"), ("→", "\\to"), ("←", "\\leftarrow"),
            ("↔", "\\leftrightarrow"), ("⇒", "\\Rightarrow"), ("±", "\\pm"),
            ("∓", "\\mp"), ("∞", "\\infty"), ("∇", "\\nabla"), ("∂", "\\partial"),
            ("∫", "\\int"), ("∑", "\\sum"), ("∏", "\\prod"), ("√", "\\surd"),
            ("⊙", "\\odot"), ("′", "'"), ("″", "''"), ("°", "^\\circ"), ("≡", "\\equiv"),
            ("α", "\\alpha"), ("β", "\\beta"), ("γ", "\\gamma"), ("δ", "\\delta"),
            ("ε", "\\epsilon"), ("ζ", "\\zeta"), ("η", "\\eta"), ("θ", "\\theta"),
            ("κ", "\\kappa"), ("λ", "\\lambda"), ("μ", "\\mu"), ("ν", "\\nu"),
            ("ξ", "\\xi"), ("π", "\\pi"), ("ρ", "\\rho"), ("σ", "\\sigma"),
            ("τ", "\\tau"), ("φ", "\\phi"), ("χ", "\\chi"), ("ψ", "\\psi"), ("ω", "\\omega"),
            ("Γ", "\\Gamma"), ("Δ", "\\Delta"), ("Θ", "\\Theta"), ("Λ", "\\Lambda"),
            ("Π", "\\Pi"), ("Σ", "\\Sigma"), ("Φ", "\\Phi"), ("Ψ", "\\Psi"), ("Ω", "\\Omega"),
            ("⁰", "^0"), ("¹", "^1"), ("²", "^2"), ("³", "^3"), ("⁴", "^4"),
            ("⁵", "^5"), ("⁶", "^6"), ("⁷", "^7"), ("⁸", "^8"), ("⁹", "^9"),
            ("⁻", "^-"), ("⁺", "^+"),
            ("₀", "_0"), ("₁", "_1"), ("₂", "_2"), ("₃", "_3"), ("₄", "_4"),
            ("₅", "_5"), ("₆", "_6"), ("₇", "_7"), ("₈", "_8"), ("₉", "_9"),
        ]
        // Joined on ONE line so it barely shifts user line numbers in compile errors.
        return math
            .filter { text.contains($0.0) }
            .map { "\\newunicodechar{\($0.0)}{\\ensuremath{\($0.1)}}" }
            .joined(separator: " ")
    }

    /// Extract cite keys from LaTeX `\cite`-family commands.
    static func citeKeys(inLatex text: String) -> [String] {
        var keys: [String] = []
        guard let re = try? NSRegularExpression(
            pattern: #"\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{([^}]+)\}"#) else { return [] }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inside = ns.substring(with: m.range(at: 1))
            keys += inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return keys.filter { !$0.isEmpty }
    }

    // MARK: - Swift -> JS

    private func setContent(_ text: String) {
        webView?.evaluateJavaScript("window.notepro.setContent(\(Self.jsStringLiteral(text)))")
    }

    private func getContent(_ completion: @escaping (String) -> Void) {
        guard let webView else { completion(""); return }
        webView.evaluateJavaScript("window.notepro.getContent()") { result, _ in
            completion(result as? String ?? "")
        }
    }

    /// Cowork-with-Claude payload helpers. The selection / heading-bounded
    /// section / whole note — picked by the user in the Cowork sheet, then
    /// composed with a prompt and shipped via clipboard + open claude.ai.
    func getCoworkPayload(scope: String, completion: @escaping (String) -> Void) {
        guard let webView else { completion(""); return }
        let js: String
        switch scope {
        case "selection": js = "window.notepro.getSelection()"
        case "section":   js = "window.notepro.getCurrentSection()"
        default:          js = "window.notepro.getContent()"
        }
        webView.evaluateJavaScript(js) { result, _ in
            completion(result as? String ?? "")
        }
    }

    private func applyViewMode() {
        guard webReady else { return }
        // In LaTeX mode the web layer is editor-only; the native PDFPreview pane
        // is the preview (driven by viewMode in EditorPane).
        let webMode = docMode == .latex ? "edit" : viewMode.rawValue
        webView?.evaluateJavaScript("window.notepro.setViewMode('\(webMode)')")
    }

    // MARK: - LaTeX live preview (compile-on-edit, debounced)

    private func scheduleLatexPreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compileLatexPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func compileLatexPreview() {
        guard let webView else { return }
        guard docMode == .latex || (docMode == .markdown && pdfPreviewOn) else { return }
        isCompilingPreview = true
        // For Markdown mode we run the in-process md→LaTeX converter first so the
        // PDF panel shows what the eventual paper will look like, not an HTML
        // approximation. The conversion is fast (cached MathJax SVGs) and shares
        // the same compile path as .tex mode below.
        let js = docMode == .latex
            ? "window.notepro.getContent()"
            : "window.notepro.toLatex()"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let tex = Self.wrapLatexFragment(result as? String ?? "")
            let done: (Result<URL, Error>) -> Void = { [weak self] outcome in
                guard let self else { return }
                self.isCompilingPreview = false
                switch outcome {
                case .success(let pdf):
                    self.previewPDF = pdf
                    self.previewVersion += 1
                    self.lastCompileError = ""
                    self.errorLine = nil; self.errorHint = ""
                case .failure(let err):
                    self.statusText = "預覽編譯失敗: \(err.localizedDescription)"
                    self.lastCompileError = err.localizedDescription
                    self.locateError(log: err.localizedDescription, preparedTex: tex,
                                     editorText: result as? String ?? "")
                }
            }
            if let url = self.currentURL {
                // In-place: hidden temp .tex in the file's dir so sibling
                // references.bib / images / \input resolve in the live preview.
                let dir = url.deletingLastPathComponent()
                PDFExporter.stageImages(tex: tex, into: dir, base: dir, vault: self.vaultRoot)
                PDFExporter.compilePreview(content: tex, in: dir, completion: done)
            } else {
                // Unsaved doc: compile the buffer in a temp dir (no siblings).
                PDFExporter.export(tex: tex, bib: "", name: "preview", completion: done)
            }
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let vimObserver { NotificationCenter.default.removeObserver(vimObserver) }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let noteListObserver { NotificationCenter.default.removeObserver(noteListObserver) }
        if let mirrorJumpObserver { NotificationCenter.default.removeObserver(mirrorJumpObserver) }
        // A force-closed preview window may never get onDisappear → decrement
        // here too so the source doesn't keep broadcasting forever.
        if isMirror { EditorModel.mirrorCount = max(0, EditorModel.mirrorCount - 1) }
        previewWork?.cancel(); autoSaveWork?.cancel(); mirrorWork?.cancel(); syncTexWork?.cancel()
        // NOTE: deliberately do NOT delete the hidden `.notepro-preview.*`
        // artifacts here — they're shared per-folder, so another editor open
        // on a sibling note may still be using them. They're hidden, gitignored,
        // and overwritten on the next preview compile.
    }

    private func applyMode() {
        guard webReady else { return }
        webView?.evaluateJavaScript("window.notepro.setMode('\(docMode == .latex ? "latex" : "markdown")')")
    }

    // MARK: - Files

    /// Open a file from the vault (or anywhere) into this window's editor.
    func open(_ url: URL) {
        // A tab created on-the-fly (e.g. drag-drop onto the tab bar) may not
        // have its WebView yet — setContent would no-op and the editor would
        // boot showing the default welcome doc. Defer until `ready` fires.
        guard webReady else {
            pendingOpenURL = url
            currentURL = url
            displayName = url.lastPathComponent
            docMode = Self.mode(for: url)
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            currentURL = url
            displayName = url.lastPathComponent
            docMode = Self.mode(for: url)
            previewPDF = nil
            isDirty = false
            pushBasePaths()   // BEFORE setContent so Live Preview image widgets resolve
            setContent(text)
            applyMode()
            pushBasePaths()   // resolve images relative to this note
            if latexPreviewVisible { scheduleLatexPreview() }
            statusText = url.lastPathComponent
        } catch {
            statusText = "開啟失敗: \(error.localizedDescription)"
        }
    }

    /// Load a brand-new LaTeX document from a template skeleton. If a vault is
    /// open, persist it as a new .tex; otherwise just load it (unsaved).
    func newFromTemplate(_ templateId: String, vault: VaultModel) {
        guard let webView else { return }
        let safe = templateId.replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript("window.notepro.newFromTemplate('\(safe)')") { [weak self] result, _ in
            guard let self else { return }
            let skeleton = result as? String ?? ""
            if vault.rootURL != nil, let url = vault.newFile(baseName: templateId, ext: "tex", content: skeleton) {
                self.open(url)
            } else {
                self.currentURL = nil
                self.docMode = .latex
                self.setContent(skeleton)
                self.applyMode()
                self.statusText = "新 LaTeX (未儲存)"
            }
        }
    }

    func save() {
        if let url = currentURL { write(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        let isTex = docMode == .latex
        panel.allowedContentTypes = isTex ? Self.texTypes : Self.markdownTypes
        panel.nameFieldStringValue = currentURL?.lastPathComponent ?? (isTex ? "Untitled.tex" : "Untitled.md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        currentURL = url
        write(to: url)
    }

    private func write(to url: URL) {
        getContent { [weak self] text in
            guard let self else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.isDirty = false
                self.displayName = url.lastPathComponent
                self.statusText = "已儲存 \(url.lastPathComponent)"
                HistoryStore.snapshot(root: self.vaultRoot, file: url, content: text) // revision history
            } catch {
                self.statusText = "儲存失敗: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Mirror (pop-out live preview) broadcast

    /// Debounced (400ms) push of the live buffer to any open preview windows.
    private func scheduleMirrorBroadcast() {
        guard EditorModel.mirrorCount > 0, let url = currentURL else { return }
        mirrorWork?.cancel()
        let sourceID = id.uuidString
        let work = DispatchWorkItem { [weak self] in
            self?.getContent { text in
                NotificationCenter.default.post(name: .noteproMirrorContent, object: nil,
                                                userInfo: ["url": url, "text": text, "sourceID": sourceID])
            }
        }
        mirrorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Apply mirrored content into this (read-only) preview editor's webview.
    func applyMirrorContent(_ text: String) {
        guard webReady else { pendingMirrorText = text; return }
        setContent(text)
    }
    private var pendingMirrorText: String?

    // MARK: - Auto-save

    private var autoSaveWork: DispatchWorkItem?
    private var autoSaveEnabled: Bool { UserDefaults.standard.object(forKey: "autoSave") as? Bool ?? true }

    /// Debounced auto-save: ~2s after the last edit, save a titled document.
    private func scheduleAutoSave() {
        guard autoSaveEnabled, let url = currentURL else { return }
        autoSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(to: url) }
        autoSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Restore a snapshot into the current file (snapshots the current state
    /// first, so the restore itself is undoable).
    /// A snapshot looks like clean Markdown (not a polluted/escaped LaTeX dump).
    static func looksLikeCleanMarkdown(_ t: String) -> Bool {
        if t.isEmpty { return false }
        if t.contains("\\textbackslash{}") { return false }   // escaped LaTeX = polluted
        if t.contains("\\documentclass") || t.contains("\\begin{document}") { return false }
        if t.components(separatedBy: "\\section{").count - 1 >= 3 { return false } // a .tex body
        return true
    }

    /// Find the most recent revision that looks like clean Markdown and restore
    /// it (undoable — snapshots the current content first). If editing a `.tex`,
    /// targets the paired `.md` source.
    func restoreLatestCleanMarkdown() {
        guard let cur = currentURL else { statusText = "沒有開啟檔案"; return }
        let target = cur.pathExtension.lowercased() == "md"
            ? cur : VaultModel.markdownURL(root: vaultRoot, forTex: cur)
        let snaps = HistoryStore.list(root: vaultRoot, for: target)
        guard let clean = snaps.first(where: { Self.looksLikeCleanMarkdown(HistoryStore.content($0)) }) else {
            statusText = "找不到乾淨的 Markdown 版本（歷史裡都被污染或無紀錄）"
            return
        }
        if let curText = try? String(contentsOf: target, encoding: .utf8), !curText.isEmpty {
            HistoryStore.snapshot(root: vaultRoot, file: target, content: curText) // make it undoable
        }
        let text = HistoryStore.content(clean)
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            open(target)
            let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
            statusText = "已還原乾淨 Markdown 版本（\(fmt.string(from: clean.date))）"
        } catch {
            statusText = "還原失敗：\(error.localizedDescription)"
        }
    }

    func restoreSnapshot(_ snap: HistoryStore.Snapshot) {
        guard let url = currentURL else { return }
        getContent { [weak self] cur in
            guard let self else { return }
            HistoryStore.snapshot(root: self.vaultRoot, file: url, content: cur)
            let text = HistoryStore.content(snap)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.open(url)
                self.statusText = "已還原版本"
            } catch {
                self.statusText = "還原失敗: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - PDF export

    func exportPDF() {
        guard !isExporting else { return }
        // Pre-compile syntax gate (instant): if there's a definite unbalanced
        // $/$$/{}/\begin, jump to it and skip the doomed Tectonic run. Disable
        // via Settings if it ever blocks a legit compile (e.g. a literal $).
        let check = UserDefaults.standard.object(forKey: "checkBeforeCompile") as? Bool ?? true
        guard check, let webView else { runExport(); return }
        webView.evaluateJavaScript("window.notepro.lintLatex(\(docMode == .latex))") { [weak self] result, _ in
            guard let self else { return }
            if let json = result as? String, let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = arr.first, let line = first["line"] as? Int {
                self.statusText = "⚠ 先修正語法：" + ((first["message"] as? String) ?? "")
                    + (arr.count > 1 ? "（共 \(arr.count) 處）" : "")
                self.errorHint = (first["message"] as? String) ?? ""
                self.errorLine = line
                self.lastCompileError = self.errorHint   // surface the AI 修復 / jump banner
                self.webView?.evaluateJavaScript("window.notepro.scrollToLine(\(line))")
            } else {
                self.runExport()
            }
        }
    }

    private func runExport() {
        if docMode == .latex { exportLatexToPDF() } else { exportMarkdownToPDF() }
    }

    /// Markdown → (web core) LaTeX → Tectonic → PDF.
    private func exportMarkdownToPDF() {
        guard let webView else { return }
        isExporting = true
        statusText = "匯出中… Exporting"
        webView.evaluateJavaScript("window.notepro.toLatex()") { [weak self] result, _ in
            guard let self else { return }
            guard
                let json = result as? String,
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tex = obj["tex"] as? String
            else {
                self.isExporting = false
                self.statusText = "匯出失敗（轉換階段）"
                return
            }
            let converterBib = obj["bib"] as? String ?? ""
            let keys = obj["keys"] as? [String] ?? []
            let name = self.currentURL?.deletingPathExtension().lastPathComponent ?? "note"
            // Auto-generate references.bib from Zotero for the cited keys.
            if !keys.isEmpty { self.statusText = "取得 Zotero 引用…" }
            ZoteroService.exportBib(keys) { [weak self] zbib in
                guard let self else { return }
                let bib = self.mergeLocalLib(zbib.isEmpty ? converterBib : zbib)
                // Write references.bib into the hidden output folder (not the vault).
                if !bib.isEmpty, let src = self.currentURL {
                    let dir = VaultModel.latexOutputDir(root: self.vaultRoot, for: src)
                    try? bib.write(to: dir.appendingPathComponent("references.bib"),
                                   atomically: true, encoding: .utf8)
                }
                PDFExporter.export(tex: tex, bib: bib, name: name,
                                   base: self.currentURL?.deletingLastPathComponent(),
                                   vault: self.vaultRoot) { [weak self] outcome in
                    self?.finishExport(outcome)
                }
            }
        }
    }

    /// A .tex document → Tectonic → PDF. Saves first, then compiles in place.
    private func exportLatexToPDF() {
        isExporting = true
        statusText = "編譯 LaTeX… Compiling"
        getContent { [weak self] text in
            guard let self else { return }
            let prepared = Self.wrapLatexFragment(text)
            let keys = Self.citeKeys(inLatex: prepared)
            let proceed: (String) -> Void = { [weak self] bib in
                guard let self else { return }
                if let url = self.currentURL {
                    try? text.write(to: url, atomically: true, encoding: .utf8) // save the user's raw file
                    let dir = url.deletingLastPathComponent()
                    if !bib.isEmpty {
                        try? bib.write(to: dir.appendingPathComponent("references.bib"),
                                       atomically: true, encoding: .utf8)
                    }
                    PDFExporter.stageImages(tex: prepared, into: dir, base: dir, vault: self.vaultRoot)
                    if prepared == text {
                        // Complete document: compile the real file in place.
                        PDFExporter.compileFile(url) { [weak self] outcome in self?.finishExport(outcome) }
                    } else {
                        // Fragment: compile the wrapped version (don't touch the user's file).
                        PDFExporter.compilePreview(content: prepared, in: dir) { [weak self] outcome in self?.finishExport(outcome) }
                    }
                } else {
                    PDFExporter.export(tex: prepared, bib: bib, name: "note") { [weak self] outcome in
                        self?.finishExport(outcome)
                    }
                }
            }
            if keys.isEmpty { proceed("") } else { ZoteroService.exportBib(keys, completion: proceed) }
        }
    }

    private func finishExport(_ outcome: Result<URL, Error>) {
        isExporting = false
        switch outcome {
        case .success(let pdf):
            statusText = "已匯出 \(pdf.lastPathComponent)"
            lastCompileError = ""; errorLine = nil; errorHint = ""
            NSWorkspace.shared.open(pdf)
        case .failure(let error):
            statusText = "PDF 失敗: \(error.localizedDescription)"
            lastCompileError = error.localizedDescription
            jumpToFirstLintIssue()   // editing-failure → take the cursor to the likely cause
        }
    }

    /// On an explicit compile failure, run the delimiter check and jump the
    /// cursor to the first unbalanced $/{/\begin (the usual cause). No-op if
    /// the document's delimiters are all balanced (then the tectonic error line
    /// banner from `locateError` is the guide instead).
    private func jumpToFirstLintIssue() {
        webView?.evaluateJavaScript("window.notepro.lintLatex()") { [weak self] result, _ in
            guard let self, let json = result as? String, let data = json.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first, let line = first["line"] as? Int else { return }
            self.statusText = (first["message"] as? String).map { "⚠ \($0)" } ?? self.statusText
            self.webView?.evaluateJavaScript("window.notepro.scrollToLine(\(line))")
        }
    }

    // MARK: - Project (multi-file paper)

    /// Compile a project paper: each chapter md → `build/chapters/<name>.tex`, a
    /// master `build/paper.tex` that `\input`s them in order, a shared
    /// `references.bib` (Zotero cited keys, or the project's own), then Tectonic
    /// → `build/paper.pdf`. Also writes `build/paper-flat.tex` (single file).
    func compileProject(_ project: Project) {
        guard let webView else { return }
        let chapters = ProjectsModel.paperChapters(project)
        guard !chapters.isEmpty else { statusText = "專案沒有章節（先把筆記加入論文）"; return }
        var payloadChapters: [[String: String]] = []
        for u in chapters {
            let md = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            payloadChapters.append(["name": u.lastPathComponent, "md": md])
        }
        let payload: [String: Any] = [
            "chapters": payloadChapters,
            "template": project.meta.template,
            "title": project.meta.title,
        ]
        guard let pdata = try? JSONSerialization.data(withJSONObject: payload),
              let pjson = String(data: pdata, encoding: .utf8) else { return }
        isExporting = true
        statusText = "編譯論文中… Building paper"
        webView.evaluateJavaScript("window.notepro.buildProject(\(Self.jsStringLiteral(pjson)))") { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let master = obj["master"] as? String,
                  let chOut = obj["chapters"] as? [[String: String]] else {
                self.isExporting = false; self.statusText = "論文組裝失敗"; return
            }
            let fm = FileManager.default
            let chaptersDir = project.buildDir.appendingPathComponent("chapters", isDirectory: true)
            try? fm.createDirectory(at: chaptersDir, withIntermediateDirectories: true)
            for c in chOut {
                if let name = c["name"], let body = c["body"] {
                    try? body.write(to: chaptersDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
            }
            try? master.write(to: project.paperTex, atomically: true, encoding: .utf8)
            let flat = obj["flat"] as? String ?? ""
            if !flat.isEmpty {
                try? flat.write(to: project.flatTex, atomically: true, encoding: .utf8)
            }
            // Stage referenced images into build/ (found in the project folder, then
            // vault-wide) so `\includegraphics{...}` resolves at compile time.
            PDFExporter.stageImages(tex: flat, into: project.buildDir,
                                    base: project.folder, vault: self.vaultRoot)
            let keys = obj["citationKeys"] as? [String] ?? []
            let finishBib: (String) -> Void = { [weak self] bib in
                guard let self else { return }
                let rootBib = project.folder.appendingPathComponent("references.bib")
                let buildBibURL = project.buildDir.appendingPathComponent("references.bib")
                try? fm.removeItem(at: buildBibURL)
                if project.meta.bib == "manual", fm.fileExists(atPath: rootBib.path) {
                    try? fm.copyItem(at: rootBib, to: buildBibURL)
                } else {
                    let merged = self.mergeLocalLib(bib)   // include vault arXiv/ADS imports
                    if !merged.isEmpty { try? merged.write(to: buildBibURL, atomically: true, encoding: .utf8) }
                }
                PDFExporter.compileFile(project.paperTex) { [weak self] outcome in
                    guard let self else { return }
                    self.isExporting = false
                    switch outcome {
                    case .success(let pdf):
                        self.statusText = "論文已編譯 \(pdf.lastPathComponent)"
                        NSWorkspace.shared.open(pdf)
                    case .failure(let e):
                        self.statusText = "論文編譯失敗：\(e.localizedDescription)"
                    }
                }
            }
            if keys.isEmpty || project.meta.bib == "manual" { finishBib("") }
            else { self.statusText = "取得 Zotero 引用…"; ZoteroService.exportBib(keys, completion: finishBib) }
        }
    }

    /// Export the flattened single-file paper (`paper-flat.tex` + `references.bib`)
    /// to a user-chosen folder, for journal submission.
    /// Pre-submission checks on a compiled project (flat tex + cited bib).
    /// Returns human-readable issues; empty = ready to submit.
    func submissionIssues(_ project: Project) -> [String] {
        guard let tex = try? String(contentsOf: project.flatTex, encoding: .utf8) else {
            return ["尚未編譯（沒有攤平檔）— 先按「編譯論文」"]
        }
        var issues: [String] = []
        func has(_ pattern: String) -> Bool {
            tex.range(of: pattern, options: .regularExpression) != nil
        }
        if !has(#"\\title(\[[^\]]*\])?\{[^}]"#) { issues.append("缺標題：\\title{…} 是空的或不存在") }
        if !has(#"\\author(\[[^\]]*\])?\{[^}]"#) { issues.append("缺作者：\\author{…} 是空的或不存在") }
        if !has(#"\\begin\{abstract\}"#) && !has(#"\\abstract\{"#) {
            issues.append("缺摘要（\\begin{abstract} 或 \\abstract）")
        }
        // Cited keys that aren't in the generated references.bib.
        let bib = (try? String(contentsOf: project.buildDir.appendingPathComponent("references.bib"),
                               encoding: .utf8)) ?? ""
        var bibKeys = Set<String>()
        if let re = try? NSRegularExpression(pattern: #"@\w+\s*\{\s*([^,\s]+)"#) {
            let ns = bib as NSString
            for m in re.matches(in: bib, range: NSRange(location: 0, length: ns.length)) {
                bibKeys.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        if let re = try? NSRegularExpression(pattern: #"\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{([^}]*)\}"#) {
            let ns = tex as NSString
            var missing = Set<String>()
            for m in re.matches(in: tex, range: NSRange(location: 0, length: ns.length)) {
                for part in ns.substring(with: m.range(at: 1)).components(separatedBy: ",") {
                    let key = part.trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty, !bibKeys.contains(key) { missing.insert(key) }
                }
            }
            if !missing.isEmpty {
                issues.append("引用不在 references.bib：\(missing.sorted().joined(separator: ", "))")
            }
        }
        // Figures that don't resolve anywhere in the vault.
        if let re = try? NSRegularExpression(pattern: #"\\includegraphics(?:\[[^\]]*\])?\{([^}]+)\}"#) {
            let ns = tex as NSString
            var missingFigs = Set<String>()
            for m in re.matches(in: tex, range: NSRange(location: 0, length: ns.length)) {
                let ref = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if ImageSchemeHandler.resolve(ref: ref, base: project.folder.path,
                                              vault: vaultRoot?.path ?? "") == nil {
                    missingFigs.insert(ref)
                }
            }
            if !missingFigs.isEmpty {
                issues.append("找不到圖檔：\(missingFigs.sorted().joined(separator: ", "))")
            }
        }
        for marker in ["TODO", "FIXME"] where tex.contains(marker) {
            issues.append("內文還留著 \(marker) 標記")
        }
        return issues
    }

    /// Menu-invoked: run the pre-submission check and show the verdict.
    func checkSubmission(_ project: Project) {
        let issues = submissionIssues(project)
        let alert = NSAlert()
        if issues.isEmpty {
            alert.messageText = "✓ 投稿前檢查通過"
            alert.informativeText = "標題、作者、摘要、引用、圖檔都齊了。可以打包投稿。"
        } else {
            alert.messageText = "投稿前檢查：\(issues.count) 個問題"
            alert.informativeText = issues.map { "• " + $0 }.joined(separator: "\n")
        }
        alert.runModal()
    }

    /// Submission bundle: a self-contained folder with the flattened single
    /// `<name>.tex` (figure paths rewritten to flat basenames), the cited-only
    /// `references.bib`, and every referenced figure copied in. Optionally zipped.
    /// Ready for arXiv / journal upload.
    func exportProjectFlat(_ project: Project) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: project.flatTex.path),
              var tex = try? String(contentsOf: project.flatTex, encoding: .utf8) else {
            statusText = "請先編譯論文（才會產生攤平檔）"; return
        }
        // Pre-flight: surface missing title/abstract/citations/figures before
        // bundling — the human-friendly moment to catch them.
        let issues = submissionIssues(project)
        if !issues.isEmpty {
            let alert = NSAlert()
            alert.messageText = "投稿前檢查發現 \(issues.count) 個問題"
            alert.informativeText = issues.map { "• " + $0 }.joined(separator: "\n")
            alert.addButton(withTitle: "仍要打包")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "建立投稿資料夾於此"
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        // Run the heavy work (figure copies, file writes, ditto zip) off the
        // main thread so the UI doesn't freeze on a multi-MB bundle. Snapshot
        // anything we need from the model before hopping.
        let projectName = project.name
        let projectFolder = project.folder.path
        let projectBuildDir = project.buildDir
        let vaultPath = vaultRoot?.path ?? ""
        statusText = "打包中…"
        DispatchQueue.global(qos: .userInitiated).async {
            var dest = parent.appendingPathComponent("\(projectName) submission", isDirectory: true)
            var n = 1
            while fm.fileExists(atPath: dest.path) { n += 1; dest = parent.appendingPathComponent("\(projectName) submission \(n)", isDirectory: true) }
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

            var figs = 0
            if let re = try? NSRegularExpression(pattern: #"\\includegraphics(\[[^\]]*\])?\{([^}]+)\}"#) {
                let ns = tex as NSString
                var seen = Set<String>()
                for m in re.matches(in: tex, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let ref = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    let base = (ref as NSString).lastPathComponent
                    if !seen.contains(ref) {
                        seen.insert(ref)
                        if let src = ImageSchemeHandler.resolve(ref: ref, base: projectFolder, vault: vaultPath) {
                            let d = dest.appendingPathComponent(base)
                            if !fm.fileExists(atPath: d.path) { try? fm.copyItem(at: src, to: d); figs += 1 }
                        }
                    }
                    let opt = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
                    tex = (tex as NSString).replacingCharacters(in: m.range, with: "\\includegraphics\(opt){\(base)}")
                }
            }
            try? tex.write(to: dest.appendingPathComponent("\(projectName).tex"), atomically: true, encoding: .utf8)

            let bibSrc = projectBuildDir.appendingPathComponent("references.bib")
            if fm.fileExists(atPath: bibSrc.path) {
                try? fm.copyItem(at: bibSrc, to: dest.appendingPathComponent("references.bib"))
            }

            let zip = dest.appendingPathExtension("zip")
            try? fm.removeItem(at: zip)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dest.path, zip.path]
            try? p.run(); p.waitUntilExit()
            let zipped = fm.fileExists(atPath: zip.path)

            DispatchQueue.main.async {
                self.statusText = "已打包投稿檔（tex + bib + \(figs) 張圖\(zipped ? " + zip" : "")）"
                NSWorkspace.shared.activateFileViewerSelecting([zipped ? zip : dest])
            }
        }
    }

    /// Send the LaTeX + last compile error to the local AI, apply the fix, and
    /// recompile. Snapshots first (revert via Version History if the fix is bad).
    func aiFixLatex() {
        guard docMode == .latex, !aiFixing else { return }
        aiFixing = true
        statusText = "AI 修復 LaTeX 中…"
        getContent { [weak self] text in
            guard let self else { return }
            let err = self.lastCompileError.isEmpty ? "（無詳細錯誤訊息，請檢查數學分隔符與括號是否成對）" : self.lastCompileError
            let prompt = """
            你是 LaTeX 專家。下面的 LaTeX 編譯失敗。只修正會導致『編譯失敗』的語法錯誤（例如未配對的 $ 或 $$、缺少的 { }、跑掉的數學模式、應改用 $$…$$ 的多行公式、未跳脫的特殊字元），完整保留所有文字、公式與原意，不要增刪內容、不要改寫。只輸出修正後的完整 LaTeX 原始碼，不要任何解釋、不要 markdown 圍欄。

            編譯錯誤：
            \(err)

            LaTeX：
            \(text)
            """
            AIProvider.shared.complete(prompt: prompt, timeout: 300) { [weak self] result in
                guard let self else { return }
                self.aiFixing = false
                switch result {
                case .failure(let e):
                    self.statusText = "AI 修復失敗：\(e.localizedDescription)"
                case .success(let fixed):
                    let out = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard out.contains("\\"), out.count > 20 else { self.statusText = "AI 未產生有效修正"; return }
                    self.setContent(out)
                    if let url = self.currentURL { self.write(to: url) }   // saves + snapshots
                    self.statusText = "AI 已套用修正 — 重新編譯中（可從版本歷史還原）"
                    if self.latexPreviewVisible { self.scheduleLatexPreview() }
                }
            }
        }
    }

    /// Export the current document's LaTeX source to a .tex file (Markdown is
    /// converted; a .tex document is saved as-is).
    func exportLaTeX() {
        if docMode == .latex { saveAs(); return }
        guard let webView else { return }
        webView.evaluateJavaScript("window.notepro.toLatex()") { [weak self] result, _ in
            guard let self else { return }
            guard
                let json = result as? String,
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tex = obj["tex"] as? String
            else { self.statusText = "匯出 LaTeX 失敗"; return }
            let bib = obj["bib"] as? String ?? ""
            let panel = NSSavePanel()
            panel.allowedContentTypes = Self.texTypes
            panel.nameFieldStringValue = (self.currentURL?.deletingPathExtension().lastPathComponent ?? "note") + ".tex"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try tex.write(to: url, atomically: true, encoding: .utf8)
                if !bib.isEmpty {
                    try bib.write(to: url.deletingLastPathComponent().appendingPathComponent("references.bib"),
                                  atomically: true, encoding: .utf8)
                }
                self.statusText = "已匯出 \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.statusText = "匯出 LaTeX 失敗: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Workflow: Markdown draft → formal LaTeX

    /// Convert the current Markdown to a sibling .tex (in the vault), write
    /// references.bib if cited, and open it for editing — the md→LaTeX workflow.
    func convertToLaTeX(vault: VaultModel) {
        guard docMode == .markdown, let webView else { return }
        vaultRoot = vault.rootURL
        // Persist the Markdown source first, so switching back ("回 Markdown")
        // restores exactly what was converted (otherwise unsaved edits are lost).
        if let url = currentURL, url.pathExtension.lowercased() == "md" { write(to: url) }
        statusText = "轉換為 LaTeX…"
        webView.evaluateJavaScript("window.notepro.toLatex()") { [weak self] result, _ in
            guard let self else { return }
            guard
                let json = result as? String,
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tex = obj["tex"] as? String
            else { self.statusText = "轉換失敗（轉換階段）"; return }
            let converterBib = obj["bib"] as? String ?? ""
            let keys = obj["keys"] as? [String] ?? []
            guard let src = self.currentURL else { self.exportLaTeX(); return }
            // Generated LaTeX goes to the hidden output folder, NOT next to the note.
            let dir = VaultModel.latexOutputDir(root: vault.rootURL, for: src)
            let texURL = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".tex")
            do {
                try tex.write(to: texURL, atomically: true, encoding: .utf8)
            } catch {
                self.statusText = "轉換失敗: \(error.localizedDescription)"
                return
            }
            self.open(texURL) // switches to LaTeX mode — editable right away
            self.statusText = "已轉為 LaTeX（輸出於 .notepro/latex）— 繼續編輯"
            // Fetch the bibliography from Zotero asynchronously.
            self.writeReferencesBib(keys: keys, fallback: converterBib, in: dir)
        }
    }

    /// Quick switch between a Markdown note and its paired `.tex` (⌥⌘L), keeping
    /// the two in sync: whichever side you edited is regenerated into the other
    /// (newest-wins). If you didn't touch the current side, the existing paired
    /// file is opened as-is (so hand-edits on the other side are preserved).
    func toggleMdLatex(vault: VaultModel) {
        vaultRoot = vault.rootURL
        guard let url = currentURL, let webView else {
            if docMode == .markdown { convertToLaTeX(vault: vault) }
            return
        }
        webView.evaluateJavaScript("window.notepro.getContent()") { [weak self] result, _ in
            guard let self else { return }
            let buffer = result as? String ?? ""
            let fm = FileManager.default
            // Persist the current buffer only if it differs from disk (so we don't
            // bump its mtime when nothing changed — that's how we detect edits).
            let onDisk = try? String(contentsOf: url, encoding: .utf8)
            if onDisk == nil || onDisk != buffer {
                try? buffer.write(to: url, atomically: true, encoding: .utf8)
            }
            func mtime(_ u: URL) -> Date {
                ((try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date) ?? .distantPast
            }
            if self.docMode == .markdown {
                let tex = VaultModel.texURL(root: vault.rootURL, for: url)
                if fm.fileExists(atPath: tex.path), mtime(tex) >= mtime(url) {
                    self.open(tex)                      // .md untouched → keep the .tex (your edits)
                } else {
                    self.convertToLaTeX(vault: vault)   // .md is newer (or no .tex) → regenerate it
                }
            } else {
                let md = VaultModel.markdownURL(root: vault.rootURL, forTex: url)
                if fm.fileExists(atPath: md.path) {
                    // A source .md exists → it's the source of truth. Open it as-is;
                    // NEVER lossy-reverse-convert over it (that garbles heavy math /
                    // matrices). Edits made in the .tex stay in the .tex.
                    self.open(md)
                } else {
                    // Hand-authored .tex with no source .md → reverse-convert to import.
                    self.convertToMarkdown(vault: vault)
                }
            }
        }
    }

    /// Reverse the current LaTeX document into Markdown and write the source .md.
    func convertToMarkdown(vault: VaultModel) {
        guard docMode == .latex, let webView, let url = currentURL else { return }
        vaultRoot = vault.rootURL
        if url.pathExtension.lowercased() == "tex" { write(to: url) } // persist .tex first
        let mdURL = VaultModel.markdownURL(root: vault.rootURL, forTex: url)
        statusText = "轉回 Markdown…"
        webView.evaluateJavaScript("window.notepro.fromLatex()") { [weak self] result, _ in
            guard let self else { return }
            guard let md = result as? String else { self.statusText = "轉回 Markdown 失敗"; return }
            do {
                try md.write(to: mdURL, atomically: true, encoding: .utf8)
            } catch {
                self.statusText = "寫入 .md 失敗: \(error.localizedDescription)"
                return
            }
            vault.refresh()
            self.open(mdURL)
            self.statusText = "已更新並切回 \(mdURL.lastPathComponent)"
        }
    }

    /// Fetch cited entries from Zotero (async) and write references.bib into `dir`.
    private func writeReferencesBib(keys: [String], fallback: String, in dir: URL) {
        let target = dir.appendingPathComponent("references.bib")
        guard !keys.isEmpty else {
            let merged = mergeLocalLib(fallback)
            if !merged.isEmpty { try? merged.write(to: target, atomically: true, encoding: .utf8) }
            return
        }
        statusText = "取得 Zotero 引用…"
        ZoteroService.exportBib(keys) { [weak self] zbib in
            guard let self else { return }
            let bib = self.mergeLocalLib(zbib.isEmpty ? fallback : zbib)
            if !bib.isEmpty {
                try? bib.write(to: target, atomically: true, encoding: .utf8)
                self.statusText = "已寫入 references.bib（\(keys.count) 筆引用）"
            } else {
                self.statusText = "⚠ Zotero 未回傳引用（請確認 Zotero 開著）"
            }
        }
    }

    /// Merge the vault's local `references.bib` (arXiv/ADS imports) into a
    /// Zotero-generated bib so imported `[@keys]` resolve at compile. Dedups by key.
    func mergeLocalLib(_ zotero: String) -> String {
        // Snapshot vaultRoot at entry — this can be called from Zotero/ffmpeg
        // background completion handlers, and vaultRoot is non-isolated; read
        // once so a concurrent main-thread reassignment can't tear the URL.
        guard let root = vaultRoot else { return zotero }
        let local = (try? String(contentsOf: root.appendingPathComponent("references.bib"), encoding: .utf8)) ?? ""
        guard !local.isEmpty else { return zotero }
        // (?i) — `@string`/`@comment`/`@preamble` are bib MACROS, not entries;
        // the entry-detection regex would otherwise treat them like cite keys.
        let entryRe = try? NSRegularExpression(pattern: #"@(\w+)\s*\{\s*([^,\s]+)"#)
        let skipTypes: Set<String> = ["string", "comment", "preamble"]
        func keys(_ s: String) -> Set<String> {
            guard let entryRe else { return [] }
            let ns = s as NSString
            var out = Set<String>()
            for m in entryRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let type = ns.substring(with: m.range(at: 1)).lowercased()
                if skipTypes.contains(type) { continue }
                out.insert(ns.substring(with: m.range(at: 2)))
            }
            return out
        }
        var have = keys(zotero)
        var out = zotero
        for part in ("\n" + local).components(separatedBy: "\n@").dropFirst() {
            let entry = "@" + part
            guard let entryRe,
                  let m = entryRe.firstMatch(in: entry, range: NSRange(location: 0, length: (entry as NSString).length)),
                  let typeR = Range(m.range(at: 1), in: entry),
                  let keyR = Range(m.range(at: 2), in: entry) else { continue }
            let type = String(entry[typeR]).lowercased()
            // Don't dedup macros by their type name (would block real entries
            // with the same key as the macro type), but DO include them — the
            // bibtex parser needs @string definitions before any entry uses them.
            if skipTypes.contains(type) {
                out += "\n" + entry.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                continue
            }
            let k = String(entry[keyR])
            if !have.contains(k) { have.insert(k); out += "\n" + entry.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
        }
        return out
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while fm.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
        }
        return url
    }

    // MARK: - Helpers

    private static let markdownTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        return types
    }()

    private static let texTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        if let tex = UTType(filenameExtension: "tex") { types.insert(tex, at: 0) }
        return types
    }()

    private static func jsStringLiteral(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arrayLiteral = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arrayLiteral.dropFirst().dropLast())
    }
}

// MARK: - Focused value (lets menu commands reach the focused window's editor)

struct EditorModelKey: FocusedValueKey {
    typealias Value = EditorModel
}

extension FocusedValues {
    var editorModel: EditorModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }
}
