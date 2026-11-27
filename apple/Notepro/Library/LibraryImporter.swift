import Foundation

/// `Nebula --library-import [--library <dir>] [--zotero <dir>] [--mapping <file>] [--vault <dir>] [--restore-cited]`
///
/// Builds the paper library from Zotero (PAPER-LIBRARY.md §5.2 step 4). It
/// reads a snapshot of Zotero's database and copies PDFs out of Zotero's
/// storage: Zotero itself is never written to.
///
/// Safe to run again: a folder whose meta.json has the same Zotero key is
/// updated in place, keeping what was added in Nebula since (reading
/// position, aliases, annotations and figures that did not come from
/// Zotero). A folder that belongs to another paper is never overwritten.
enum LibraryImporter {

    struct Options {
        var zoteroDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Zotero")
        var library = PaperLibraryStore.defaultRoot
        var mappingFile: URL?
        var vault: URL?
        /// Bring back trashed items that the vault still cites.
        var restoreCited = false
        var dbPathOverride: URL?
    }

    struct Result: Codable {
        var created = 0, updated = 0, pdfsCopied = 0, pdfsAlreadyThere = 0
        var annotations = 0, figures = 0, notes = 0, files = 0, paperCandidates = 0
        var restoredFromTrash: [String] = []
        var skipped: [String] = []          // "<citekey>: why"
    }

