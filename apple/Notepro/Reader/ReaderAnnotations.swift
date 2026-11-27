import Foundation
import PDFKit
import AppKit

/// Moves annotations between a library paper's `annotations.json` and the
/// PDFAnnotations shown in the reader. The PDF file itself is never written
/// for library papers: annotations live only in the sidecar.
enum ReaderAnnotations {

    static let idKey = PDFAnnotationKey(rawValue: "/NebulaID")
    static let authorKey = PDFAnnotationKey(rawValue: "/NebulaAuthor")
    private static let dirtyKey = "nebulaDirty"

    /// Zotero's default palette (keeps imported colours meaningful).
    static let palette: [(name: String, hex: String)] = [
        ("Yellow", "#ffd400"), ("Red", "#ff6666"), ("Green", "#5fb236"),
        ("Blue", "#2ea8e5"), ("Purple", "#a28ae5"),
    ]

    // MARK: dirty tracking (per document)

    private static var dirtyDocs = Set<ObjectIdentifier>()
    static func markDirty(_ d: PDFDocument) { dirtyDocs.insert(ObjectIdentifier(d)) }
    static func markClean(_ d: PDFDocument) { dirtyDocs.remove(ObjectIdentifier(d)) }
    static func dirty(_ d: PDFDocument) -> Bool { dirtyDocs.contains(ObjectIdentifier(d)) }

    // MARK: load

    static func load(into doc: PDFDocument, folder: String, store: PaperLibraryStore) {
        let anns = store.read([LibraryAnnotation].self,
                              from: store.folder(folder).appendingPathComponent("annotations.json")) ?? []
        for a in anns { add(a, to: doc) }
        let figs = store.read([LibraryFigure].self,
                              from: store.folder(folder).appendingPathComponent("figures.json")) ?? []
        var regions: [Int: [CGRect]] = [:]
        for f in figs where f.rect.count == 4 {
            regions[f.page, default: []].append(CGRect(x: f.rect[0], y: f.rect[1],
                                                       width: f.rect[2] - f.rect[0], height: f.rect[3] - f.rect[1]))
        }
        ReaderPage.setFigures(regions, for: doc)
        markClean(doc)
    }

