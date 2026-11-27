import Foundation
import PDFKit
import AppKit
import CoreText

/// `Nebula --reader-selftest`: checks the reader's logic without a window —
/// annotations round-tripping through annotations.json, highlighting a
/// selection, dark mode keeping figures, and tab suspension. Uses a PDF it
/// draws itself; touches no user data or settings.
enum ReaderSelfTest {

    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "PASS" : "FAIL")  \(what)")
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nebula-reader-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            let store = PaperLibraryStore(root: root)
            let folder = "testPaper2020"
            let dir = store.folder(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try makePDF(dir.appendingPathComponent("paper.pdf"))
            try store.write(PaperMeta(citekey: folder, ids: PlanIDs(), title: "Test paper", year: "2020",
                                      bibliographic: Bibliographic(itemType: "journalArticle", fields: [:], creators: []),
                                      pdf: "paper.pdf", added: ""),
                            to: dir.appendingPathComponent("meta.json"))
            try store.write([
                LibraryAnnotation(id: "z:H1", kind: .highlight, page: 0, rects: [[72, 700, 200, 714]],
                                  color: "#ff6666", text: "Alpha", comment: "first", author: "user"),
                LibraryAnnotation(id: "z:I1", kind: .ink, page: 1, paths: [[100, 100, 150, 150, 200, 120]],
                                  width: 2, color: "#2ea8e5"),
                LibraryAnnotation(id: "z:N1", kind: .note, page: 2, rects: [[300, 300, 320, 320]],
                                  color: "#ffd400", comment: "a note"),
            ], to: dir.appendingPathComponent("annotations.json"))
            try store.write([LibraryFigure(label: "Figure 1", page: 1, rect: [300, 400, 500, 600], source: "test")],
                            to: dir.appendingPathComponent("figures.json"))

            print("Loading annotations.json into the reader")
            guard let doc = ReaderDocument.open(dir.appendingPathComponent("paper.pdf")) else {
                throw ZoteroImportError.missing("test PDF did not open")
            }
            check(doc.page(at: 0) is ReaderPage, "pages use the reader's page class (needed for dark mode)")
            ReaderAnnotations.load(into: doc, folder: folder, store: store)
            let rows = ReaderAnnotations.rows(in: doc)
            check(rows.count == 3, "highlight, ink and note shown (got \(rows.count))")
            check(rows.first { $0.id == "z:H1" }?.comment == "first" && rows.first { $0.id == "z:H1" }?.color == "#ff6666",
                  "comment and colour come back")
            check(!ReaderAnnotations.dirty(doc), "a freshly loaded paper has nothing to save")

            print("Highlighting a selection, commenting, saving")
            let pv = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            pv.document = doc
            guard let sel = doc.findString("gamma", withOptions: .caseInsensitive).first else {
                throw ZoteroImportError.missing("search found nothing in the test PDF")
            }
            pv.setCurrentSelection(sel, animate: false)
            check(ReaderAnnotations.highlightSelection(in: pv, hex: "#5fb236"), "selection highlighted")
            let newRow = ReaderAnnotations.rows(in: doc).first { $0.id.hasPrefix("n:") }
            check(newRow?.text.lowercased().contains("gamma") == true, "the new highlight's text is read from the page")
            if let id = newRow?.id { ReaderAnnotations.setComment("check this", id: id, in: doc) }
            ReaderAnnotations.save(from: doc, folder: folder, store: store)
            let saved = store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("annotations.json")) ?? []
            check(saved.count == 4, "annotations.json now has 4 (got \(saved.count))")
            check(saved.first { $0.id == "z:I1" }?.paths == [[100, 100, 150, 150, 200, 120]],
                  "imported ink keeps its exact paths through a save")
            check(saved.first { $0.id == "z:H1" }?.rects == [[72, 700, 200, 714]] && saved.first { $0.id == "z:H1" }?.text == "Alpha",
                  "imported highlight keeps its rect and stored text")
            let n = saved.first { $0.id.hasPrefix("n:") }
            check(n?.comment == "check this" && n?.color == "#5fb236" && n?.author == "user", "new highlight saved with comment and colour")
            check(fm.contentsEqual(atPath: dir.appendingPathComponent("paper.pdf").path,
                                   andPath: root.appendingPathComponent("original.pdf").path),
                  "the PDF file itself is unchanged")

            print("Reloading and deleting")
            guard let doc2 = ReaderDocument.open(dir.appendingPathComponent("paper.pdf")) else { throw ZoteroImportError.missing("reopen") }
            ReaderAnnotations.load(into: doc2, folder: folder, store: store)
            check(ReaderAnnotations.rows(in: doc2).count == 4, "all 4 come back after reopening")
            ReaderAnnotations.remove(id: "z:N1", in: doc2)
            ReaderAnnotations.save(from: doc2, folder: folder, store: store)
            let afterDelete = store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("annotations.json")) ?? []
            check(afterDelete.count == 3 && !afterDelete.contains { $0.id == "z:N1" }, "a deleted note is gone from annotations.json")

            print("Dark mode keeps figures in colour")
            ReaderPage.dark = true
            if let page = doc2.page(at: 1) {
                let px = pixels(page)
                // Background outside the figure: dark. Inside the figure: still light.
                check(px.at(50, 50) < 0.25, "page background drawn dark (got \(String(format: "%.2f", px.at(50, 50))))")
                check(px.at(400, 450) > 0.75, "figure region keeps its light background (got \(String(format: "%.2f", px.at(400, 450))))")
            }
            if let page = doc2.page(at: 0) {
                // The imported red highlight sits at x 72–200, y 700–714.
                let px = pixels(page)
                check(px.at(190, 707) > 0.4 && px.at(300, 600) < 0.25,
                      "a highlight keeps its colour strip while the page around it is dark (got \(String(format: "%.2f", px.at(190, 707))))")
            }
            ReaderPage.dark = false
            if let page = doc2.page(at: 1) {
                check(pixels(page).at(50, 50) > 0.9, "light mode draws the page normally")
            }

            print("Tabs and suspension")
            let session = ReaderSession(store: store, persists: false)
            var urls: [URL] = []
            for i in 0..<7 {
                let u = root.appendingPathComponent("extra\(i).pdf")
                try fm.copyItem(at: root.appendingPathComponent("original.pdf"), to: u)
                urls.append(u)
            }
            session.open(dir.appendingPathComponent("paper.pdf"))
            check(session.active?.folder == folder && session.active?.title == folder,
                  "a library paper opens as its citekey, linked to its folder")
            for u in urls { session.open(u); _ = session.document(for: session.activeID!) }
            let live = session.tabs.filter { session.isLive($0.id) }.count
            check(session.tabs.count == 8 && live <= ReaderSession.liveDocuments,
                  "8 tabs open, only \(live) documents kept (limit \(ReaderSession.liveDocuments))")
            check(!session.isLive(session.tabs[0].id), "the oldest tab is suspended")
            session.open(urls[2])
            check(session.tabs.count == 8 && session.active?.url == urls[2].standardizedFileURL, "opening an open PDF switches to its tab")
            let first = session.tabs[0].id
            session.select(first)
            check(session.document(for: first) != nil, "a suspended tab reopens")
            session.updatePosition(first, ReaderPosition(page: 2, x: 0, y: 500, scale: 0))
            check(store.meta(folder: folder)?.lastPage == 2, "reading position saved to meta.json")
            session.close(first)
            check(!session.tabs.contains { $0.id == first }, "tab closed")
            session.reopenClosed()
            check(session.active?.folder == folder && session.active?.position.page == 2, "closed tab reopens at its page")

            print("Paper links in the chat")
            check(session.verify(link: "nebula://paper/\(folder)?page=1&quote=beta%20gamma%20delta"), "a quote that is on its page verifies")
            check(!session.verify(link: "nebula://paper/\(folder)?page=2&quote=beta%20gamma%20delta"), "the same quote on the wrong page does not")
            check(!session.verify(link: "nebula://paper/noSuchPaper?page=1&quote=Alpha"), "an unknown citekey does not")
            let parsed = ReaderSession.parse(URL(string: "nebula://paper/\(folder)?page=3&quote=Theta%20iota")!)
            check(parsed?.key == folder && parsed?.page == 2 && parsed?.quote == "Theta iota", "links parse to citekey, 0-based page and quote")
            session.openLink(URL(string: "nebula://paper/\(folder)?page=3&quote=Theta%20iota")!)
            check(session.active?.folder == folder && session.pendingGoto?.page == 2 && session.pendingGoto?.quote == "Theta iota",
                  "opening a link selects the paper and queues the place to show")

            print("Claude's reader tools (offline)")
            let (info, e1) = ReaderMCPTools.call("reader_paper", [:], folder: dir)
            check(!e1 && ((info.first?["text"] as? String) ?? "").contains("pages: 3"), "reader_paper describes the paper")
            let (txt, e2) = ReaderMCPTools.call("reader_page_text", ["from": 2, "to": 3], folder: dir)
            let t2 = (txt.first?["text"] as? String) ?? ""
            check(!e2 && t2.contains("--- page 2 ---") && t2.contains("Epsilon") && t2.contains("Theta"), "reader_page_text returns the asked pages")
            let (img, e3) = ReaderMCPTools.call("reader_figure", ["label": "Figure 1"], folder: dir)
            check(!e3 && img.contains { $0["type"] as? String == "image" }, "reader_figure returns an image")
            let (sg, e4) = ReaderMCPTools.call("reader_suggest_highlights", ["highlights": [
                ["page": 1, "quote": "beta gamma", "category": "Result", "reason": "Key claim."],
                ["page": 2, "quote": "not on this page at all", "category": "Caveat"],
            ]], folder: dir)
            let sugg = store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("suggestions.json")) ?? []
            check(!e4 && sugg.count == 1 && sugg[0].author == "claude" && sugg[0].comment == "[Result] Key claim."
                  && sugg[0].color == "#ffd400" && (sugg[0].rects?.count ?? 0) >= 1,
                  "a found quote becomes a pending suggestion; a missing one is reported (\((sg.first?["text"] as? String) ?? ""))")

            print("Accepting a suggestion")
            guard let doc3 = ReaderDocument.open(dir.appendingPathComponent("paper.pdf")) else { throw ZoteroImportError.missing("reopen") }
            ReaderAnnotations.load(into: doc3, folder: folder, store: store)
            ReaderAnnotations.add(sugg[0], to: doc3)
            check(ReaderAnnotations.rows(in: doc3).contains { $0.id == sugg[0].id && $0.author == "claude" }, "suggestion shown as a Claude row")
            ReaderAnnotations.markDirty(doc3)
            ReaderAnnotations.save(from: doc3, folder: folder, store: store)
            let notSaved = store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("annotations.json")) ?? []
            check(!notSaved.contains { $0.id.hasPrefix("s:") }, "a pending suggestion is never saved as an annotation")
            let accepted = "c:" + sugg[0].id.dropFirst(2)
            for (_, p) in ReaderAnnotations.parts(id: sugg[0].id, in: doc3) { p.setValue(accepted, forAnnotationKey: ReaderAnnotations.idKey) }
            ReaderAnnotations.markDirty(doc3)
            ReaderAnnotations.save(from: doc3, folder: folder, store: store)
            let withAccepted = store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("annotations.json")) ?? []
            let acc = withAccepted.first { $0.id == accepted }
            check(acc?.author == "claude" && acc?.text == "beta gamma" && acc?.comment == "[Result] Key claim.",
                  "an accepted suggestion is saved with Claude's quote and reason")

            print("Library tab")
            func meta(_ key: String, title: String, year: String, creators: [String], pdf: Bool,
                      projects: [String] = [], tags: [String] = [], status: String? = nil) -> PaperMeta {
                var m = PaperMeta(citekey: key, ids: PlanIDs(doi: "10.1/\(key)"), title: title, year: year,
                                  bibliographic: Bibliographic(itemType: "journalArticle",
                                                               fields: ["publicationTitle": "Test Journal"],
                                                               creators: creators.map { PersonName(family: $0, given: "A.") }),
                                  pdf: pdf ? "paper.pdf" : nil, added: "2024-01-0\(creators.count) 00:00:00")
                m.projects = projects; m.tags = tags; m.status = status
                return m
            }
            for (k, m) in [
                ("alphaOne2021", meta("alphaOne2021", title: "Infall onto a hub", year: "2021", creators: ["Alpha"], pdf: true,
                                      projects: ["bigSurvey/partA"], tags: ["infall"], status: "unread")),
                ("betaTwo2022", meta("betaTwo2022", title: "Magnetic fields in cores", year: "2022", creators: ["Beta", "Gamma"],
                                     pdf: false, projects: ["bigSurvey/partB", "other"], tags: ["magnetic", "infall"])),
            ] {
                try store.write(m, to: store.folder(k).appendingPathComponent("meta.json"))
            }
            try fm.createDirectory(at: store.folder("alphaOne2021").appendingPathComponent("notes"), withIntermediateDirectories: true)
            try "note".write(to: store.folder("alphaOne2021").appendingPathComponent("notes/n1.md"), atomically: true, encoding: .utf8)
            try store.write([FileEntry(name: "misc/slides.pdf", collections: ["misc"], zoteroKey: "F1")],
                            to: store.filesDir.appendingPathComponent("files.json"))
            let (entries, files) = LibraryIndex.load(store)
            check(entries.count == 3 && files.count == 1, "library loads every paper and the other files (\(entries.count), \(files.count))")
            let a = entries.first { $0.folder == "alphaOne2021" }, b = entries.first { $0.folder == "betaTwo2022" }
            let annCount = (store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("annotations.json")) ?? []).count
            check(a?.notes == ["n1.md"] && annCount > 0 && entries.first { $0.folder == folder }?.annotationCount == annCount,
                  "notes and annotation counts are read (\(entries.first { $0.folder == folder }?.annotationCount ?? -1) of \(annCount))")
            check(a?.creators == "Alpha" && b?.creators == "Beta and Gamma" &&
                  LibraryEntry.creatorLabel(["X", "Y", "Z"].map { PersonName(family: $0, given: "") }) == "X et al.",
                  "creators read like Zotero's (one, two, et al.)")
            let tree = LibraryIndex.projectTree(entries.flatMap(\.meta.projects))
            check(tree.map(\.path) == ["bigSurvey", "other"] && tree.first?.children?.map(\.path) == ["bigSurvey/partA", "bigSurvey/partB"],
                  "projects form a tree; a parent that is only a prefix is created")
            func shown(_ s: LibrarySource) -> [String] { entries.filter { LibraryIndex.matches($0, s) }.map(\.folder).sorted() }
            check(shown(.project("bigSurvey")) == ["alphaOne2021", "betaTwo2022"] && shown(.project("bigSurvey/partB")) == ["betaTwo2022"],
                  "a project shows its sub-projects' papers")
            check(shown(.tag("infall")) == ["alphaOne2021", "betaTwo2022"] && shown(.unread) == ["alphaOne2021"]
                  && shown(.noPDF) == ["betaTwo2022"], "tags, unread and no-PDF filter")
            check(LibraryIndex.search(entries, "magnetic 2022").map(\.folder) == ["betaTwo2022"]
                  && LibraryIndex.search(entries, "gamma beta").map(\.folder) == ["betaTwo2022"]
                  && LibraryIndex.search(entries, "10.1/alphaone").map(\.folder) == ["alphaOne2021"],
                  "search needs every word: title, year, authors, DOI")
            check(webURL(b!.meta)?.absoluteString == "https://doi.org/10.1/betaTwo2022", "a paper without a PDF links to its DOI page")
            check(LibraryInfoPane.typeLabel("journalArticle") == "Journal Article", "item types read as words")
            check(LibraryEntry.plain("Multi-line <i>Herschel</i>/HIFI and H<sub>2</sub>O") == "Multi-line Herschel/HIFI and H2O",
                  "titles drop Zotero's markup")
            check(LibraryEntry.journal("\\apj") == "ApJ" && LibraryEntry.journal("åp") == "A&A" && LibraryEntry.journal("Nature") == "Nature"
                  && LibraryEntry.displayDate("1952-04-01 1952-04-01") == "1952-04-01" && LibraryEntry.displayDate("2019-00-00 2019") == "2019",
                  "journal macros and Zotero dates read as people write them")

            let s2 = ReaderSession(store: store, persists: false)
            check(s2.showLibrary, "with no tabs the library tab is in front")
            s2.openFolder(folder)
            check(!s2.showLibrary && s2.active?.folder == folder, "opening a paper leaves the library tab")
            s2.open(urls[0])
            s2.showLibrary = true
            s2.selectNext(1)
            check(!s2.showLibrary && s2.activeID == s2.tabs[0].id, "⌃Tab from the library goes to the first paper tab")
            s2.selectNext(-1)
            check(s2.showLibrary, "⌃⇧Tab from the first paper tab goes back to the library")
            s2.selectNext(-1)
            check(!s2.showLibrary && s2.activeID == s2.tabs.last?.id, "and on round to the last tab")
            s2.showLibrary = true
            s2.openLink(URL(string: "nebula://paper/\(folder)?page=1")!)
            check(!s2.showLibrary && s2.active?.folder == folder, "a paper link opens over the library tab")
            for t in s2.tabs { s2.close(t.id) }
            check(s2.showLibrary && s2.tabs.isEmpty, "closing the last tab shows the library")
        } catch {
            print("  FAIL  \(error)")
            failures += 1
        }
        print(failures == 0 ? "\nReader self-test passed." : "\nReader self-test FAILED (\(failures)).")
        exit(failures == 0 ? 0 : 1)
    }

    /// A 3-page US-letter PDF with a line of text on each page. Also saved as
    /// original.pdf next to the library, to check the paper is never written.
    static func makePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ZoteroImportError.missing("PDF context") }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for i in 0..<3 {
            ctx.beginPDFPage(nil)
            let s = NSAttributedString(string: ["Alpha beta gamma delta", "Epsilon zeta eta", "Theta iota kappa"][i],
                                       attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(s)
            ctx.textPosition = CGPoint(x: 72, y: 703)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("original.pdf"))
    }

    /// Grey levels of a page rendered at 1 pt per pixel; at(x, y) uses PDF
    /// coordinates (origin bottom-left).
    struct Pixels {
        let data: [UInt8], w: Int, h: Int
        func at(_ x: Int, _ y: Int) -> Double { Double(data[(h - 1 - y) * w + x]) / 255 }
    }

    static func pixels(_ page: PDFPage) -> Pixels {
        let b = page.bounds(for: .mediaBox)
        let w = Int(b.width), h = Int(b.height)
        var data = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        page.draw(with: .mediaBox, to: ctx)
        return Pixels(data: data, w: w, h: h)
    }
}
