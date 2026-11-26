import SwiftUI
import PDFKit
import AppKit
import Combine

/// Drives the reader window's one PDFView: attaches the active tab's
/// document, remembers positions, find, annotations, capture and keys.
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
    @Published var showQuickOpen = false

    // Find
    @Published var findQuery = ""
    @Published private(set) var findResults: [PDFSelection] = []
    @Published private(set) var findIndex = 0

    struct OutlineRow: Identifiable { let id = UUID(); let label: String; let depth: Int; let page: Int }

    private var attachedID: UUID?
    private var bag = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var saveTimer: Timer?

    init() {
        session.$generation.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.attach() }.store(in: &bag)
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
        pv.document = doc
        pv.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        let pos = tab.position
        if pos.scale > 0 { pv.autoScales = false; pv.scaleFactor = pos.scale } else { pv.autoScales = true }
        if let page = doc.page(at: min(pos.page, max(doc.pageCount - 1, 0))) {
            let point = (pos.x == 0 && pos.y == 0) ? CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)
                                                   : CGPoint(x: pos.x, y: pos.y)
            DispatchQueue.main.async { pv.go(to: PDFDestination(page: page, at: point)) }
        }
        clearFind()
        refreshRows()
        outline = Self.flatten(doc.outlineRoot, depth: 0, doc: doc)
        status = tab.folder.map { "Library: \($0)" } ?? tab.url.lastPathComponent
        pv.window?.title = tab.title
    }

    /// Store the outgoing tab's position and annotations.
    func detachCurrent() {
        guard let id = attachedID, let pv = pdfView, let doc = pv.document,
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
        guard let id = attachedID, let pv = pdfView else { return }
        session.updatePosition(id, currentPosition(pv))
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

    /// ⌘W closes the tab (the window when none are left), ⌘⇧T reopens,
    /// ⌃Tab / ⌃⇧Tab switch, ⌘T opens a paper, ⌘F finds, ⌘G next match.
    func installKeys(window: NSWindow) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] e in
            guard let self, let window, e.window === window else { return e }
            let mods = e.modifierFlags.intersection([.command, .shift, .control, .option])
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            switch (mods, ch) {
            case ([.command], "w"):
                if let a = self.session.activeID { self.detachCurrent(); self.attachedID = nil; self.session.close(a) }
                if self.session.tabs.isEmpty { window.performClose(nil) }
                return nil
            case ([.command, .shift], "t"): self.session.reopenClosed(); return nil
            case ([.command], "t"): self.showQuickOpen = true; return nil
            case ([.control], "\t"): self.session.selectNext(1); return nil
            case ([.control, .shift], "\t"): self.session.selectNext(-1); return nil
            case ([.command], "g"): self.findStep(1); return nil
            case ([.command, .shift], "g"): self.findStep(-1); return nil
            case ([.command], "e"): self.highlight(); return nil
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