    /// One LibraryAnnotation → one PDFAnnotation per rect (highlight) or path set (ink).
    static func add(_ a: LibraryAnnotation, to doc: PDFDocument) {
        guard let page = doc.page(at: a.page) else { return }
        let color = NSColor(hex: a.color) ?? .systemYellow
        func tag(_ p: PDFAnnotation) {
            p.setValue(a.id, forAnnotationKey: idKey)
            p.setValue(a.author, forAnnotationKey: authorKey)
            if !a.comment.isEmpty { p.contents = a.comment }
            page.addAnnotation(p)
        }
        switch a.kind {
        case .highlight:
            for r in a.rects ?? [] where r.count == 4 {
                let p = PDFAnnotation(bounds: rect(r), forType: .highlight, withProperties: nil)
                p.color = color.withAlphaComponent(0.45)
                if a.author == "claude" {
                    let b = PDFBorder(); b.style = .dashed; b.lineWidth = 1; b.dashPattern = [3, 2]
                    p.border = b
                }
                tag(p)
            }
        case .note:
            guard let r = a.rects?.first, r.count == 4 else { return }
            let p = PDFAnnotation(bounds: CGRect(x: r[0], y: r[1], width: 20, height: 20), forType: .text, withProperties: nil)
            p.color = color
            p.iconType = .comment
            tag(p)
        case .ink:
            let all = (a.paths ?? []).flatMap { path in stride(from: 0, to: path.count - 1, by: 2).map { i in CGPoint(x: path[i], y: path[i + 1]) } }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
                  let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return }
            let w = a.width ?? 1
            let bounds = CGRect(x: minX - w, y: minY - w, width: maxX - minX + 2 * w, height: maxY - minY + 2 * w)
            let p = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            p.color = color
            let border = PDFBorder(); border.lineWidth = w; p.border = border
            for path in a.paths ?? [] where path.count >= 4 {
                let bp = NSBezierPath()
                bp.move(to: CGPoint(x: path[0] - bounds.minX, y: path[1] - bounds.minY))
                for i in stride(from: 2, to: path.count - 1, by: 2) {
                    bp.line(to: CGPoint(x: path[i] - bounds.minX, y: path[i + 1] - bounds.minY))
                }
                p.add(bp)
            }
            tag(p)
        }
    }

    // MARK: save

    /// Collect the reader's annotations back into annotations.json, keeping
    /// the stored order, timestamps and anything the reader does not show.
    static func save(from doc: PDFDocument, folder: String, store: PaperLibraryStore) {
        guard dirty(doc) else { return }
        let url = store.folder(folder).appendingPathComponent("annotations.json")
        let stored = store.read([LibraryAnnotation].self, from: url) ?? []
        var byID: [String: LibraryAnnotation] = [:]
        var order: [String] = []
        var created = Set<String>()      // new in the reader: rects collected from every line
        let suggested = Dictionary((store.read([LibraryAnnotation].self,
                                               from: store.folder(folder).appendingPathComponent("suggestions.json")) ?? [])
                                    .map { ("c:" + $0.id.dropFirst(2), $0) }, uniquingKeysWith: { a, _ in a })
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for p in page.annotations {
                guard let kind = kind(of: p) else { continue }
                let id = (p.value(forAnnotationKey: idKey) as? String) ?? newID(for: p)
                if id.hasPrefix("s:") { continue }     // a suggestion, not yet accepted
                // The reader never moves an annotation, so a stored one keeps its
                // exact geometry and text (Zotero's text is better than a re-read
                // of the page); only its comment and colour can change here.
                if !created.contains(id), let old = byID[id] ?? stored.first(where: { $0.id == id })
                    ?? suggested[id].map({ var a = $0; a.id = id; return a }) {
                    var a = old
                    a.comment = p.contents ?? ""
                    a.color = p.color.withAlphaComponent(1).hexString
                    if byID[id] == nil { order.append(id) }
                    byID[id] = a
                    continue
                }
                var a = byID[id] ?? LibraryAnnotation(
                    id: id, kind: kind, page: i, color: p.color.withAlphaComponent(1).hexString,
                    comment: p.contents ?? "",
                    author: (p.value(forAnnotationKey: authorKey) as? String) ?? "user",
                    created: ISO8601DateFormatter().string(from: Date()))
                created.insert(id)
                switch kind {
                case .highlight:
                    a.rects = (a.rects ?? []) + [array(p.bounds)]
                    let t = page.selection(for: p.bounds)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    a.text = [a.text, t].filter { !$0.isEmpty }.joined(separator: " ")
                case .note:
                    a.rects = [array(p.bounds)]
                case .ink:
                    break   // drawn ink is not created in the reader yet; keep stored paths
                }
                if byID[id] == nil { order.append(id) }
                byID[id] = a
            }
        }
        let result = order.compactMap { byID[$0] }
        try? store.write(result, to: url)
        markClean(doc)
    }

    static func kind(of p: PDFAnnotation) -> LibraryAnnotation.Kind? {
        switch p.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "Highlight": return .highlight
        case "Text": return .note
        case "Ink": return .ink
        default: return nil
        }
    }

    private static func newID(for p: PDFAnnotation) -> String {
        let id = "n:" + UUID().uuidString.prefix(8).lowercased()
        p.setValue(id, forAnnotationKey: idKey)
        return id
    }

    static func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1]) }
    static func array(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.maxX, r.maxY].map { (v: CGFloat) -> Double in (Double(v) * 100).rounded() / 100 }
    }

    // MARK: editing from the reader

    /// Highlight the current selection; all its lines share one id.
    @discardableResult
    static func highlightSelection(in view: PDFView, hex: String) -> Bool {
        guard let sel = view.currentSelection, let doc = view.document else { return false }
        let id = "n:" + UUID().uuidString.prefix(8).lowercased()
        var n = 0
        for line in sel.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let p = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
            p.color = (NSColor(hex: hex) ?? .systemYellow).withAlphaComponent(0.45)
            p.setValue(id, forAnnotationKey: idKey)
            p.setValue("user", forAnnotationKey: authorKey)
            page.addAnnotation(p)
            n += 1
        }
        view.clearSelection()
        if n > 0 { markDirty(doc) }
        return n > 0
    }

    static func addNote(on page: PDFPage, at point: CGPoint, doc: PDFDocument) {
        let p = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                              forType: .text, withProperties: nil)
        p.iconType = .comment
        p.color = NSColor(hex: "#ffd400") ?? .systemYellow
        p.setValue("n:" + UUID().uuidString.prefix(8).lowercased(), forAnnotationKey: idKey)
        p.setValue("user", forAnnotationKey: authorKey)
        page.addAnnotation(p)
        markDirty(doc)
    }

    /// All PDFAnnotations sharing an id (a highlight spans one per line).
    static func parts(id: String, in doc: PDFDocument) -> [(PDFPage, PDFAnnotation)] {
        var out: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for p in page.annotations where (p.value(forAnnotationKey: idKey) as? String) == id { out.append((page, p)) }
        }
        return out
    }

    static func remove(id: String, in doc: PDFDocument) {
        for (page, p) in parts(id: id, in: doc) { page.removeAnnotation(p) }
        markDirty(doc)
    }

    static func setComment(_ c: String, id: String, in doc: PDFDocument) {
        for (_, p) in parts(id: id, in: doc) { p.contents = c }
        markDirty(doc)
    }

    static func setColor(_ hex: String, id: String, in doc: PDFDocument) {
        let c = NSColor(hex: hex) ?? .systemYellow
        for (_, p) in parts(id: id, in: doc) { p.color = kind(of: p) == .highlight ? c.withAlphaComponent(0.45) : c }
        markDirty(doc)
    }

    /// The reader's list: one row per annotation id, in page order.
    struct Row: Identifiable, Equatable {
        let id: String
        let kind: LibraryAnnotation.Kind
        let page: Int
        let text: String
        let comment: String
        let color: String
        let author: String
    }

    static func rows(in doc: PDFDocument) -> [Row] {
        var seen = Set<String>(), out: [Row] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let sorted = page.annotations.sorted { $0.bounds.maxY > $1.bounds.maxY }
            for p in sorted {
                guard let k = kind(of: p) else { continue }
                let id = (p.value(forAnnotationKey: idKey) as? String) ?? newID(for: p)
                guard seen.insert(id).inserted else { continue }
                let text = k == .highlight
                    ? parts(id: id, in: doc).compactMap { pg, a in pg.selection(for: a.bounds)?.string }.joined(separator: " ")
                    : ""
                out.append(Row(id: id, kind: k, page: i,
                               text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               comment: p.contents ?? "", color: p.color.withAlphaComponent(1).hexString,
                               author: (p.value(forAnnotationKey: authorKey) as? String) ?? "user"))
            }
        }
        return out
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#ffd400" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
