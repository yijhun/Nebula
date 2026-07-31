import Foundation
import PDFKit
import AppKit

/// One detected figure/table in a paper, from whichever source found it.
struct PaperFigure: Identifiable {
    let id = UUID()
    let kind: String          // "figure" | "table" | "formula"
    let tag: String           // "Figure 6"
    let caption: String       // cleaned caption text
    let pageIndex: Int        // 0-based
    let image: URL            // rendered PNG on disk
    /// Region in PDF points, PDFKit convention (origin bottom-left). nil when
    /// the source didn't give usable coordinates.
    let rect: CGRect?

    var isFigureOrTable: Bool { kind == "figure" || kind == "table" }
}

/// Finds the figures in a paper, cheapest source first:
///
/// 1. the **zotero-figure** plugin's cache (`~/Zotero/zotero-figure/results/…`)
///    — already extracted, high-res, free and instant;
/// 2. **pdffigures2** (`~/Zotero/pdffigures2.jar`, ~1.5 s per paper) — works on
///    any PDF whether or not the plugin has analysed it.
///
/// Results from either source are normalised into `PaperFigure`.
enum FigureExtractor {

    // MARK: paths

    static var zoteroDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Zotero") }
    static var pluginResults: URL { zoteroDir.appendingPathComponent("zotero-figure/results") }
    static var pdfFigures2Jar: URL { zoteroDir.appendingPathComponent("pdffigures2.jar") }

    static var hasPdfFigures2: Bool {
        FileManager.default.fileExists(atPath: pdfFigures2Jar.path) && javaPath != nil
    }
    static var javaPath: String? {
        ["/usr/bin/java", "/opt/homebrew/bin/java", "/usr/local/bin/java"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: entry point

    /// All figures for a PDF. Tries the plugin cache for `attachmentKey`, then
    /// falls back to running pdffigures2. Completion is on the main queue.
    static func figures(pdf: URL, attachmentKey: String,
                        completion: @escaping ([PaperFigure], _ source: String) -> Void) {
        if let cached = fromPluginCache(attachmentKey: attachmentKey), !cached.isEmpty {
            DispatchQueue.main.async { completion(cached, "zotero-figure") }
            return
        }
        runPdfFigures2(pdf: pdf) { figs in
            DispatchQueue.main.async { completion(figs, figs.isEmpty ? "none" : "pdffigures2") }
        }
    }

    // MARK: tier 1 — the zotero-figure plugin's cache

    /// Read `<results>/<libraryID>/<attachmentKey>/manifest.json`. The library
    /// id isn't known here, so every library folder is checked.
    static func fromPluginCache(attachmentKey: String) -> [PaperFigure]? {
        guard !attachmentKey.isEmpty else { return nil }
        let fm = FileManager.default
        guard let libs = try? fm.contentsOfDirectory(at: pluginResults, includingPropertiesForKeys: nil)
        else { return nil }
        for lib in libs {
            let dir = lib.appendingPathComponent(attachmentKey, isDirectory: true)
            let manifest = dir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifest.path),
                  let data = try? Data(contentsOf: manifest),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else { continue }
            var out: [PaperFigure] = []
            for r in results {
                guard let file = r["imageFile"] as? String else { continue }
                let img = dir.appendingPathComponent(file)
                guard fm.fileExists(atPath: img.path) else { continue }
                // The plugin's rect is already in PDFKit's bottom-left space.
                var rect: CGRect?
                if let a = r["rect"] as? [Double], a.count == 4 {
                    rect = CGRect(x: a[0], y: a[1], width: a[2] - a[0], height: a[3] - a[1])
                }
                out.append(PaperFigure(
                    kind: (r["kind"] as? String ?? "figure").lowercased(),
                    tag: r["tag"] as? String ?? "Figure",
                    caption: cleanCaption(r["comment"] as? String ?? ""),
                    pageIndex: r["pageIndex"] as? Int ?? 0,
                    image: img, rect: rect))
            }
            return out.isEmpty ? nil : sorted(out)
        }
        return nil
    }

    // MARK: tier 2 — pdffigures2

    /// Run the bundled pdffigures2 jar over one PDF (~1.5 s) into a temp dir.
    /// Its JSON gives caption + region; regions use a TOP-LEFT origin, so they
    /// are flipped into PDFKit space here.
    static func runPdfFigures2(pdf: URL, completion: @escaping ([PaperFigure]) -> Void) {
        guard hasPdfFigures2, let java = javaPath else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let work = fm.temporaryDirectory
                .appendingPathComponent("np-figs-\(UUID().uuidString)", isDirectory: true)
            let imgDir = work.appendingPathComponent("img", isDirectory: true)
            let dataDir = work.appendingPathComponent("data", isDirectory: true)
            for d in [imgDir, dataDir] {
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: java)
            p.arguments = ["-jar", pdfFigures2Jar.path, pdf.path,
                           "-i", "300",
                           "-m", imgDir.path + "/",
                           "-d", dataDir.path + "/",
                           "-q"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            // Drain so a chatty run can't fill the pipe buffer and deadlock.
            pipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
            do { try p.run(); p.waitUntilExit() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                completion([]); return
            }
            pipe.fileHandleForReading.readabilityHandler = nil

            // Page heights, for the top-left → bottom-left flip.
            let doc = PDFDocument(url: pdf)
            func pageHeight(_ i: Int) -> CGFloat {
                guard let page = doc?.page(at: i) else { return 792 }
                return page.bounds(for: .mediaBox).height
            }
            var out: [PaperFigure] = []
            let jsons = (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? []
            for j in jsons where j.pathExtension == "json" {
                guard let data = try? Data(contentsOf: j),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { continue }
                for r in arr {
                    guard let render = r["renderURL"] as? String,
                          fm.fileExists(atPath: render) else { continue }
                    let page = r["page"] as? Int ?? 0
                    var rect: CGRect?
                    if let b = r["regionBoundary"] as? [String: Double],
                       let x1 = b["x1"], let y1 = b["y1"], let x2 = b["x2"], let y2 = b["y2"] {
                        let h = pageHeight(page)
                        rect = CGRect(x: x1, y: h - y2, width: x2 - x1, height: y2 - y1)
                    }
                    let type = (r["figType"] as? String ?? "Figure")
                    let name = r["name"] as? String ?? ""
                    out.append(PaperFigure(
                        kind: type.lowercased(),
                        tag: "\(type) \(name)".trimmingCharacters(in: .whitespaces),
                        caption: cleanCaption(r["caption"] as? String ?? ""),
                        pageIndex: page,
                        image: URL(fileURLWithPath: render), rect: rect))
                }
            }
            completion(sorted(out))
        }
    }

    // MARK: helpers

    private static func sorted(_ figs: [PaperFigure]) -> [PaperFigure] {
        // Figures and tables first (what people actually cite), then by page.
        figs.sorted {
            if $0.isFigureOrTable != $1.isFigureOrTable { return $0.isFigureOrTable }
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.tag < $1.tag
        }
    }

    /// PDF text extraction mangles ligatures and maths; strip the noise that
    /// shows up most often so the caption is presentable in a note.
    static func cleanCaption(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        // Mis-decoded ligature/。encoding artefacts, e.g. "ð15Þ" and stray U+FFFD.
        for junk in ["\u{FFFD}", "ð", "Þ", "\u{00AD}"] {
            t = t.replacingOccurrences(of: junk, with: "")
        }
        t = t.replacingOccurrences(of: "ﬁ", with: "fi")
            .replacingOccurrences(of: "ﬂ", with: "fl")
        // Collapse the whitespace the removals leave behind.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
