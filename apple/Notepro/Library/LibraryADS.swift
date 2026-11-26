import Foundation
import PDFKit

/// `Nebula --library-ads [--library <dir>] [--apply]`
///
/// Asks NASA ADS about the library (PAPER-LIBRARY.md §4.4):
/// - which preprints now have a journal version (citekey unchanged);
/// - the bibcode of every paper that lacks one;
/// - what each bibcode-named file in `_files/` is;
/// - which papers without a PDF have an arXiv version to download.
///
/// Without `--apply` nothing in the library changes: it writes
/// `.import/ads-report.md` and `.import/ads-plan.json`. With `--apply` it
/// updates the metadata of papers ADS matched exactly. It never downloads.
enum LibraryADS {

    /// ADS search, injectable so the self-test runs offline.
    typealias Fetch = (_ query: String, _ fields: String, _ rows: Int) throws -> [[String: Any]]

    struct Update: Codable {
        let folder: String
        let citekey: String
        var bibcode: String?
        var doi: String?
        var journal: String?
        var volume: String?
        var page: String?
        var year: String?
        var nowPublished: Bool
    }

    struct FileMatch: Codable {
        let file: String
        let hint: String
        var matches: [String]               // bibcodes; exactly one = confident
        var titles: [String]
    }

    struct Plan: Codable {
        var updates: [Update] = []
        var files: [FileMatch] = []
        var arxivPDFs: [String: String] = [:]   // folder → https://arxiv.org/pdf/<id>
        var journalOnly: [String] = []          // folders without PDF and without arXiv
        var unknown: [String] = []              // papers ADS did not find
        var duplicatesAfter: [DuplicateGroup] = []
    }

