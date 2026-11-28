import Foundation
import PDFKit

/// `Nebula --library-merge [--library <dir>] [--vault <dir>] [--apply]`
///
/// Merges duplicate papers (PAPER-LIBRARY.md §4.4). Without `--apply` it
/// changes nothing: it writes `.import/merge-plan.json` and
/// `merge-report.md`, one entry per group with the paper it would keep and
/// why. Edit the plan (`keep`, `skip`) and run with `--apply`, which merges
/// exactly what the plan says:
///
/// - the kept paper gets the others' citekeys as aliases, so every citation
///   still resolves, and their tags, projects, notes and identifiers;
/// - a different PDF of the same paper is kept beside it (`paper-arxiv.pdf`
///   for an arXiv one, else `paper-2.pdf`);
/// - each merged-away folder moves, whole, to `<library>/.merged/`, so
///   nothing is lost and a merge can be undone by moving it back;
/// - their Zotero keys are recorded, so a re-import does not bring them back.
enum LibraryMerge {

    struct Group: Codable {
        var keep: String                    // folder
        var merge: [String]                 // folders
        var citekeys: [String: String]      // folder → citekey
        var titles: [String: String]
        var reasons: [String]
        var why: String
        /// The merged paper's citekey: the one the vault cites most, else
        /// the usual authorTitleYear style. The others become aliases.
        var citekey: String
        /// Only the title (and year) match: confirm before merging.
        var titleOnly: Bool
        /// Set true to leave this group alone.
        var skip = false
    }

    struct Plan: Codable {
        var library: String
        var groups: [Group]
    }

    struct Result {
        var merged = 0, skipped = 0
        var problems: [String] = []
    }

