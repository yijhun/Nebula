import SwiftUI
import PDFKit
import AppKit
import Combine

/// Drives the reader window's one PDFView: attaches the active tab's
/// document, remembers positions, find, annotations, capture, keys, and the
/// chat about the open paper.
@MainActor
final class ReaderController: ObservableObject {
    let session = ReaderSession.shared
    weak var pdfView: ReaderPDFView? { didSet { if pdfView != nil { attach() } } }
    weak var vault: VaultModel?

    enum SidebarMode: String, CaseIterable { case thumbnails, outline, annotations }

    @Published var sidebar: SidebarMode = .annotations
    @Published var showSidebar = true
    @Published var highlightHex = UserDefaults.standard.string(forKey: "readerHighlight") ?? "#ffd400" {
        didSet { UserDefaults.standard.set(highlightHex, forKey: "readerHighlight") }
    }
    @Published var noteMode = false
    @Published var captureMode = false
    @Published var dark = ReaderPage.dark
    @Published var twoUp = false
    @Published var status = ""
    @Published var rows: [ReaderAnnotations.Row] = []
    @Published var outline: [OutlineRow] = []
    /// Bumped to put the cursor in the library tab's search field (⌘T).
    @Published var focusLibrarySearch = 0
    // The library tab's view state, kept here so it survives switching to a
    // paper and back.
    @Published var librarySource: LibrarySource? = .all {
        didSet {
            guard librarySource != oldValue else { return }
            librarySelection = []; libraryFileSelection = []
            // Recently Opened lists the latest first.
            if librarySource == .recent { librarySort = [KeyPathComparator(\LibraryEntry.lastOpened, order: .reverse)] }
        }
    }
    @Published var libraryQuery = ""
    @Published var librarySelection = Set<String>()
    @Published var libraryFileSelection = Set<String>()
    @Published var librarySort = [KeyPathComparator(\LibraryEntry.added, order: .reverse)]
    @Published var showChat = UserDefaults.standard.bool(forKey: "readerShowChat") {
        didSet { UserDefaults.standard.set(showChat, forKey: "readerShowChat"); if showChat { bindChat() } }
    }

    /// The reader's own conversation, bound to the active library paper. It
    /// starts a CLI only when a message is sent (PAPER-LIBRARY.md §10).
    let chat = ChatController()

    // Find
    @Published var findQuery = ""
    @Published private(set) var findResults: [PDFSelection] = []
    @Published private(set) var findIndex = 0

    struct OutlineRow: Identifiable { let id = UUID(); let label: String; let depth: Int; let page: Int }

    private var attachedID: UUID?
    /// The tab whose saved position is still being restored (see attach).
    private var restoringID: UUID?
    private var bag = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private weak var window: NSWindow?
    private var saveTimer: Timer?