    static func runCLI() -> Never {
        let args = CommandLine.arguments
        let libPath = args.firstIndex(of: "--library").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let store = PaperLibraryStore(root: libPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                                      ?? PaperLibraryStore.defaultRoot)
        do {
            let plan = try run(store: store, apply: args.contains("--apply"), fetch: liveFetch())
            print("""
                ADS: \(plan.updates.filter(\.nowPublished).count) preprints now published, \
                \(plan.updates.filter { !$0.nowPublished }.count) papers gain a bibcode, \
                \(plan.files.filter { $0.matches.count == 1 }.count)/\(plan.files.count) files matched to one paper, \
                \(plan.arxivPDFs.count) missing PDFs available on arXiv, \(plan.journalOnly.count) journal-only, \
                \(plan.unknown.count) not found, \(plan.duplicatesAfter.count) duplicate groups after the update. \
                \(args.contains("--apply") ? "Applied." : "Nothing changed (dry run).")
                Wrote \(store.importDir.path)/ads-report.md and ads-plan.json
                """)
            exit(0)
        } catch {
            FileHandle.standardError.write("ADS step failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // MARK: - Run

    static func run(store: PaperLibraryStore, apply: Bool, fetch: Fetch) throws -> Plan {
        var plan = Plan()
        let papers = store.allPapers()
        let fl = "bibcode,doi,pub,volume,page,year,identifier,doctype,title"

        // 1. Look every paper up by its identifiers, 25 per query.
        var byIdentifier: [String: [String: Any]] = [:]
        let queries: [(String, String)] = papers.flatMap { p -> [(String, String)] in
            var q: [(String, String)] = []
            if let b = p.meta.ids.bibcode { q.append((p.folder, "bibcode:\"\(b)\"")) }
            if let a = p.meta.ids.arxiv { q.append((p.folder, "identifier:\"arXiv:\(a)\"")) }
            if let d = p.meta.ids.doi, !d.hasPrefix("10.48550/") { q.append((p.folder, "doi:\"\(d)\"")) }
            return q
        }
        for chunk in stride(from: 0, to: queries.count, by: 25).map({ Array(queries[$0..<min($0 + 25, queries.count)]) }) {
            let docs = try fetch(chunk.map(\.1).joined(separator: " OR "), fl, 100)
            for d in docs {
                for id in (d["identifier"] as? [String] ?? []) + (d["doi"] as? [String] ?? []) + [d["bibcode"] as? String ?? ""] {
                    byIdentifier[id.lowercased()] = d
                }
            }
        }
        func lookup(_ m: PaperMeta) -> [String: Any]? {
            [m.ids.bibcode, m.ids.arxiv.map { "arxiv:\($0)" }, m.ids.doi]
                .compactMap { $0?.lowercased() }.lazy.compactMap { byIdentifier[$0] }.first
        }

        for p in papers {
            let m = p.meta
            guard let d = lookup(m) else {
                if m.ids.arxiv != nil || m.ids.doi != nil || m.ids.bibcode != nil { plan.unknown.append(p.folder) }
                if m.pdf == nil { plan.journalOnly.append(p.folder) }
                continue
            }
            let bib = d["bibcode"] as? String
            let published = !(bib ?? "").contains("arXiv") && (d["doctype"] as? String) != "eprint"
            let nowPublished = m.version == "preprint" && published
            if nowPublished || (m.ids.bibcode == nil && bib != nil) {
                plan.updates.append(Update(
                    folder: p.folder, citekey: m.citekey, bibcode: bib,
                    doi: (d["doi"] as? [String])?.first?.lowercased(),
                    journal: nowPublished ? d["pub"] as? String : nil,
                    volume: nowPublished ? d["volume"] as? String : nil,
                    page: nowPublished ? (d["page"] as? [String])?.first : nil,
                    year: nowPublished ? d["year"] as? String : nil,
                    nowPublished: nowPublished))
            }
            if m.pdf == nil {
                if let a = m.ids.arxiv ?? arxivID(in: d) { plan.arxivPDFs[p.folder] = "https://arxiv.org/pdf/\(a)" }
                else { plan.journalOnly.append(p.folder) }
            }
        }

        // 2. Bibcode-named files: search by year / journal / volume / page,
        //    then pick by title words found on the PDF's first page.
        let files = store.read([FileEntry].self, from: store.filesDir.appendingPathComponent("files.json")) ?? []
        for f in files {
            guard let hint = f.paperCandidate, let q = bibcodeQuery(hint) else { continue }
            let docs = try fetch(q, "bibcode,title", 20)
            var match = FileMatch(file: f.name, hint: hint,
                                  matches: docs.compactMap { $0["bibcode"] as? String },
                                  titles: docs.map { ($0["title"] as? [String])?.first ?? "" })
            if match.matches.count > 1, let text = firstPageText(store.filesDir.appendingPathComponent(f.name)) {
                let scored = zip(match.matches, match.titles).map { ($0, $1, titleScore($1, in: text)) }
                if let best = scored.max(by: { $0.2 < $1.2 }), best.2 >= 0.6,
                   scored.filter({ $0.2 >= 0.6 }).count == 1 {
                    match.matches = [best.0]; match.titles = [best.1]
                }
            }
            plan.files.append(match)
        }

        // 3. Apply exact matches.
        if apply {
            for u in plan.updates {
                guard var m = store.meta(folder: u.folder) else { continue }
                if let b = u.bibcode { m.ids.bibcode = b }
                if u.nowPublished {
                    if let d = u.doi { m.ids.doi = d; m.bibliographic.fields["DOI"] = d }
                    if let j = u.journal { m.bibliographic.fields["publicationTitle"] = j }
                    if let v = u.volume { m.bibliographic.fields["volume"] = v }
                    if let pg = u.page { m.bibliographic.fields["pages"] = pg }
                    if let y = u.year { m.year = y; m.bibliographic.fields["date"] = y }
                    m.version = "published"
                }
                try store.write(m, to: store.folder(u.folder).appendingPathComponent("meta.json"))
            }
        }

        // 4. Duplicates as they will be after the update (journal DOIs now
        //    shared by a preprint and its separately-imported journal copy).
        let after = store.allPapers().map { p -> PlannedPaper in
            var m = p.meta
            if !apply, let u = plan.updates.first(where: { $0.folder == p.folder }) {
                m.ids.bibcode = u.bibcode ?? m.ids.bibcode
                if u.nowPublished, let d = u.doi { m.ids.doi = d }
            }
            return PlannedPaper(zoteroKey: m.zoteroKey ?? p.folder, citekey: m.citekey, folder: p.folder,
                                itemType: m.bibliographic.itemType, title: m.title, year: m.year, authors: [],
                                ids: m.ids, pdf: nil, otherAttachments: 0, annotations: AnnotationCounts(),
                                projects: [], tags: [], keywords: [], status: nil, childNotes: 0, issues: [])
        }
        plan.duplicatesAfter = ZoteroImportPlanner.duplicates(after)

        try store.write(plan, to: store.importDir.appendingPathComponent("ads-plan.json"))
        try markdown(plan, applied: apply).write(to: store.importDir.appendingPathComponent("ads-report.md"),
                                                 atomically: true, encoding: .utf8)
        return plan
    }

    // MARK: - Helpers

    static func arxivID(in d: [String: Any]) -> String? {
        for id in d["identifier"] as? [String] ?? [] where id.lowercased().hasPrefix("arxiv:") {
            return String(id.dropFirst(6))
        }
        return nil
    }

    /// "1994A&A...291..943O" or a cut-short "1987A&A...186." → an ADS query.
    static func bibcodeQuery(_ hint: String) -> String? {
        if hint.count == 19 { return "bibcode:\"\(hint)\"" }
        guard hint.count >= 9 else { return nil }
        let year = hint.prefix(4)
        let rest = hint.dropFirst(4)
        let stem = String(rest.prefix(5)).replacingOccurrences(of: ".", with: "")
        let after = rest.dropFirst(5)
        let numbers = after.split(separator: ".").filter { !$0.isEmpty }
        var q = "year:\(year) bibstem:\"\(stem)\""
        if let v = numbers.first, Int(v) != nil { q += " volume:\(v)" }
        if numbers.count > 1 {
            let page = numbers[1].filter(\.isNumber)
            if !page.isEmpty { q += " page:\(page)" }
        }
        return q
    }

    static func firstPageText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let text = (0..<min(2, doc.pageCount)).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
        return text.isEmpty ? nil : text.lowercased()
    }

    /// Share of a title's longer words that appear in the text.
    static func titleScore(_ title: String, in text: String) -> Double {
        let words = title.lowercased().split { !$0.isLetter }.filter { $0.count > 3 }
        guard !words.isEmpty else { return 0 }
        return Double(words.filter { text.contains($0) }.count) / Double(words.count)
    }

    static func liveFetch() -> Fetch {
        let token = LiteratureSearch.adsToken
        return { q, fl, rows in
            guard !token.isEmpty else { throw ZoteroImportError.missing("No ADS token in Nebula's settings") }
            // Bibcodes contain "&" and "+"; URLQueryItem would leave them raw.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+?")
            func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
            let url = URL(string: "https://api.adsabs.harvard.edu/v1/search/query?q=\(enc(q))&fl=\(enc(fl))&rows=\(rows)")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 30
            var out: Result<[[String: Any]], Error> = .success([])
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { data, resp, err in
                defer { done.signal() }
                if let err { out = .failure(err); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let docs = (obj["response"] as? [String: Any])?["docs"] as? [[String: Any]] else {
                    out = .failure(ZoteroImportError.database("ADS answered HTTP \(status)")); return
                }
                out = .success(docs)
            }.resume()
            done.wait()
            return try out.get()
        }
    }

    // MARK: - Report

    static func markdown(_ p: Plan, applied: Bool) -> String {
        var md = "# ADS check of the paper library\n\n"
        md += applied ? "Exact matches below were applied to meta.json.\n" : "Dry run: nothing in the library changed. Run with `--apply` to update metadata.\n"
        let pub = p.updates.filter(\.nowPublished)
        md += "\n## Preprints with a journal version (\(pub.count))\n\nCitekeys stay the same.\n\n"
        md += pub.map { "- `\($0.citekey)` → \($0.journal ?? "?") \($0.volume ?? "") \($0.page ?? "") (\($0.year ?? "")) `\($0.bibcode ?? "")`\n" }.joined()
        let bib = p.updates.filter { !$0.nowPublished }
        md += "\n## Papers that gain a bibcode (\(bib.count))\n"
        md += "\n## Files that look like papers (\(p.files.count))\n\n"
        md += p.files.map { f -> String in
            let what = f.matches.count == 1 ? "→ `\(f.matches[0])` \(f.titles[0])"
                : f.matches.isEmpty ? "no match" : "\(f.matches.count) candidates: " + f.matches.prefix(5).map { "`\($0)`" }.joined(separator: ", ")
            return "- \(f.file): \(what)\n"
        }.joined()
        md += "\n## Missing PDFs\n\n- Available on arXiv (download needs your OK): \(p.arxivPDFs.count)\n- Journal only (download from the publisher yourself): \(p.journalOnly.count)\n\n"
        md += p.arxivPDFs.sorted { $0.key < $1.key }.map { "- `\($0.key)` — \($0.value)\n" }.joined()
        md += "\n## Not found in ADS (\(p.unknown.count))\n\n" + p.unknown.map { "- `\($0)`\n" }.joined()
        md += "\n## Duplicates after the update (\(p.duplicatesAfter.count))\n\n"
        md += p.duplicatesAfter.map { g in "- " + g.citekeys.map { "`\($0)`" }.joined(separator: ", ") + " — " + g.reasons.joined(separator: "; ") + "\n" }.joined()
        return md
    }
}
