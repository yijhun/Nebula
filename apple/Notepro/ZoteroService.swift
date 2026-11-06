import Foundation

/// One Zotero library item (from Better BibTeX).
struct ZoteroItem: Identifiable, Hashable {
    let citekey: String
    let title: String
    let authors: String
    let year: String
    var id: String { citekey }
}

/// The full bibliographic record for one item, parsed from Better CSL JSON —
/// everything the literature note wants to auto-fill.
struct ZoteroMeta {
    var citekey = ""
    var title = ""
    var authors = ""      // "Family, Family et al."
    var year = ""
    var journal = ""      // container-title
    var volume = ""
    var pages = ""
    var doi = ""
    var url = ""
    var abstract = ""
}

/// Talks to the local Better BibTeX JSON-RPC endpoint (no cloud / API key).
/// Requires Zotero running with the Better BibTeX plugin.
enum ZoteroService {
    static let endpoint = URL(string: "http://localhost:23119/better-bibtex/json-rpc")!

    enum ZError: LocalizedError {
        case notRunning, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: return "無法連線 Zotero（請開啟 Zotero 並安裝 Better BibTeX）"
            case .badResponse(let m): return "Zotero 回應錯誤：\(m)"
            }
        }
    }

    /// Whether Zotero integration is enabled in Settings (default on).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "zoteroEnabled") as? Bool ?? true }

    private static func rpc(_ method: String, _ params: [Any],
                            _ completion: @escaping (Result<Any, Error>) -> Void) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": method, "params": params, "id": 1,
        ])
        URLSession.shared.dataTask(with: req) { data, _, error in
            if error != nil { completion(.failure(ZError.notRunning)); return }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(.failure(ZError.badResponse("invalid JSON"))); return }
            if let result = obj["result"] { completion(.success(result)) }
            else {
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                completion(.failure(ZError.badResponse(msg)))
            }
        }.resume()
    }

    /// Search the library; returns items with citekeys (main-thread completion).
    /// Tries local Better BibTeX first; if Zotero isn't running, falls back to
    /// the Zotero Web API (when a userID + API key are configured).
    static func search(_ query: String, completion: @escaping ([ZoteroItem]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !q.isEmpty else { DispatchQueue.main.async { completion([]) }; return }
        let finish = { (items: [ZoteroItem]) in DispatchQueue.main.async { completion(items) } }
        // Title / creator / year — the mode Zotero's own search bar starts in.
        searchLocal(q, mode: "quicksearch-titleCreatorYear") { hits in
            if let hits, !hits.isEmpty { finish(hits); return }
            // Nothing there: the words are probably in an abstract or the
            // attached PDF, so widen the net before giving up.
            searchLocal(q, mode: "quicksearch-everything") { wide in
                if let wide { finish(wide) }
                else if hits != nil { finish([]) }              // Zotero answered, just no match
                else if ZoteroWeb.available { ZoteroWeb.search(q, completion: completion) }
                else { finish([]) }                             // Zotero closed, no cloud key
            }
        }
    }

    /// One local Better BibTeX search. `nil` means Zotero was unreachable or
    /// refused the query — an empty array means it answered with no matches.
    ///
    /// The query has to go over as a structured condition. Passing it as a bare
    /// string makes Better BibTeX build a grouped search that current Zotero
    /// rejects ("Invalid condition 'blockStart'"), and the error surfaced as an
    /// empty result list — the citation picker simply found no papers, ever.
    private static func searchLocal(_ q: String, mode: String,
                                    _ completion: @escaping ([ZoteroItem]?) -> Void) {
        rpc("item.search", [[[mode, "contains", q]]]) { result in
            guard case .success(let r) = result, let arr = r as? [[String: Any]] else {
                completion(nil); return
            }
            completion(arr.compactMap { it in
                let ck = (it["citekey"] as? String) ?? (it["citation-key"] as? String) ?? ""
                guard !ck.isEmpty else { return nil }
                return ZoteroItem(citekey: ck,
                                  title: it["title"] as? String ?? ck,
                                  authors: authorString(it["author"]),
                                  year: yearString(it["issued"]))
            })
        }
    }

    /// Export `keys` in `format`, tolerating keys the library doesn't have.
    ///
    /// Better BibTeX refuses a whole export when any one key is unknown
    /// ("not found: …"). A note with a single stale citation then lost every
    /// other citation's label in the preview, and its entire bibliography in
    /// PDF export. So when the batch is refused, each key is exported on its
    /// own and whatever resolves is kept. `chunks` are export payloads (one per
    /// successful call); `reachable` is false only when Zotero didn't answer.
    private static func exportTolerant(_ keys: [String], format: String,
                                       completion: @escaping (_ chunks: [String], _ reachable: Bool) -> Void) {
        rpc("item.export", [keys, format]) { result in
            switch result {
            case .success(let r):
                completion([(r as? String) ?? ""], true)
            case .failure(let error):
                if case ZError.notRunning = error { completion([], false); return }
                guard keys.count > 1 else { completion([], true); return }
                let group = DispatchGroup()
                let lock = NSLock()
                var chunks: [String] = []
                for key in keys {
                    group.enter()
                    rpc("item.export", [[key], format]) { one in
                        if case .success(let r) = one, let s = r as? String {
                            lock.lock(); chunks.append(s); lock.unlock()
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .global()) { completion(chunks, true) }
            }
        }
    }

    /// Which .bib dialect to export. biblatex styles read `date` and
    /// `journaltitle`; classic .bst styles (ApJ's aasjournal, mnras, aa) only
    /// read `year` and `journal`, and printed "????" for every year when fed
    /// the biblatex export.
    enum BibFormat { case biblatex, bibtex }

    /// Export the given citekeys (only those entries). Local BBT first; Web
    /// API fallback when Zotero is closed. Keys the library lacks are skipped
    /// rather than emptying the whole bibliography.
    static func exportBib(_ citekeys: [String], format: BibFormat = .biblatex,
                          completion: @escaping (String) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion("") }; return }
        let translator = format == .bibtex ? "Better BibTeX" : "biblatex"
        exportTolerant(keys, format: translator) { chunks, reachable in
            if !reachable, ZoteroWeb.available { ZoteroWeb.exportBib(keys, completion: completion); return }
            // A&A titles arrive with their footnote stars ("…Feedback⋆⋆⋆").
            // They aren't part of the title, and Latin Modern has no ⋆ glyph,
            // so they'd print as gaps in the reference list.
            var bib = chunks.joined(separator: "\n")
                .replacingOccurrences(of: "⋆", with: "")
                .replacingOccurrences(of: "★", with: "")
                .replacingOccurrences(of: "{$\\star$}", with: "")
            if format == .bibtex { bib = abbreviateJournals(bib) }
            DispatchQueue.main.async { completion(bib) }
        }
    }

    /// Journal names as ApJ prints them. Zotero stores the full name
    /// ("The Astrophysical Journal"); the .bst prints the field verbatim.
    private static let journalAbbrev: [String: String] = [
        "astrophysical journal": "ApJ",
        "astrophysical journal letters": "ApJL",
        "astrophysical journal. letters": "ApJL",
        "astrophysical journal supplement series": "ApJS",
        "astrophysical journal supplement": "ApJS",
        "astronomical journal": "AJ",
        "astronomy & astrophysics": "A\\&A",
        "astronomy and astrophysics": "A\\&A",
        "astronomy & astrophysics supplement series": "A\\&AS",
        "astronomy and astrophysics supplement series": "A\\&AS",
        "astronomy and astrophysics review": "A\\&ARv",
        "monthly notices of the royal astronomical society": "MNRAS",
        "annual review of astronomy and astrophysics": "ARA\\&A",
        "publications of the astronomical society of the pacific": "PASP",
        "publications of the astronomical society of japan": "PASJ",
        "publications of the astronomical society of australia": "PASA",
        "astrophysics and space science": "Ap\\&SS",
        "space science reviews": "SSRv",
        "nature astronomy": "NatAs",
        "astronomische nachrichten": "AN",
        "new astronomy": "NewA",
        "new astronomy reviews": "NewAR",
        "journal of quantitative spectroscopy and radiative transfer": "JQSRT",
        "journal of molecular spectroscopy": "JMoSp",
        "journal of physical and chemical reference data": "JPCRD",
        "physical review letters": "PhRvL",
        "physical review d": "PhRvD",
        "reviews of modern physics": "RvMP",
    ]

    static func abbreviateJournals(_ bib: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"(?m)^(\s*journal\s*=\s*\{)(.*)(\},?\s*)$"#) else { return bib }
        let ns = bib as NSString
        var out = bib
        for m in re.matches(in: bib, range: NSRange(location: 0, length: ns.length)).reversed() {
            let raw = ns.substring(with: m.range(at: 2))
            var key = raw.replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .replacingOccurrences(of: "\\&", with: "&")
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("the ") { key.removeFirst(4) }
            guard let abbr = journalAbbrev[key] else { continue }
            let replaced = ns.substring(with: m.range(at: 1)) + abbr + ns.substring(with: m.range(at: 3))
            out = (out as NSString).replacingCharacters(in: m.range, with: replaced)
        }
        return out
    }

    /// Parse Better CSL JSON export payloads into one list of records.
    private static func cslRecords(_ chunks: [String]) -> [[String: Any]] {
        chunks.flatMap { s -> [[String: Any]] in
            guard let data = s.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return arr
        }
    }

    /// Map citekeys → "Author et al. (year)" display labels (via CSL JSON).
    static func meta(_ citekeys: [String], completion: @escaping ([String: String]) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion([:]) }; return }
        exportTolerant(keys, format: "Better CSL JSON") { chunks, _ in
            var map: [String: String] = [:]
            for it in cslRecords(chunks) {
                guard let id = it["id"] as? String else { continue }
                map[id] = label(for: it)
            }
            DispatchQueue.main.async { completion(map) }
        }
    }

    /// Full bibliographic records for the given citekeys (Better CSL JSON →
    /// every field the literature note fills). Local BBT first, Web API fallback.
    static func fullMeta(_ citekeys: [String], completion: @escaping ([String: ZoteroMeta]) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion([:]) }; return }
        exportTolerant(keys, format: "Better CSL JSON") { chunks, _ in
            // Rich parse needs Better BibTeX's CSL export; if Zotero is closed we
            // just return nothing (the caller keeps whatever it already had).
            var map: [String: ZoteroMeta] = [:]
            for chunk in chunks { map.merge(parseCSL(chunk)) { a, _ in a } }
            DispatchQueue.main.async { completion(map) }
        }
    }

    /// Parse a Better CSL JSON array into citekey → ZoteroMeta.
    private static func parseCSL(_ s: String) -> [String: ZoteroMeta] {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var map: [String: ZoteroMeta] = [:]
        for it in arr {
            guard let id = it["id"] as? String else { continue }
            var m = ZoteroMeta(citekey: id)
            m.title = (it["title"] as? String) ?? ""
            m.authors = authorString(it["author"])
            m.year = yearString(it["issued"])
            m.journal = (it["container-title"] as? String) ?? ""
            m.volume = stringField(it["volume"])
            m.pages = stringField(it["page"])
            m.doi = (it["DOI"] as? String) ?? ""
            m.url = (it["URL"] as? String) ?? ""
            m.abstract = (it["abstract"] as? String) ?? ""
            map[id] = m
        }
        return map
    }

    /// One attachment of a library item.
    struct Attachment {
        let path: String        // local file path
        let itemKey: String     // Zotero attachment key (also its storage folder)
        var isPDF: Bool { path.lowercased().hasSuffix(".pdf") }
    }

    /// Local attachments for a citekey (Better BibTeX `item.attachments`).
    /// The `open` field looks like `zotero://open-pdf/library/items/<KEY>`;
    /// that KEY is also the storage folder name and the key the zotero-figure
    /// plugin caches its analysis under.
    static func attachments(_ citekey: String, completion: @escaping ([Attachment]) -> Void) {
        let key = citekey.trimmingCharacters(in: .whitespaces)
        guard enabled, !key.isEmpty else { DispatchQueue.main.async { completion([]) }; return }
        rpc("item.attachments", [key]) { result in
            var out: [Attachment] = []
            if case .success(let r) = result, let arr = r as? [[String: Any]] {
                for a in arr {
                    let path = a["path"] as? String ?? ""
                    guard !path.isEmpty else { continue }
                    let open = a["open"] as? String ?? ""
                    let itemKey = open.components(separatedBy: "/").last ?? ""
                    out.append(Attachment(path: path, itemKey: itemKey))
                }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Find the citekey of the library item matching an anchor. Prefers DOI,
    /// then arXiv id, then a title query. Returns nil if nothing matches.
    static func resolveCitekey(doi: String = "", arxiv: String = "", title: String = "",
                               completion: @escaping (String?) -> Void) {
        let doi = doi.trimmingCharacters(in: .whitespaces)
        let arxiv = arxiv.trimmingCharacters(in: .whitespaces)
        let title = title.trimmingCharacters(in: .whitespaces)
        let query = !doi.isEmpty ? doi : (!arxiv.isEmpty ? arxiv : title)
        guard enabled, !query.isEmpty else { DispatchQueue.main.async { completion(nil) }; return }
        search(query) { items in
            // DOI/arXiv are unique enough to take the first hit; a title query
            // only counts if it's an exact (case-insensitive) title match.
            if !doi.isEmpty || !arxiv.isEmpty {
                completion(items.first?.citekey)
            } else {
                let want = title.lowercased()
                completion(items.first(where: { $0.title.lowercased() == want })?.citekey
                           ?? (items.count == 1 ? items.first?.citekey : nil))
            }
        }
    }

    private static func stringField(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        return ""
    }

    /// "Family et al. (year)" / "Family (year)" from a CSL item.
    private static func label(for it: [String: Any]) -> String {
        let authors = it["author"] as? [[String: Any]] ?? []
        let year = yearString(it["issued"])
        let first = (authors.first?["family"] as? String)
            ?? (authors.first?["literal"] as? String) ?? "?"
        let name = authors.count >= 2 ? "\(first) et al." : first
        return year.isEmpty ? name : "\(name) (\(year))"
    }

    private static func authorString(_ any: Any?) -> String {
        guard let arr = any as? [[String: Any]] else { return "" }
        let names = arr.prefix(3).map { a -> String in
            (a["family"] as? String) ?? (a["literal"] as? String) ?? ""
        }.filter { !$0.isEmpty }
        let s = names.joined(separator: ", ")
        return arr.count > 3 ? s + " et al." : s
    }

    private static func yearString(_ any: Any?) -> String {
        guard let issued = any as? [String: Any],
              let parts = issued["date-parts"] as? [[Any]],
              let first = parts.first, let y = first.first else { return "" }
        if let i = y as? Int { return String(i) }
        return String(describing: y)
    }
}