    init() {
        session.$generation.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.attach() }.store(in: &bag)
        // Going to the library tab keeps the paper attached (hidden), so
        // coming back is instant; its position and annotations are saved now.
        session.$showLibrary.removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                if on {
                    self.detachCurrent()
                    self.session.library.reload()   // last opened, pages, annotation counts
                    self.window?.makeFirstResponder(nil)
                    self.showTitle(nil)
                } else if let t = self.session.active {
                    self.showTitle(t)
                }
            }.store(in: &bag)
        session.$pendingGoto.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPendingGoto() }.store(in: &bag)
        chat.readerState = { [weak self] in
            guard let self, let pv = self.pdfView, let doc = pv.document, let page = pv.currentPage else { return (0, "") }
            let sel = pv.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (doc.index(for: page) + 1, String(sel.prefix(4000)))
        }
        chat.onPaperLink = { [weak self] url in self?.session.openLink(url) }
        chat.onToNote = { [weak self] text in
            let key = self?.session.active?.folder.flatMap { self?.session.store.meta(folder: $0)?.citekey } ?? ""
            NotificationCenter.default.post(name: .noteproInsertIntoNote, object: nil,
                                            userInfo: ["text": "\n\(text)\(key.isEmpty ? "" : " [@\(key)]")\n"])
            self?.status = LZ("已送進筆記")
        }
        chat.onTurnEnd = { [weak self] in self?.loadSuggestions() }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.detachCurrent(); self?.session.saveAll() }.store(in: &bag)
    }

    deinit { if let m = keyMonitor { NSEvent.removeMonitor(m) } }

    // MARK: attach / detach

    func attach() {
        guard let pv = pdfView else { return }
        if attachedID == session.activeID, pv.document != nil { return }
        detachCurrent()
        guard let id = session.activeID, let doc = session.document(for: id),
              let tab = session.active else {
            pv.document = nil; attachedID = nil; rows = []; outline = []; return
        }
        attachedID = id
        // Until the saved page is back, the view reports page 1: that is not
        // the reader's position, and must not mark the paper opened.
        restoringID = id
        pv.document = doc
        pv.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        let pos = tab.position
        if pos.scale > 0 { pv.autoScales = false; pv.scaleFactor = pos.scale } else { pv.autoScales = true }
        if let page = doc.page(at: min(pos.page, max(doc.pageCount - 1, 0))) {
            let point = (pos.x == 0 && pos.y == 0) ? CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)
                                                   : CGPoint(x: pos.x, y: pos.y)
            DispatchQueue.main.async { [weak self] in
                pv.go(to: PDFDestination(page: page, at: point))
                DispatchQueue.main.async { if self?.restoringID == id { self?.restoringID = nil } }
            }
        } else {
            restoringID = nil
        }
        clearFind()
        loadSuggestions()
        refreshRows()
        outline = Self.flatten(doc.outlineRoot, depth: 0, doc: doc)
        if showChat { bindChat() }
        applyPendingGoto()
        status = tab.folder.map { "Library: \($0)" } ?? tab.url.lastPathComponent
        if !session.showLibrary { showTitle(tab) }
    }

    /// The window's title bar: the paper's title, its citekey underneath.
    func showTitle(_ tab: ReaderTab?) {
        guard let window else { return }
        guard let tab else { window.title = LZ("論文庫"); window.subtitle = ""; return }
        if let f = tab.folder, let m = session.store.meta(folder: f), !m.title.isEmpty {
            window.title = m.title
            window.subtitle = m.citekey
        } else {
            window.title = tab.title; window.subtitle = ""
        }
    }

    /// Store the outgoing tab's position and annotations.
    func detachCurrent() {
        guard let id = attachedID, id != restoringID, let pv = pdfView, let doc = pv.document,
              let tab = session.tabs.first(where: { $0.id == id }) else { return }
        session.updatePosition(id, currentPosition(pv))
        session.saveAnnotations(tab: tab, document: doc)
    }

    func currentPosition(_ pv: PDFView) -> ReaderPosition {
        guard let dest = pv.currentDestination, let page = dest.page, let doc = pv.document else { return ReaderPosition() }
        return ReaderPosition(page: doc.index(for: page), x: Double(dest.point.x), y: Double(dest.point.y),
                              scale: pv.autoScales ? 0 : Double(pv.scaleFactor))
    }

    /// Called as the user scrolls: keep the position, cheaply.
    func pageChanged() {
        guard let id = attachedID, id != restoringID, let pv = pdfView else { return }
        session.updatePosition(id, currentPosition(pv))
    }

    // MARK: chat

    /// Point the chat at the active tab's paper (library papers only).
    func bindChat() {
        guard let tab = session.active, let f = tab.folder, let m = session.store.meta(folder: f) else {
            chat.setPaper(nil); return
        }
        chat.setPaper(.init(folder: session.store.folder(f), citekey: m.citekey, title: m.title))
    }

    var chatAvailable: Bool { session.active?.folder != nil }

    func briefMe() {
        showChat = true
        chat.submit(LZ("導讀這篇：三行摘要、最重要的 2–3 張圖（附頁碼連結），以及它和我其他論文的關係（如果找得到）。"))
    }

    func suggestHighlights(wholePaper: Bool) {
        showChat = true
        let page = (pdfView?.currentPage).flatMap { p in pdfView?.document?.index(for: p) }.map { $0 + 1 } ?? 1
        let scope = wholePaper ? LZ("整篇論文") : String(format: LZ("第 %d 頁"), page)
        chat.submit(String(format: LZ("幫我建議重點，範圍：%@。類別：Result、Numbers、Data & Method、Caveat、Relevant to me。用 reader_suggest_highlights，最多 8 個，理由用英文。"), scope))
    }

    // MARK: going to a place

    func applyPendingGoto() {
        guard let g = session.pendingGoto, g.tab == session.activeID, attachedID == g.tab,
              let pv = pdfView, let doc = pv.document, let page = doc.page(at: g.page) else { return }
        session.pendingGoto = nil
        if let q = g.quote, let rects = ReaderMCPTools.locate(q, on: page, in: doc), let r = rects.first {
            let sel = doc.findString(q, withOptions: .caseInsensitive).first { $0.pages.contains(page) }
            pv.go(to: PDFDestination(page: page, at: CGPoint(x: r[0], y: r[3] + 60)))
            if let sel { pv.setCurrentSelection(sel, animate: true) }
        } else {
            pv.go(to: page)
        }
    }

    // MARK: suggested highlights (from Claude)

    private var suggestionsURL: URL? {
        session.active?.folder.map { session.store.folder($0).appendingPathComponent("suggestions.json") }
    }

    /// Show suggestions.json as pending, dashed highlights (ids "s:…").
    func loadSuggestions() {
        guard let url = suggestionsURL, let doc = pdfView?.document else { return }
        let sugg = session.store.read([LibraryAnnotation].self, from: url) ?? []
        var shown = Set<String>()
        for i in 0..<doc.pageCount {
            for p in doc.page(at: i)?.annotations ?? [] {
                if let id = p.value(forAnnotationKey: ReaderAnnotations.idKey) as? String, id.hasPrefix("s:") { shown.insert(id) }
            }
        }
        for s in sugg where !shown.contains(s.id) { ReaderAnnotations.add(s, to: doc) }
        if sugg.contains(where: { !shown.contains($0.id) }) {
            sidebar = .annotations; showSidebar = true
            status = String(format: LZ("Claude 建議了 %d 個重點，請逐一確認"), sugg.count)
        }
        refreshRows()
    }

    func acceptSuggestion(_ id: String) {
        guard let doc = pdfView?.document else { return }
        let newID = "c:" + id.dropFirst(2)
        for (_, p) in ReaderAnnotations.parts(id: id, in: doc) {
            p.setValue(newID, forAnnotationKey: ReaderAnnotations.idKey)
            p.border = nil                                  // no longer dashed: accepted
        }
        ReaderAnnotations.markDirty(doc)
        session.saveActive()        // keeps Claude's exact quote and reason
        dropSuggestion(id)
        refreshRows()
    }

    func rejectSuggestion(_ id: String) {
        guard let doc = pdfView?.document else { return }
        for (page, p) in ReaderAnnotations.parts(id: id, in: doc) { page.removeAnnotation(p) }
        dropSuggestion(id)
        refreshRows()
    }

    private func dropSuggestion(_ id: String) {
        guard let url = suggestionsURL else { return }
        let rest = (session.store.read([LibraryAnnotation].self, from: url) ?? []).filter { $0.id != id }
        try? session.store.write(rest, to: url)
    }

    // MARK: annotations

    func annotationsChanged() {
        refreshRows()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.session.saveActive() }
    }

    func refreshRows() {
        rows = pdfView?.document.map(ReaderAnnotations.rows) ?? []
    }

    func highlight() {
        guard let pv = pdfView else { return }
        if ReaderAnnotations.highlightSelection(in: pv, hex: highlightHex) { annotationsChanged() }
        else { status = LZ("先選取文字再標記") }
    }

    func setComment(_ c: String, id: String) {
        guard let d = pdfView?.document else { return }
        ReaderAnnotations.setComment(c, id: id, in: d); annotationsChanged()
    }

    func setColor(_ hex: String, id: String) {
        guard let d = pdfView?.document else { return }
        ReaderAnnotations.setColor(hex, id: id, in: d); annotationsChanged()
    }

    func delete(id: String) {
        guard let d = pdfView?.document else { return }
        ReaderAnnotations.remove(id: id, in: d); annotationsChanged()
    }

    func jump(toAnnotation id: String) {
        guard let pv = pdfView, let d = pv.document,
              let (page, a) = ReaderAnnotations.parts(id: id, in: d).first else { return }
        pv.go(to: PDFDestination(page: page, at: CGPoint(x: a.bounds.minX, y: a.bounds.maxY + 40)))
    }

    func jump(toPage i: Int) {
        guard let pv = pdfView, let page = pv.document?.page(at: i) else { return }
        pv.go(to: page)
    }

    func noteClicked(page: PDFPage, point: CGPoint) {
        guard let d = pdfView?.document else { return }
        ReaderAnnotations.addNote(on: page, at: point, doc: d)
        noteMode = false
        sidebar = .annotations; showSidebar = true
        annotationsChanged()
    }

    // MARK: find

    func runFind() {
        guard let pv = pdfView, let doc = pv.document else { return }
        let q = findQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearFind(); return }
        findResults = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for s in findResults { s.color = NSColor.systemOrange.withAlphaComponent(0.5) }
        pv.highlightedSelections = findResults
        findIndex = 0
        showFindResult()
    }

    func findStep(_ d: Int) {
        guard !findResults.isEmpty else { runFind(); return }
        findIndex = (findIndex + d + findResults.count) % findResults.count
        showFindResult()
    }

    private func showFindResult() {
        guard let pv = pdfView, findResults.indices.contains(findIndex) else { return }
        let s = findResults[findIndex]
        pv.setCurrentSelection(s, animate: false)
        pv.go(to: s)
    }

    func clearFind() {
        findResults = []; findIndex = 0
        pdfView?.highlightedSelections = nil
    }

    // MARK: view options

    func toggleDark() {
        dark.toggle()
        ReaderPage.dark = dark
        UserDefaults.standard.set(dark, forKey: "readerDark")
        // Pages cache their tiles; re-attaching the document redraws them.
        if let pv = pdfView, let doc = pv.document {
            let dest = pv.currentDestination
            pv.document = nil; pv.document = doc
            if let dest { pv.go(to: dest) }
        }
    }

    func setTwoUp(_ on: Bool) {
        twoUp = on
        pdfView?.displayMode = on ? .twoUpContinuous : .singlePageContinuous
    }

    func zoom(_ d: Int) {
        guard let pv = pdfView else { return }
        if d == 0 { pv.autoScales = true } else { pv.autoScales = false; d > 0 ? pv.zoomIn(nil) : pv.zoomOut(nil) }
        pageChanged()
    }

    // MARK: capture (figure → note + Keynote clipboard)

    func capture(_ viewRect: CGRect) {
        guard let pv = pdfView, let doc = pv.document,
              let page = pv.page(for: CGPoint(x: viewRect.midX, y: viewRect.midY), nearest: true) else { return }
        let pageRect = pv.convert(viewRect, to: page)
        guard pageRect.width > 8, pageRect.height > 8,
              let data = FigureClipboard.croppedPDF(page: page, rect: pageRect) else { status = LZ("框選範圍太小"); return }
        let key = session.active?.folder.flatMap { session.store.meta(folder: $0)?.citekey } ?? ""
        let pageNo = doc.index(for: page) + 1
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let base = "fig-\(key.isEmpty ? (session.active?.title ?? "paper") : key)-\(fmt.string(from: Date()))"
        FigureClipboard.copy(data, name: base)
        if let root = vault?.rootURL {
            let folder = (UserDefaults.standard.string(forKey: "attachmentFolder") ?? "Assets").trimmingCharacters(in: .whitespaces)
            let dir = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pdfURL = dir.appendingPathComponent("\(base).pdf"), pngURL = dir.appendingPathComponent("\(base).png")
            try? data.write(to: pdfURL)
            if let clip = PDFDocument(data: data)?.page(at: 0) {
                let img = clip.thumbnail(of: CGSize(width: pageRect.width * 2, height: pageRect.height * 2), for: .cropBox)
                if let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: pngURL)
                }
            }
            let src = key.isEmpty ? (session.active?.url.lastPathComponent ?? "") : "[@\(key)]"
            NotificationCenter.default.post(name: .noteproInsertIntoNote, object: nil,
                                            userInfo: ["text": "\n![[\(pngURL.lastPathComponent)]]\n*Figure from \(src), p. \(pageNo)*\n"])
            vault?.refresh()
        }
        status = LZ("已複製 PDF，可直接貼進 Keynote")
    }

    // MARK: keys

    /// Show the library tab with the cursor in its search field.
    func openLibrarySearch() {
        session.showLibrary = true
        focusLibrarySearch += 1
    }

    /// ⌘W closes the paper tab (never the library tab), ⌘⇧T reopens,
    /// ⌃Tab / ⌃⇧Tab switch (library tab included), ⌘T searches the library,
    /// ⌘F finds, ⌘G next match. Paper keys do nothing on the library tab.
    func installKeys(window: NSWindow) {
        self.window = window
        showTitle(session.showLibrary ? nil : session.active)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] e in
            guard let self, let window, e.window === window else { return e }
            let mods = e.modifierFlags.intersection([.command, .shift, .control, .option])
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            let library = self.session.showLibrary
            switch (mods, ch) {
            case ([.command], "w"):
                // The library tab never closes; with no papers open ⌘W closes the window.
                if library { if self.session.tabs.isEmpty { window.performClose(nil) }; return nil }
                if let a = self.session.activeID { self.detachCurrent(); self.attachedID = nil; self.session.close(a) }
                return nil
            case ([.command, .shift], "t"): self.session.reopenClosed(); return nil
            case ([.command], "t"): self.openLibrarySearch(); return nil
            case ([.control], "\t"): self.session.selectNext(1); return nil
            case ([.control, .shift], "\t"): self.session.selectNext(-1); return nil
            case ([.command], "g") where !library: self.findStep(1); return nil
            case ([.command, .shift], "g") where !library: self.findStep(-1); return nil
            case ([.command], "e") where !library: self.highlight(); return nil
            case ([.command, .option], "i") where !library: self.showChat.toggle(); return nil
            default: return e
            }
        }
    }

    // MARK: outline

    static func flatten(_ node: PDFOutline?, depth: Int, doc: PDFDocument) -> [OutlineRow] {
        guard let node else { return [] }
        var out: [OutlineRow] = []
        for i in 0..<node.numberOfChildren {
            guard let c = node.child(at: i) else { continue }
            let page = c.destination?.page.map { doc.index(for: $0) } ?? 0
            out.append(OutlineRow(label: c.label ?? "", depth: depth, page: page))
            if depth < 3 { out += flatten(c, depth: depth + 1, doc: doc) }
        }
        return out
    }
}

/// The reader's PDFView: capture and note modes on top of normal reading.
final class ReaderPDFView: CapturePDFView {
    var noteActive: () -> Bool = { false }
    var onNote: ((PDFPage, CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if noteActive() {
            let p = convert(event.locationInWindow, from: nil)
            if let page = page(for: p, nearest: true) { onNote?(page, convert(p, to: page)) }
            return
        }
        super.mouseDown(with: event)
    }
}
