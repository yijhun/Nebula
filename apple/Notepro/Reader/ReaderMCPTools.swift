import Foundation
import PDFKit
import AppKit

/// MCP tools for the reader's chat (PAPER-LIBRARY.md §8.2). The CLI starts
/// `Nebula --mcp --paper <folder>` for a reader conversation, so every tool
/// is bound to that paper's library folder and reads its files directly
/// (paper.pdf, figures.json); nothing needs the running app. What the user
/// is looking at right now (page, selection) is sent with each message.
///
/// Suggested highlights are written to `suggestions.json` in the folder; the
/// reader shows them as pending, dashed highlights for the user to accept.
enum ReaderMCPTools {

    static func tools() -> [[String: Any]] {
        func obj(_ props: [String: Any], _ req: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": req]
        }
        let int: [String: Any] = ["type": "integer"]
        return [
            ["name": "reader_paper",
             "description": "The paper open in the reader: citekey, title, authors, year, page count, and its known figures/tables (label and page).",
             "inputSchema": obj([:], [])],
            ["name": "reader_page_text",
             "description": "Text of pages `from`…`to` (1-based, at most 6 pages per call), each headed '--- page N ---'. Read only the pages you need.",
             "inputSchema": obj(["from": int, "to": int], ["from"])],
            ["name": "reader_figure",
             "description": "Image of one known figure or table, by its label (e.g. 'Figure 3') as listed by reader_paper. Use it to answer questions about a figure.",
             "inputSchema": obj(["label": ["type": "string"]], ["label"])],
            ["name": "reader_page_image",
             "description": "Image of a whole page (1-based), for figures that are not in the list or for layout questions.",
             "inputSchema": obj(["page": int], ["page"])],
            ["name": "reader_suggest_highlights",
             "description": "Propose highlights for the user to accept or reject in the reader. Only when the user asks. At most 8. Each: page (1-based), quote (exact text from that page, 3–25 words), category (Result, Numbers, Data & Method, Caveat, Relevant to me), reason (one short English sentence).",
             "inputSchema": obj(["highlights": ["type": "array", "items": obj([
                "page": int, "quote": ["type": "string"], "category": ["type": "string"], "reason": ["type": "string"],
             ], ["page", "quote", "category"])]], ["highlights"])],
        ]
    }

    /// Category → highlight colour (Zotero's palette).
    static let categoryColors: [String: String] = [
        "result": "#ffd400", "numbers": "#2ea8e5", "data & method": "#5fb236",
        "caveat": "#ff6666", "relevant to me": "#a28ae5",
    ]

    /// Returns MCP `content` items and whether it is an error.
    static func call(_ name: String, _ a: [String: Any], folder: URL) -> ([[String: Any]], Bool) {
        func text(_ s: String, _ err: Bool = false) -> ([[String: Any]], Bool) { ([["type": "text", "text": s]], err) }
        let pdfURL = folder.appendingPathComponent("paper.pdf")
        guard let doc = PDFDocument(url: pdfURL) else { return text("The paper's PDF could not be opened (\(pdfURL.path)).", true) }
        let store = PaperLibraryStore(root: folder.deletingLastPathComponent())
        let figs = store.read([LibraryFigure].self, from: folder.appendingPathComponent("figures.json")) ?? []

        switch name {
        case "reader_paper":
            let m = store.meta(folder: folder.lastPathComponent)
            var lines = ["citekey: \(m?.citekey ?? folder.lastPathComponent)",
                         "title: \(m?.title ?? "")",
                         "authors: \(m?.bibliographic.creators.map { "\($0.family), \($0.given)" }.joined(separator: "; ") ?? "")",
                         "year: \(m?.year ?? "")", "pages: \(doc.pageCount)"]
            lines.append(figs.isEmpty ? "figures: none detected yet (use reader_page_image)"
                         : "figures: " + figs.map { "\($0.label) (p. \($0.page + 1))" }.joined(separator: ", "))
            return text(lines.joined(separator: "\n"))

        case "reader_page_text":
            let from = max(1, a["from"] as? Int ?? 1)
            let to = min(doc.pageCount, max(from, min(a["to"] as? Int ?? from, from + 5)))
            guard from <= doc.pageCount else { return text("The paper has \(doc.pageCount) pages.", true) }
            let body = (from...to).map { i in "--- page \(i) ---\n" + (doc.page(at: i - 1)?.string ?? "") }.joined(separator: "\n\n")
            return text(body)

        case "reader_figure":
            let label = (a["label"] as? String ?? "").lowercased().replacingOccurrences(of: ".", with: "")
            let norm = { (s: String) in s.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "fig ", with: "figure ") }
            guard let f = figs.first(where: { norm($0.label) == norm(label) }) ?? figs.first(where: { norm($0.label).contains(norm(label)) }),
                  let page = doc.page(at: f.page), f.rect.count == 4 else {
                return text("No figure labelled \"\(a["label"] as? String ?? "")\". Known: \(figs.map(\.label).joined(separator: ", ")). Use reader_page_image otherwise.", true)
            }
            let r = CGRect(x: f.rect[0], y: f.rect[1], width: f.rect[2] - f.rect[0], height: f.rect[3] - f.rect[1])
            guard let png = render(page, rect: r, maxSide: 1400) else { return text("Could not render the figure.", true) }
            return ([["type": "text", "text": "\(f.label), page \(f.page + 1)\(f.caption.isEmpty ? "" : ": \(f.caption)")"],
                     ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]], false)

