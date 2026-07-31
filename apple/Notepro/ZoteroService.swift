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
        rpc("item.search", [q]) { result in
            switch result {
            case .success(let r):
                var items: [ZoteroItem] = []
                if let arr = r as? [[String: Any]] {
                    for it in arr {
                        let ck = (it["citekey"] as? String) ?? (it["citation-key"] as? String) ?? ""
                        guard !ck.isEmpty else { continue }
                        items.append(ZoteroItem(
                            citekey: ck,
                            title: it["title"] as? String ?? ck,
                            authors: authorString(it["author"]),
                            year: yearString(it["issued"])
                        ))
                    }
                }
                DispatchQueue.main.async { completion(items) }
            case .failure:
                // Zotero not running → try the cloud API.
                if ZoteroWeb.available { ZoteroWeb.search(q, completion: completion) }
                else { DispatchQueue.main.async { completion([]) } }
            }
        }
    }

    /// Export the given citekeys as biblatex (only those entries). Local BBT
    /// first; Web API fallback when Zotero is closed.
    static func exportBib(_ citekeys: [String], completion: @escaping (String) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion("") }; return }
        rpc("item.export", [keys, "biblatex"]) { result in
            switch result {
            case .success(let r):
                DispatchQueue.main.async { completion((r as? String) ?? "") }
            case .failure:
                if ZoteroWeb.available { ZoteroWeb.exportBib(keys, completion: completion) }
                else { DispatchQueue.main.async { completion("") } }
            }
        }
    }

    /// Map citekeys → "Author et al. (year)" display labels (via CSL JSON).
    static func meta(_ citekeys: [String], completion: @escaping ([String: String]) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion([:]) }; return }
        rpc("item.export", [keys, "Better CSL JSON"]) { result in
            var map: [String: String] = [:]
            if case .success(let r) = result, let s = r as? String,
               let data = s.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for it in arr {
                    guard let id = it["id"] as? String else { continue }
                    map[id] = label(for: it)
                }
            }
            DispatchQueue.main.async { completion(map) }
        }
    }

    /// Full bibliographic records for the given citekeys (Better CSL JSON →
    /// every field the literature note fills). Local BBT first, Web API fallback.
    static func fullMeta(_ citekeys: [String], completion: @escaping ([String: ZoteroMeta]) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion([:]) }; return }
        rpc("item.export", [keys, "Better CSL JSON"]) { result in
            // Rich parse needs Better BibTeX's CSL export; if Zotero is closed we
            // just return nothing (the caller keeps whatever it already had).
            let map: [String: ZoteroMeta]
            if case .success(let r) = result, let s = r as? String { map = parseCSL(s) }
            else { map = [:] }
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
