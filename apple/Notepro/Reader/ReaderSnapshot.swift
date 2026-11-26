import SwiftUI
import AppKit
import PDFKit

/// `Nebula --reader-snapshot <out-dir>`: builds the real reader window off
/// screen, drives it through a few states (tabs, annotations, dark mode,
/// thumbnails + find, a new highlight) and writes a PNG of each, so the UI
/// can be checked without anyone clicking. Reads the library at
/// `$NEBULA_LIBRARY` (point it at a copy); run it from a separate build if
/// the user's own Nebula settings must stay untouched.
@MainActor
enum ReaderSnapshot {

    static func run() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--reader-snapshot"), i + 1 < args.count else {
            print("usage: Nebula --reader-snapshot <out-dir>"); exit(2)
        }
        let out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let session = ReaderSession.shared
        let papers = session.store.allPapers().filter { $0.meta.pdf != nil }
        print("library \(session.store.root.path): \(papers.count) papers with a PDF")
        for t in session.tabs { session.close(t.id) }

        let ctrl = ReaderController()
        let root = ReaderWindowView(controller: ctrl).environmentObject(VaultModel())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: root)
        window.setFrameOrigin(CGPoint(x: -4000, y: -4000))   // off screen
        window.orderBack(nil)

        func pump(_ s: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func shot(_ name: String) {
            pump()
            guard let v = window.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            // PDFView draws in tiled layers that an off-screen cache does not
            // capture, so the page it is showing is rendered separately.
            var pageInfo = "no page"
            if let pv = ctrl.pdfView, let page = pv.currentPage, let doc = pv.document {
                let b = page.bounds(for: .cropBox)
                let img = NSImage(size: b.size, flipped: false) { _ in
                    NSColor.white.setFill(); NSRect(origin: .zero, size: b.size).fill()
                    guard let cg = NSGraphicsContext.current?.cgContext else { return true }
                    cg.translateBy(x: -b.minX, y: -b.minY)
                    page.draw(with: .cropBox, to: cg)
                    return true
                }
                if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                    try? r.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-page.png"))
                }
                pageInfo = "page \(doc.index(for: page) + 1)/\(doc.pageCount), \(page.annotations.count) annotations on it, scale \(String(format: "%.2f", pv.scaleFactor))"
            }
            print("wrote \(name).png — \(pageInfo) — tabs \(session.tabs.count), live \(session.tabs.filter { session.isLive($0.id) }.count), rows \(ctrl.rows.count), find \(ctrl.findResults.count), status \"\(ctrl.status)\"")
        }

        shot("0-empty")
        // Open up to three papers, the most-annotated one last (active).
        let ordered = papers.sorted { annCount($0.folder, session.store) < annCount($1.folder, session.store) }
        for p in ordered.suffix(3) { session.openFolder(p.folder) }
        ctrl.sidebar = .annotations
        shot("1-tabs-annotations")

        ctrl.toggleDark()
        shot("2-dark")
        ctrl.toggleDark()

        ctrl.sidebar = .thumbnails
        ctrl.findQuery = "the"
        pump(0.2)            // let the field's change handler run first, as typing would
        ctrl.runFind()
        shot("3-thumbnails-find")

        ctrl.sidebar = .outline
        shot("4-outline")

        // A new highlight on the first find result, with a comment.
        if let pv = ctrl.pdfView, let sel = ctrl.findResults.first {
            ctrl.clearFind()
            pv.setCurrentSelection(sel, animate: false)
            ctrl.highlightHex = "#5fb236"
            ctrl.highlight()
            if let r = ctrl.rows.first(where: { $0.id.hasPrefix("n:") }) { ctrl.setComment("snapshot test", id: r.id) }
        }
        ctrl.sidebar = .annotations
        shot("5-new-highlight")

        session.selectNext(-1)
        shot("6-switched-tab")

        // Back to the most-annotated paper with the chat open; any
        // suggestions.json in its folder shows as pending Claude rows.
        let lastFolder = ordered.last?.folder ?? ""
        if let t = session.tabs.first(where: { $0.folder == lastFolder }) { session.select(t.id) }
        ctrl.showChat = true
        ctrl.sidebar = .annotations
        pump(1.5)
        let pending = ctrl.rows.filter { $0.id.hasPrefix("s:") }
        print("chat available \(ctrl.chatAvailable), bound to \(ctrl.chat.paper?.citekey ?? "none"); pending suggestions \(pending.count)")
        shot("7-chat-suggestions")
        if let first = pending.first {
            ctrl.acceptSuggestion(first.id)
            if let second = pending.dropFirst().first { ctrl.rejectSuggestion(second.id) }
            print("after accept/reject: pending \(ctrl.rows.filter { $0.id.hasPrefix("s:") }.count), accepted rows \(ctrl.rows.filter { $0.id.hasPrefix("c:") }.count)")
        }
        session.openLink(URL(string: "nebula://paper/\(lastFolder)?page=1&quote=dominated%20by%20protostellar%20feedback")!)
        pump(0.8)
        print("link opened: page \((ctrl.pdfView?.currentPage).flatMap { ctrl.pdfView?.document?.index(for: $0) }.map { $0 + 1 } ?? 0), selection \"\(ctrl.pdfView?.currentSelection?.string ?? "")\"")

        ctrl.detachCurrent(); session.saveAll()
        exit(0)
    }

    private static func annCount(_ folder: String, _ store: PaperLibraryStore) -> Int {
        (store.read([LibraryAnnotation].self, from: store.folder(folder).appendingPathComponent("annotations.json")) ?? []).count
    }
}
