import Foundation

/// `Nebula --zotero-import-report --out <dir> [--zotero <dir>] [--vault <dir>] [--mapping <file>]`
///
/// The dry run before moving the library out of Zotero (PAPER-LIBRARY.md §5.2):
/// reads a snapshot copy of Zotero's database, plans where every item would
/// go, and writes three files to `<dir>` — nothing else is written:
///
/// - `report.md`: what will happen, problems first, for the user to read;
/// - `plan.json`: the same plan, for the real import to consume later;
/// - `collection-mapping.json`: what each collection becomes (project / tag /
///   drop). Edit it and pass it back with `--mapping` to change the plan.
enum ZoteroImportReport {

    static func runCLI() -> Never {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return (args[i + 1] as NSString).expandingTildeInPath
        }
        guard let out = value("--out") else {
            FileHandle.standardError.write("usage: Nebula --zotero-import-report --out <dir> [--zotero <dir>] [--vault <dir>] [--mapping <file>]\n".data(using: .utf8)!)
            exit(2)
        }
        let zdir = URL(fileURLWithPath: value("--zotero") ?? (NSHomeDirectory() + "/Zotero"))
        do {
            let summary = try generate(zoteroDir: zdir, outDir: URL(fileURLWithPath: out),
                                       vault: value("--vault").map { URL(fileURLWithPath: $0) },
                                       mappingFile: value("--mapping").map { URL(fileURLWithPath: $0) })
            print(summary)
            exit(0)
        } catch {
            FileHandle.standardError.write("Import report failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    /// Snapshot → plan → files. Returns a one-paragraph summary.
    @discardableResult
    static func generate(zoteroDir: URL, outDir: URL, vault: URL?, mappingFile: URL?,
                         dbPathOverride: URL? = nil) throws -> String {
        let fm = FileManager.default
        let snapshot = try dbPathOverride ?? ZoteroSnapshot.copy(zoteroDir: zoteroDir)
        defer { if dbPathOverride == nil { try? fm.removeItem(at: snapshot.deletingLastPathComponent()) } }
        let lib = try ZoteroSnapshot.read(dbPath: snapshot,
                                          storageDir: zoteroDir.appendingPathComponent("storage"))

        var mapping: [String: CollectionAction]?
        if let mf = mappingFile {
            let rules = try JSONDecoder().decode([String: CollectionRule].self, from: Data(contentsOf: mf))
            mapping = rules.mapValues(\.action)
        }
        var plan = ZoteroImportPlanner.plan(lib, zoteroDir: zoteroDir, mapping: mapping)
        if let v = vault { plan.vault = checkVault(v, plan: plan) }

        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(plan).write(to: outDir.appendingPathComponent("plan.json"))
        try enc.encode(plan.collections).write(to: outDir.appendingPathComponent("collection-mapping.json"))
        try markdown(plan).write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)

        let t = plan.totals
        return "\(t.papers) papers (\(t.withPDF) with PDF), \(t.duplicateGroups) duplicate groups, "
            + "\(t.orphanPDFs + t.orphanFiles + t.orphanLinks + t.orphanNotes) items without a parent, "
            + "\(plan.papers.filter { !$0.issues.isEmpty }.count) papers with issues"
            + (plan.vault.map { ", \($0.unresolved.count) unresolved vault citations" } ?? "")
            + (t.invariantFailures.isEmpty ? "." : ". INVARIANTS FAILED: \(t.invariantFailures.joined(separator: "; "))")
            + "\nWrote \(outDir.path)/report.md, plan.json, collection-mapping.json"
    }

    // MARK: - Vault check (§5.4: every cited key must resolve)

    static func checkVault(_ vault: URL, plan: ImportPlan) -> VaultCheck {
        let known = Set(plan.papers.map(\.citekey))
        var cited = Set<String>(), bibKeys = Set<String>(), files = 0
        let bibEntry = try! NSRegularExpression(pattern: #"(?m)^\s*@[A-Za-z]+\s*\{\s*([^,\s]+)\s*,"#)
        let fm = FileManager.default
        let it = fm.enumerator(at: vault, includingPropertiesForKeys: nil,
                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = it?.nextObject() as? URL {
            let ext = u.pathExtension.lowercased()
            guard ["md", "tex", "bib"].contains(ext),
                  let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
            if ext == "bib" {
                let ns = s as NSString
                for m in bibEntry.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    bibKeys.insert(ns.substring(with: m.range(at: 1)))
                }
                continue
            }
            files += 1
            cited.formUnion(citedKeys(in: s))
        }
        let unresolved = cited.subtracting(known)
        let trash = unresolved.intersection(plan.trashedCitekeys)
        let bib = unresolved.subtracting(trash).intersection(bibKeys)
        return VaultCheck(vault: vault.path, filesScanned: files, citedKeys: cited.count,
                          unresolved: unresolved.sorted(), inZoteroTrash: trash.sorted(),
                          onlyInVaultBib: bib.sorted(),
                          notFound: unresolved.subtracting(trash).subtracting(bib).sorted())
    }

    /// Pandoc `[@key; @key2]` and LaTeX `\cite{a,b}`, `\autocite{…}`, `\textcite[…]{…}`, ….
    static func citedKeys(in s: String) -> Set<String> {
        var out = Set<String>()
        let ns = s as NSString
        let bracket = try! NSRegularExpression(pattern: #"\[[^\[\]\n]*@[^\[\]\n]*\]"#)
        let atKey = try! NSRegularExpression(pattern: #"(?:^|[\s;\[-])@([A-Za-z0-9_][A-Za-z0-9_:.#$%&+?<>~/-]*[A-Za-z0-9_])"#)
        for m in bracket.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range)
            let ins = inner as NSString
            for k in atKey.matches(in: inner, range: NSRange(location: 0, length: ins.length)) {
                out.insert(ins.substring(with: k.range(at: 1)))
            }
        }
        // Any command with "cite" in it: \cite, \citep, \autocite (the
        // editor's default), \textcite, \parencite, \footcite, \Citet, …
        let cite = try! NSRegularExpression(pattern: #"\\[A-Za-z]*[cC]ite[A-Za-z]*\*?(?:\[[^\]]*\]){0,2}\{([^}]*)\}"#)
        for m in cite.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            for k in ns.substring(with: m.range(at: 1)).split(separator: ",") {
                let key = k.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, key != "*" { out.insert(key) }
            }
        }
        return out
    }

    // MARK: - Markdown

    static func markdown(_ p: ImportPlan) -> String {
        let t = p.totals
        var md = """
        # Zotero → Nebula import: dry run

        Generated \(p.generated) from a copy of `\(p.zoteroDir)/zotero.sqlite`.
        Nothing has been imported; Zotero was not changed.

        ## Summary

        | | Count |
        |---|---|
        | Papers to import (live items) | \(t.papers) |
        | … with a PDF | \(t.withPDF) |
        | … without a PDF | \(t.withoutPDF) |
        | PDF listed but file missing | \(t.missingPDFFiles) |
        | Items in the trash (not imported) | \(t.trashedItems) |
        | Duplicate groups | \(t.duplicateGroups) |
        | PDFs / files / links / notes without a parent | \(t.orphanPDFs) / \(t.orphanFiles) / \(t.orphanLinks) / \(t.orphanNotes) |
        | Highlights / notes / ink | \(t.annotations.highlight) / \(t.annotations.note) / \(t.annotations.ink) |
        | Image annotations → figure regions | \(t.annotations.figureRegions) |
        | Annotations on parentless PDFs / in trash | \(t.annotationsOnOrphans) / \(t.annotationsSkipped) |

        """
        md += t.invariantFailures.isEmpty
            ? "\nChecks: every live item is planned once, and every attachment and annotation is accounted for.\n"
            : "\n**Checks failed:**\n" + t.invariantFailures.map { "- \($0)\n" }.joined()

        if let v = p.vault {
            md += "\n## Citations in the vault\n\nScanned \(v.filesScanned) notes in `\(v.vault)`: \(v.citedKeys) distinct keys cited, "
            if v.unresolved.isEmpty {
                md += "all of them resolve.\n"
            } else {
                md += "**\(v.unresolved.count) do not resolve** to an imported paper.\n"
                md += keyList("In Zotero's trash (restore them before importing, or they stay unresolved)", v.inZoteroTrash)
                md += keyList("Only in a .bib file in the vault (not in Zotero)", v.onlyInVaultBib)
                md += keyList("Not in Zotero or any .bib file in the vault (hidden folders skipped)", v.notFound)
            }
        }

        md += "\n## Duplicates (decide which to keep)\n\n"
        md += p.duplicates.isEmpty ? "None found.\n" : p.duplicates.map(dupLine).joined()

        let issues = p.papers.filter { !$0.issues.isEmpty }
        md += "\n## Papers with issues\n\n"
        md += issues.isEmpty ? "None.\n" : issues.map(issueLine).joined()

        let noPDF = p.papers.filter { $0.pdf == nil }
        md += "\n## Papers without a PDF (\(noPDF.count))\n\n"
        md += noPDF.map { paper -> String in
            let id = paper.ids.arxiv.map { "arXiv \($0)" } ?? paper.ids.doi.map { "doi \($0)" } ?? "no identifier"
            return "- `\(paper.citekey)` — \(paper.title.prefix(80)) (\(id))\n"
        }.joined()

        md += "\n## Items without a parent paper\n\n"
        md += p.orphans.isEmpty ? "None.\n" : "These have no place in the one-folder-per-paper layout yet; decide what each is.\n\n" + p.orphans.map(orphanLine).joined()

        md += "\n## Collections\n\nEdit `collection-mapping.json` (project / tag / drop) and run again with `--mapping` to change these.\n\n| Collection | Papers | Standalone files | Becomes | Why |\n|---|---|---|---|---|\n"
        for (name, r) in p.collections.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            md += "| \(name) | \(r.papers) | \(r.files) | \(r.action.rawValue) | \(r.reason) |\n"
        }

        let statuses = Dictionary(grouping: p.papers.compactMap(\.status), by: { $0 }).mapValues(\.count)
        let kw = Set(p.papers.flatMap(\.keywords)).count, tags = Set(p.papers.flatMap(\.tags)).count
        md += "\n## Tags\n\n- Reading status from tags: " + (statuses.isEmpty ? "none" : statuses.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) + "\n"
        md += "- Journal keywords (kept as `keywords`, not tags): \(kw) distinct\n- Your tags after the import (incl. topic collections): \(tags) distinct\n"

        md += "\n## All papers\n\n| Citekey | Year | PDF | Highlights | Figure regions | Projects |\n|---|---|---|---|---|---|\n"
        for x in p.papers { md += paperRow(x) }
        return md
    }

    private static func keyList(_ heading: String, _ keys: [String]) -> String {
        guard !keys.isEmpty else { return "" }
        return "\n\(heading), \(keys.count):\n\n" + keys.map { "- `\($0)`\n" }.joined()
    }

    private static func dupLine(_ g: DuplicateGroup) -> String {
        let keys = g.citekeys.map { "`\($0)`" }.joined(separator: ", ")
        return "- \(keys) — \(g.reasons.joined(separator: "; "))\n"
    }

    private static func issueLine(_ paper: PlannedPaper) -> String {
        "- `\(paper.citekey)`: \(paper.issues.joined(separator: "; "))\n"
    }

    private static func orphanLine(_ o: Orphan) -> String {
        let missing = o.exists == false ? " (file missing)" : ""
        let colls = o.collections.isEmpty ? "" : " — in \(o.collections.joined(separator: ", "))"
        return "- \(o.kind.rawValue): \(o.label)\(missing)\(colls)\n"
    }

    private static func paperRow(_ x: PlannedPaper) -> String {
        let pdf: String = x.pdf == nil ? "—" : (x.pdf!.exists ? "yes" : "missing")
        let projects = x.projects.joined(separator: ", ")
        return "| `\(x.citekey)` | \(x.year) | \(pdf) | \(x.annotations.highlight) | \(x.annotations.figureRegions) | \(projects) |\n"
    }
}