    static func runCLI() -> Never {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return (args[i + 1] as NSString).expandingTildeInPath
        }
        let store = PaperLibraryStore(root: value("--library").map { URL(fileURLWithPath: $0) } ?? PaperLibraryStore.defaultRoot)
        let planURL = store.importDir.appendingPathComponent("merge-plan.json")
        do {
            if args.contains("--apply") {
                guard let plan = store.read(Plan.self, from: planURL) else {
                    throw ZoteroImportError.missing("No \(planURL.path); run --library-merge without --apply first")
                }
                let r = try apply(plan, store: store)
                print("Merged \(r.merged) groups, left \(r.skipped) alone. Merged-away folders are in \(store.root.path)/.merged")
                for p in r.problems { print("  \(p)") }
                exit(r.problems.isEmpty ? 0 : 3)
            }
            let plan = makePlan(store: store, vault: value("--vault").map { URL(fileURLWithPath: $0) })
            try store.write(plan, to: planURL)
            try report(plan, store: store).write(to: store.importDir.appendingPathComponent("merge-report.md"),
                                                 atomically: true, encoding: .utf8)
            print("""
                \(plan.groups.count) duplicate groups, \(plan.groups.filter(\.titleOnly).count) matched by title only. \
                Nothing changed. Wrote \(store.importDir.path)/merge-report.md and merge-plan.json
                """)
            exit(0)
        } catch {
            FileHandle.standardError.write("Merge failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // MARK: - Plan

    struct Facts {
        var annotations = 0
        var hasPDF = false
        var arxivPDF = false
        var cited = 0
        var notes = 0
        var lastOpened = ""
    }

    static func facts(_ folder: String, _ m: PaperMeta, store: PaperLibraryStore, cites: [String: Int]) -> Facts {
        let dir = store.folder(folder)
        var f = Facts()
        f.annotations = (store.read([LibraryAnnotation].self, from: dir.appendingPathComponent("annotations.json")) ?? []).count
        if let pdf = m.pdf, FileManager.default.fileExists(atPath: dir.appendingPathComponent(pdf).path) {
            f.hasPDF = true
            f.arxivPDF = isArxivPDF(dir.appendingPathComponent(pdf))
        }
        f.cited = ([m.citekey] + m.aliases).reduce(0) { $0 + (cites[$1] ?? 0) }
        f.notes = ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("notes").path)) ?? []).count
        f.lastOpened = m.lastOpened ?? ""
        return f
    }

    /// arXiv stamps "arXiv:2101.00001v2 [astro-ph.GA] 5 Jan 2021" down the
    /// first page's margin; a journal PDF does not carry it.
    static func isArxivPDF(_ url: URL) -> Bool {
        guard let s = PDFDocument(url: url)?.page(at: 0)?.string else { return false }
        return s.range(of: #"arXiv:(\d{4}\.\d{4,5}|[a-z\-]+/\d{7})v\d"#, options: .regularExpression) != nil
    }

    /// 2 for an authorTitleYear key, 1 for the same with an a/b suffix,
    /// 0 for anything else (a bibcode, a file name, a shouting title).
    static func keyStyle(_ key: String) -> Int {
        // Title words may hold digits: smithDisksAroundW3IRS52020.
        if key.range(of: #"^[a-z]+[A-Z0-9][A-Za-z0-9]*\d{4}$"#, options: .regularExpression) != nil { return 2 }
        if key.range(of: #"^[a-z]+[A-Z0-9][A-Za-z0-9]*\d{4}[a-z]$"#, options: .regularExpression) != nil { return 1 }
        return 0
    }

    /// How many vault files cite each key.
    static func vaultCitations(_ vault: URL?) -> [String: Int] {
        guard let vault else { return [:] }
        var out: [String: Int] = [:]
        let it = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = it?.nextObject() as? URL {
            guard ["md", "tex"].contains(u.pathExtension.lowercased()),
                  let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for k in ZoteroImportReport.citedKeys(in: s) { out[k, default: 0] += 1 }
        }
        return out
    }

    static func makePlan(store: PaperLibraryStore, vault: URL?) -> Plan {
        let papers = store.allPapers()
        let metas = Dictionary(uniqueKeysWithValues: papers.map { ($0.folder, $0.meta) })
        let cites = vaultCitations(vault)
        // Grouped by folder (citekeys are not unique; folders are).
        let planned = papers.map { p in
            PlannedPaper(zoteroKey: p.meta.zoteroKey ?? p.folder, citekey: p.folder, folder: p.folder,
                         itemType: p.meta.bibliographic.itemType, title: p.meta.title, year: p.meta.year, authors: [],
                         ids: p.meta.ids, pdf: nil, otherAttachments: 0, annotations: AnnotationCounts(),
                         projects: [], tags: [], keywords: [], status: nil, childNotes: 0, issues: [])
        }
        var groups: [Group] = []
        for g in ZoteroImportPlanner.duplicates(planned) {
            let folders = g.citekeys.filter { metas[$0] != nil }
            guard folders.count > 1 else { continue }
            let f = Dictionary(uniqueKeysWithValues: folders.map { ($0, facts($0, metas[$0]!, store: store, cites: cites)) })
            // Annotated, then has a PDF, then the journal PDF, then cited
            // more in the vault, then has notes, then the usual citekey
            // style, then opened more recently.
            func rank(_ x: String) -> [Int] {
                let a = f[x]!
                return [a.annotations > 0 ? 1 : 0, a.hasPDF ? 1 : 0, a.hasPDF && !a.arxivPDF ? 1 : 0,
                        a.cited, a.notes > 0 ? 1 : 0, keyStyle(metas[x]!.citekey)]
            }
            let keep = folders.sorted { x, y in
                let rx = rank(x), ry = rank(y)
                if rx != ry { return rx.lexicographicallyPrecedes(ry) == false }
                if f[x]!.lastOpened != f[y]!.lastOpened { return f[x]!.lastOpened > f[y]!.lastOpened }
                return x.count != y.count ? x.count < y.count : x < y
            }[0]
            let k = f[keep]!, others = folders.filter { $0 != keep }
            var why: [String] = []
            if k.annotations > 0 { why.append("has your \(k.annotations) annotations") }
            if k.hasPDF && !k.arxivPDF && others.contains(where: { f[$0]!.arxivPDF || !f[$0]!.hasPDF }) { why.append("journal PDF") }
            else if k.hasPDF && others.contains(where: { !f[$0]!.hasPDF }) { why.append("only one with a PDF") }
            if k.cited > 0 || others.contains(where: { f[$0]!.cited > 0 }) {
                why.append("cited in \(k.cited) vault file(s) vs " + others.map { "\(f[$0]!.cited)" }.joined(separator: "/"))
            }
            if why.isEmpty {
                let style = keyStyle(metas[keep]!.citekey)
                why.append(others.contains { keyStyle(metas[$0]!.citekey) < style } ? "usual citekey style"
                           : k.lastOpened.isEmpty ? "no difference; shorter folder name" : "opened more recently")
            }
            let titleOnly = !g.reasons.contains { $0.hasPrefix("doi ") || $0.hasPrefix("arXiv ") }
            let mainKey = folders.map { metas[$0]!.citekey }.max { a, b in
                let ca = cites[a] ?? 0, cb = cites[b] ?? 0
                if ca != cb { return ca < cb }
                if keyStyle(a) != keyStyle(b) { return keyStyle(a) < keyStyle(b) }
                if a.count != b.count { return a.count > b.count }   // "…pdf" over "…pdfa"
                return b == metas[keep]!.citekey          // ties go to the kept paper's key
            }!
            groups.append(Group(keep: keep, merge: others,
                                citekeys: Dictionary(uniqueKeysWithValues: folders.map { ($0, metas[$0]!.citekey) }),
                                titles: Dictionary(uniqueKeysWithValues: folders.map { ($0, metas[$0]!.title) }),
                                reasons: g.reasons, why: why.joined(separator: "; "),
                                citekey: mainKey, titleOnly: titleOnly))
        }
        groups.sort { ($0.titleOnly ? 0 : 1, $0.keep) < ($1.titleOnly ? 0 : 1, $1.keep) }
        return Plan(library: store.root.path, groups: groups)
    }

    // MARK: - Apply

    static func apply(_ plan: Plan, store: PaperLibraryStore) throws -> Result {
        let fm = FileManager.default
        var r = Result()
        let mergedRoot = store.root.appendingPathComponent(".merged", isDirectory: true)
        try fm.createDirectory(at: mergedRoot, withIntermediateDirectories: true)
        var log = store.read([Group].self, from: store.importDir.appendingPathComponent("merge-log.json")) ?? []

        for g in plan.groups {
            if g.skip { r.skipped += 1; continue }
            guard var keep = store.meta(folder: g.keep) else { r.problems.append("\(g.keep): not in the library"); continue }
            let kdir = store.folder(g.keep)
            var kAnns = store.read([LibraryAnnotation].self, from: kdir.appendingPathComponent("annotations.json")) ?? []
            var kFigs = store.read([LibraryFigure].self, from: kdir.appendingPathComponent("figures.json")) ?? []
            var done = true
            for o in g.merge {
                guard let m = store.meta(folder: o) else { r.problems.append("\(o): not in the library"); done = false; continue }
                let odir = store.folder(o)
                let oAnns = store.read([LibraryAnnotation].self, from: odir.appendingPathComponent("annotations.json")) ?? []
                let oFigs = store.read([LibraryFigure].self, from: odir.appendingPathComponent("figures.json")) ?? []
                let kPDF = keep.pdf.map { kdir.appendingPathComponent($0) }
                let oPDF = m.pdf.map { odir.appendingPathComponent($0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
                let samePDF = kPDF != nil && oPDF != nil && fm.contentsEqual(atPath: kPDF!.path, andPath: oPDF!.path)

                // Annotations and figure regions belong to their PDF's pages.
                if !oAnns.isEmpty && !samePDF && !(keep.pdf == nil && kAnns.isEmpty) {
                    r.problems.append("\(o): has annotations on a different PDF; left alone (keep it instead, or merge by hand)")
                    done = false; continue
                }

                // PDF
                if let oPDF {
                    if keep.pdf == nil || kPDF.map({ !fm.fileExists(atPath: $0.path) }) == true {
                        try copyItem(oPDF, to: kdir.appendingPathComponent("paper.pdf"))
                        keep.pdf = "paper.pdf"; keep.lastPage = m.lastPage
                        kAnns = oAnns; kFigs = oFigs
                    } else if !samePDF {
                        let name = uniqueName(isArxivPDF(oPDF) ? "paper-arxiv.pdf" : "paper-2.pdf", in: kdir)
                        try copyItem(oPDF, to: kdir.appendingPathComponent(name))
                    } else {
                        for a in oAnns where !kAnns.contains(where: { $0.id == a.id }) { kAnns.append(a) }
                        for f in oFigs where !kFigs.contains(f) { kFigs.append(f) }
                    }
                }

                // Everything else in the folder: notes/, chat/, suggestions, …
                let handled: Set<String> = ["meta.json", "annotations.json", "figures.json", m.pdf ?? "paper.pdf"]
                for name in (try? fm.contentsOfDirectory(atPath: odir.path)) ?? [] where !handled.contains(name) {
                    let src = odir.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: src.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        let dest = kdir.appendingPathComponent(name, isDirectory: true)
                        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                        for child in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                            try copyItem(src.appendingPathComponent(child), to: dest.appendingPathComponent(uniqueName(child, in: dest)))
                        }
                    } else {
                        try copyItem(src, to: kdir.appendingPathComponent(uniqueName(name, in: kdir)))
                    }
                }

                // Metadata
                for a in [m.citekey] + m.aliases where a != keep.citekey && !keep.aliases.contains(a) { keep.aliases.append(a) }
                keep.ids.doi = keep.ids.doi ?? m.ids.doi
                keep.ids.arxiv = keep.ids.arxiv ?? m.ids.arxiv
                keep.ids.bibcode = keep.ids.bibcode ?? m.ids.bibcode
                for t in m.tags where !keep.tags.contains(t) { keep.tags.append(t) }
                for t in m.keywords where !keep.keywords.contains(t) { keep.keywords.append(t) }
                for t in m.projects where !keep.projects.contains(t) { keep.projects.append(t) }
                let order = ["unread": 0, "reading": 1, "read": 2]
                if (order[m.status ?? ""] ?? -1) > (order[keep.status ?? ""] ?? -1) { keep.status = m.status }
                if (m.lastOpened ?? "") > (keep.lastOpened ?? "") { keep.lastOpened = m.lastOpened }
                if m.added < keep.added { keep.added = m.added }
                var zk = keep.mergedZoteroKeys ?? []
                for k in [m.zoteroKey].compactMap({ $0 }) + (m.mergedZoteroKeys ?? []) where !zk.contains(k) { zk.append(k) }
                keep.mergedZoteroKeys = zk

                // The whole folder moves aside, never deleted.
                try store.write(keep, to: kdir.appendingPathComponent("meta.json"))
                try store.write(kAnns, to: kdir.appendingPathComponent("annotations.json"))
                try store.write(kFigs, to: kdir.appendingPathComponent("figures.json"))
                try fm.moveItem(at: odir, to: mergedRoot.appendingPathComponent(uniqueName(o, in: mergedRoot), isDirectory: true))
            }
            if done, g.citekey != keep.citekey, keep.aliases.contains(g.citekey) || g.citekeys.values.contains(g.citekey) {
                keep.aliases.removeAll { $0 == g.citekey }
                if !keep.aliases.contains(keep.citekey) { keep.aliases.append(keep.citekey) }
                keep.citekey = g.citekey
                try store.write(keep, to: kdir.appendingPathComponent("meta.json"))
            }
            if done { r.merged += 1; log.append(g) }
        }
        try store.write(log, to: store.importDir.appendingPathComponent("merge-log.json"))
        return r
    }

    /// A copy-on-write clone on APFS, so a copied PDF costs no space.
    static func copyItem(_ src: URL, to dest: URL) throws {
        try FileManager.default.copyItem(at: src, to: dest)
    }

    static func uniqueName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let n = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(n).path) { return n }
            i += 1
        }
    }

    // MARK: - Report

    static func report(_ plan: Plan, store: PaperLibraryStore) -> String {
        var md = "# Duplicate papers\n\nNothing has changed yet. For each group the first paper is kept; the others "
        md += "become its aliases (their citekeys still work) and their folders move to `.merged/`.\n"
        md += "To change a group, edit `merge-plan.json` (`keep`, `merge`, or `\"skip\": true`), then run with `--apply`.\n"
        let title = plan.groups.filter(\.titleOnly), ids = plan.groups.filter { !$0.titleOnly }
        func line(_ g: Group) -> String {
            var s = "- keep `\(g.citekeys[g.keep] ?? g.keep)`"
            if g.citekeys[g.keep] != g.keep { s += " (folder `\(g.keep)`)" }
            if g.citekey != g.citekeys[g.keep] { s += ", citekey becomes `\(g.citekey)`" }
            s += " ← " + g.merge.map { "`\(g.citekeys[$0] ?? $0)`" + (g.citekeys[$0] != $0 ? " (folder `\($0)`)" : "") }.joined(separator: ", ")
            s += "\n  \(g.titles[g.keep] ?? "")\n  why: \(g.why). match: \(g.reasons.joined(separator: "; "))\n"
            for o in g.merge where g.titles[o] != g.titles[g.keep] { s += "  other title: \(g.titles[o] ?? "")\n" }
            return s
        }
        md += "\n## Matched by title only — please check (\(title.count))\n\n" + title.map(line).joined()
        md += "\n## Same DOI or arXiv id (\(ids.count))\n\n" + ids.map(line).joined()
        return md
    }
}