    static func runCLI() -> Never {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return (args[i + 1] as NSString).expandingTildeInPath
        }
        var o = Options()
        if let z = value("--zotero") { o.zoteroDir = URL(fileURLWithPath: z) }
        if let l = value("--library") { o.library = URL(fileURLWithPath: l) }
        o.mappingFile = value("--mapping").map { URL(fileURLWithPath: $0) }
        o.vault = value("--vault").map { URL(fileURLWithPath: $0) }
        o.restoreCited = args.contains("--restore-cited")
        do {
            let r = try run(o)
            print("""
                Imported into \(o.library.path): \(r.created) new, \(r.updated) updated papers; \
                \(r.pdfsCopied) PDFs copied (\(r.pdfsAlreadyThere) already there); \
                \(r.annotations) annotations, \(r.figures) figure regions, \(r.notes) notes; \
                \(r.files) files in _files (\(r.paperCandidates) to look up as papers); \
                \(r.restoredFromTrash.count) restored from Zotero's trash; \(r.skipped.count) skipped.
                """)
            for s in r.skipped { print("  skipped \(s)") }
            exit(r.skipped.isEmpty ? 0 : 3)
        } catch {
            FileHandle.standardError.write("Import failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // MARK: - Run

    static func run(_ o: Options) throws -> Result {
        let fm = FileManager.default
        let snapshot = try o.dbPathOverride ?? ZoteroSnapshot.copy(zoteroDir: o.zoteroDir)
        defer { if o.dbPathOverride == nil { try? fm.removeItem(at: snapshot.deletingLastPathComponent()) } }
        let lib = try ZoteroSnapshot.read(dbPath: snapshot, storageDir: o.zoteroDir.appendingPathComponent("storage"))

        var mapping: [String: CollectionAction]?
        if let mf = o.mappingFile {
            mapping = try JSONDecoder().decode([String: CollectionRule].self, from: Data(contentsOf: mf)).mapValues(\.action)
        }

        // Which trashed items to bring back: those the vault cites.
        var restore = Set<String>()
        if o.restoreCited, let v = o.vault {
            let first = ZoteroImportPlanner.plan(lib, zoteroDir: o.zoteroDir, mapping: mapping)
            restore = Set(ZoteroImportReport.checkVault(v, plan: first).inZoteroTrash)
        }
        var plan = ZoteroImportPlanner.plan(lib, zoteroDir: o.zoteroDir, mapping: mapping, restore: restore)
        guard plan.totals.invariantFailures.isEmpty else {
            throw ZoteroImportError.database("plan failed its checks, nothing written: \(plan.totals.invariantFailures.joined(separator: "; "))")
        }
        if let v = o.vault { plan.vault = ZoteroImportReport.checkVault(v, plan: plan) }

        let store = PaperLibraryStore(root: o.library)
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        var result = Result()
        result.restoredFromTrash = plan.restoredFromTrash

        let itemsByKey = Dictionary(lib.items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let attByKey = Dictionary(lib.attachments.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var annsByAttachment: [Int64: [ZAnnotation]] = [:]
        for a in lib.annotations { annsByAttachment[a.attachmentID, default: []].append(a) }
        var notesByParent: [Int64: [ZNote]] = [:]
        for n in lib.notes where !n.deleted { if let p = n.parentID { notesByParent[p, default: []].append(n) } }

        for p in plan.papers {
            guard let item = itemsByKey[p.zoteroKey] else { result.skipped.append("\(p.citekey): item vanished"); continue }
            let dir = store.folder(p.folder)
            let existing = store.meta(folder: p.folder)
            if let e = existing, e.zoteroKey != p.zoteroKey {
                result.skipped.append("\(p.citekey): folder \(p.folder) already holds another paper (\(e.citekey))")
                continue
            }
            if fm.fileExists(atPath: dir.path), existing == nil,
               !((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
                result.skipped.append("\(p.citekey): folder \(p.folder) exists and is not a library paper")
                continue
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // PDF: copied, never moved; an existing copy is left alone.
            var pdfName: String?
            var pdfAttachmentID: Int64?
            if let f = p.pdf, f.exists, let src = f.resolvedPath {
                pdfName = "paper.pdf"
                pdfAttachmentID = attByKey[f.zoteroKey]?.itemID
                let dest = dir.appendingPathComponent("paper.pdf")
                if fm.fileExists(atPath: dest.path) {
                    result.pdfsAlreadyThere += 1
                } else {
                    try fm.copyItem(at: URL(fileURLWithPath: src), to: dest)
                    result.pdfsCopied += 1
                }
            }

            // Annotations on the chosen PDF; image regions become figures.
            var anns: [LibraryAnnotation] = [], figs: [LibraryFigure] = []
            for z in pdfAttachmentID.flatMap({ annsByAttachment[$0] }) ?? [] {
                if z.type == 3 {
                    if let f = figure(from: z) { figs.append(f) }
                } else if let a = annotation(from: z) {
                    anns.append(a)
                }
            }
            // Keep what Nebula added since the last import.
            let annURL = dir.appendingPathComponent("annotations.json")
            let figURL = dir.appendingPathComponent("figures.json")
            let oldAnns = store.read([LibraryAnnotation].self, from: annURL) ?? []
            let oldFigs = store.read([LibraryFigure].self, from: figURL) ?? []
            anns += oldAnns.filter { !$0.id.hasPrefix("z:") }
            figs += oldFigs.filter { $0.source != "zotero-figure" }
            try store.write(anns, to: annURL)
            try store.write(figs, to: figURL)
            result.annotations += anns.count
            result.figures += figs.count

            // Child notes → Markdown in the paper's folder.
            for n in notesByParent[item.itemID] ?? [] {
                let md = markdown(fromNoteHTML: n.html, title: n.title)
                try md.write(to: dir.appendingPathComponent("notes", isDirectory: true)
                                .appendingPathComponent("zotero-\(n.key).md"),
                             atomically: true, encoding: .utf8, createDirs: true)
                result.notes += 1
            }

            var meta = PaperMeta(
                citekey: p.citekey, ids: p.ids, title: p.title, year: p.year,
                bibliographic: Bibliographic(itemType: item.type, fields: item.fields,
                                             creators: item.people.map { PersonName(family: $0.family, given: $0.given, role: $0.role) }),
                status: p.status, tags: p.tags, keywords: p.keywords, projects: p.projects,
                version: isPreprint(item, p.ids) ? "preprint" : (p.ids.doi != nil ? "published" : nil),
                pdf: pdfName, added: item.dateAdded, zoteroKey: p.zoteroKey)
            if let e = existing {
                meta.aliases = e.aliases
                meta.lastOpened = e.lastOpened
                meta.lastPage = e.lastPage
                if meta.status == nil { meta.status = e.status }
                result.updated += 1
            } else {
                result.created += 1
            }
            try store.write(meta, to: dir.appendingPathComponent("meta.json"))
        }

        // Files that are not papers.
        var entries: [FileEntry] = store.read([FileEntry].self, from: store.filesDir.appendingPathComponent("files.json")) ?? []
        for o in plan.orphans where o.kind == .pdf || o.kind == .file {
            guard let att = attByKey[o.zoteroKey] else { continue }
            let f = ZoteroImportPlanner.resolve(att, storage: lib.storageDir)
            guard f.exists, let src = f.resolvedPath else { continue }
            let group = ZoteroImportPlanner.safeFolderName(o.collections.first.map(ZoteroImportPlanner.lastComponent) ?? "unsorted")
            let name = "\(group)/\(URL(fileURLWithPath: src).lastPathComponent)"
            let dest = store.filesDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: URL(fileURLWithPath: src), to: dest)
            }
            let candidate = bibcodeHint(URL(fileURLWithPath: src).lastPathComponent)
            entries.removeAll { $0.zoteroKey == o.zoteroKey }
            entries.append(FileEntry(name: name, collections: o.collections, zoteroKey: o.zoteroKey, paperCandidate: candidate))
        }
        entries.sort { $0.name < $1.name }
        if !entries.isEmpty { try store.write(entries, to: store.filesDir.appendingPathComponent("files.json")) }
        result.files = entries.count
        result.paperCandidates = entries.filter { $0.paperCandidate != nil }.count

        // What this import was given and did, for the next run and for review.
        try store.write(plan, to: store.importDir.appendingPathComponent("plan.json"))
        try store.write(plan.collections, to: store.importDir.appendingPathComponent("collection-mapping.json"))
        try store.write(result, to: store.importDir.appendingPathComponent("last-import.json"))
        return result
    }

    // MARK: - Conversions

    static func annotation(from z: ZAnnotation) -> LibraryAnnotation? {
        guard let pos = json(z.position), let page = pos["pageIndex"] as? Int else { return nil }
        let kind: LibraryAnnotation.Kind
        switch z.type {
        case 1: kind = .highlight
        case 2: kind = .note
        case 4: kind = .ink
        default: return nil
        }
        return LibraryAnnotation(
            id: "z:\(z.key)", kind: kind, page: page,
            rects: pos["rects"] as? [[Double]], paths: pos["paths"] as? [[Double]],
            width: pos["width"] as? Double, color: z.color.isEmpty ? "#ffd400" : z.color,
            text: z.text, comment: z.comment, author: "user", created: z.dateAdded)
    }

    static func figure(from z: ZAnnotation) -> LibraryFigure? {
        guard let pos = json(z.position), let page = pos["pageIndex"] as? Int,
              let r = (pos["rects"] as? [[Double]])?.first, r.count == 4 else { return nil }
        let label = z.tags.first { $0.range(of: #"^(Figure|Table|Fig\.?)\s*\S+$"#, options: .regularExpression) != nil }
            ?? (z.comment.isEmpty ? "Region" : z.comment)
        return LibraryFigure(label: label, page: page, rect: r, source: "zotero-figure")
    }

    static func isPreprint(_ item: ZItem, _ ids: PlanIDs) -> Bool {
        if item.type == "preprint" { return true }
        if (item.fields["publicationTitle"] ?? "").lowercased().contains("arxiv") { return true }
        return ids.doi?.hasPrefix("10.48550/") == true
    }

    /// "1994A&A...291..943O.pdf" → "1994A&A...291..943O": a file named like an
    /// ADS bibcode (possibly cut short) is probably a paper to look up.
    static func bibcodeHint(_ filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        guard stem.range(of: #"^(1[89]|20)\d{2}[A-Za-z&]{2,6}[.\dA-Za-z]{2,14}$"#, options: .regularExpression) != nil
        else { return nil }
        return stem
    }

    static func markdown(fromNoteHTML html: String, title: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            (#"(?i)<h1[^>]*>"#, "\n# "), (#"(?i)<h2[^>]*>"#, "\n## "), (#"(?i)<h3[^>]*>"#, "\n### "),
            (#"(?i)</h[1-6]>"#, "\n\n"), (#"(?i)<li[^>]*>"#, "\n- "), (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</p>"#, "\n\n"), (#"(?i)<(strong|b)>"#, "**"), (#"(?i)</(strong|b)>"#, "**"),
            (#"(?i)<(em|i)>"#, "*"), (#"(?i)</(em|i)>"#, "*"), (#"<[^>]+>"#, ""),
        ]
        for (re, rep) in rules { s = s.replacingOccurrences(of: re, with: rep, options: .regularExpression) }
        for (ent, ch) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: ent, with: ch)
        }
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = s.isEmpty ? "" : s + "\n"
        return s.hasPrefix("#") || title.isEmpty ? body : "# \(title)\n\n\(body)"
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

private extension String {
    func write(to url: URL, atomically: Bool, encoding: String.Encoding, createDirs: Bool) throws {
        if createDirs {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try write(to: url, atomically: atomically, encoding: encoding)
    }
}