        case "reader_page_image":
            let p = (a["page"] as? Int ?? 1) - 1
            guard let page = doc.page(at: p), let png = render(page, rect: page.bounds(for: .cropBox), maxSide: 1600) else {
                return text("No page \(p + 1); the paper has \(doc.pageCount) pages.", true)
            }
            return ([["type": "text", "text": "Page \(p + 1)"], ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]], false)

        case "reader_suggest_highlights":
            let items = (a["highlights"] as? [[String: Any]] ?? []).prefix(8)
            var placed: [LibraryAnnotation] = [], missed: [String] = []
            for h in items {
                let p = (h["page"] as? Int ?? 0) - 1
                let quote = (h["quote"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let page = doc.page(at: p), !quote.isEmpty,
                      let rects = locate(quote, on: page, in: doc) else { missed.append("p.\(p + 1) \"\(quote.prefix(40))\""); continue }
                let cat = h["category"] as? String ?? "Result"
                let reason = h["reason"] as? String ?? ""
                placed.append(LibraryAnnotation(
                    id: "s:" + UUID().uuidString.prefix(8).lowercased(), kind: .highlight, page: p,
                    rects: rects, color: categoryColors[cat.lowercased()] ?? "#ffd400",
                    text: quote, comment: reason.isEmpty ? "[\(cat)]" : "[\(cat)] \(reason)",
                    author: "claude", created: ISO8601DateFormatter().string(from: Date())))
            }
            let url = folder.appendingPathComponent("suggestions.json")
            let old = store.read([LibraryAnnotation].self, from: url) ?? []
            try? store.write(old + placed, to: url)
            var msg = "Placed \(placed.count) suggested highlight(s); the user accepts or rejects each in the reader."
            if !missed.isEmpty { msg += " Not found on the page as quoted (quote the exact text): " + missed.joined(separator: "; ") }
            return text(msg, placed.isEmpty)

        default:
            return text("Unknown tool \(name)", true)
        }
    }

    /// Rects (PDF points) of a quote on one page, matched whitespace- and
    /// hyphenation-tolerantly; nil when it is not on that page.
    static func locate(_ quote: String, on page: PDFPage, in doc: PDFDocument) -> [[Double]]? {
        func lines(_ sel: PDFSelection) -> [[Double]] {
            sel.selectionsByLine().compactMap { l -> [Double]? in
                guard l.pages.first == page else { return nil }
                return ReaderAnnotations.array(l.bounds(for: page))
            }
        }
        func first(_ q: String, after: Int = -1) -> NSRange? {
            for sel in doc.findString(q, withOptions: [.caseInsensitive]) where sel.pages.contains(page) {
                let r = sel.range(at: 0, on: page)
                if r.location != NSNotFound, r.location > after { return r }
            }
            return nil
        }
        // 1. The whole quote as one string.
        if quote.count >= 8, let r = first(quote), let sel = page.selection(for: r) {
            let l = lines(sel); if !l.isEmpty { return l }
        }
        // 2. Its first and last words, joined: survives line breaks, hyphenation
        //    and symbols the PDF's text layer spells differently (e.g. M⊙).
        let words = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 6 {
            let head = words.prefix(4).joined(separator: " "), tail = words.suffix(4).joined(separator: " ")
            if let a = first(head), let b = first(tail, after: a.location),
               b.location + b.length - a.location < quote.count * 2 + 40,
               let sel = page.selection(for: NSRange(location: a.location, length: b.location + b.length - a.location)) {
                let l = lines(sel); if !l.isEmpty { return l }
            }
        }
        // 3. Just its start.
        let start = words.prefix(6).joined(separator: " ")
        if start.count >= 8, let r = first(start), let sel = page.selection(for: r) {
            let l = lines(sel); if !l.isEmpty { return l }
        }
        return nil
    }

    /// Does the quote appear on that page? Used to mark chat links.
    static func quoteOnPage(_ quote: String, page: PDFPage) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "-\n", with: "")
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let q = norm(quote), t = norm(page.string ?? "")
        return !q.isEmpty && t.contains(q)
    }

    static func render(_ page: PDFPage, rect: CGRect, maxSide: CGFloat) -> Data? {
        let scale = min(2, maxSide / max(rect.width, rect.height))
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            guard let cg = NSGraphicsContext.current?.cgContext else { return true }
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .cropBox, to: cg)
            return true
        }
        guard let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
