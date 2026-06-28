import Foundation

/// Zotero Web API fallback — used when the local Better BibTeX endpoint isn't
/// reachable (Zotero app not running). Reads the user's synced cloud library
/// with a personal API key, so citations work offline-of-Zotero.
///
/// Citekey handling: Better BibTeX stores its pinned citation key in the item's
/// `extra` field ("Citation Key: foo2020"). We prefer that so inserted
/// `[@citekey]`s match; otherwise we synthesize firstauthor+year. The Web API
/// itself indexes by 8-char item keys, so we keep a citekey→itemKey cache and,
/// at export time, rewrite each entry's BibTeX key to the user's citekey so the
/// `\cite{}`s resolve.
enum ZoteroWeb {
    static var userID: String { UserDefaults.standard.string(forKey: "zoteroUserID") ?? "" }
    static var apiKey: String { UserDefaults.standard.string(forKey: "zoteroAPIKey") ?? "" }
    static var available: Bool {
        ZoteroService.enabled && !userID.isEmpty && !apiKey.isEmpty
    }

    /// Cached citekey → Zotero item key, filled during search and reused at export.
    private static var keyCache: [String: String] = [:]
    private static let cacheQueue = DispatchQueue(label: "zoteroweb.cache")

    private static func request(_ path: String, query: [URLQueryItem]) -> URLRequest? {
        var comps = URLComponents(string: "https://api.zotero.org/users/\(userID)/\(path)")
        comps?.queryItems = query
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(apiKey, forHTTPHeaderField: "Zotero-API-Key")
        req.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        return req
    }

    // MARK: Search

    static func search(_ query: String, completion: @escaping ([ZoteroItem]) -> Void) {
        guard let req = request("items", query: [
            .init(name: "q", value: query),
            .init(name: "qmode", value: "titleCreatorYear"),
            .init(name: "itemType", value: "-attachment || note"),
            .init(name: "include", value: "data"),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: "25"),
            .init(name: "sort", value: "date"),
            .init(name: "direction", value: "desc"),
        ]) else { return DispatchQueue.main.async { completion([]) } }

        URLSession.shared.dataTask(with: req) { data, _, _ in
            var items: [ZoteroItem] = []
            if let data,
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for entry in arr {
                    guard let itemKey = entry["key"] as? String,
                          let d = entry["data"] as? [String: Any] else { continue }
                    let title = d["title"] as? String ?? ""
                    if title.isEmpty { continue }
                    let info = citekeyInfo(from: d)
                    // Only cache pinned (real BBT) keys; synthesized keys can
                    // collide and would map one citekey to the wrong item.
                    if info.pinned { cacheQueue.sync { keyCache[info.key] = itemKey } }
                    items.append(ZoteroItem(
                        citekey: info.key,
                        title: title,
                        authors: creatorString(d["creators"]),
                        year: yearOf(d["date"])
                    ))
                }
            }
            DispatchQueue.main.async { completion(items) }
        }.resume()
    }

    // MARK: Export

    /// Resolve each citekey → itemKey (cache, else a targeted everything-search),
    /// export each item as BibTeX, rewrite its key to the user's citekey, concat.
    static func exportBib(_ citekeys: [String], completion: @escaping (String) -> Void) {
        let group = DispatchGroup()
        var entries: [String: String] = [:]   // citekey → bib entry
        let lock = NSLock()

        for ck in citekeys {
            group.enter()
            resolveItemKey(ck) { itemKey in
                guard let itemKey else { group.leave(); return }
                fetchBib(itemKey: itemKey) { bib in
                    if let bib, !bib.isEmpty {
                        let rewritten = rewriteKey(bib, to: ck)
                        lock.lock(); entries[ck] = rewritten; lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let bib = citekeys.compactMap { entries[$0] }.joined(separator: "\n\n")
            completion(bib)
        }
    }

    private static func resolveItemKey(_ citekey: String, completion: @escaping (String?) -> Void) {
        if let cached = cacheQueue.sync(execute: { keyCache[citekey] }) {
            return completion(cached)
        }
        // qmode=everything searches the extra field, where BBT stores the key.
        guard let req = request("items", query: [
            .init(name: "q", value: citekey),
            .init(name: "qmode", value: "everything"),
            .init(name: "include", value: "data"),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: "10"),
        ]) else { return completion(nil) }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var match: String?
            if let data,
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // Prefer an item whose derived citekey equals the wanted one.
                for entry in arr {
                    guard let itemKey = entry["key"] as? String,
                          let d = entry["data"] as? [String: Any] else { continue }
                    if derivedCitekey(from: d) == citekey { match = itemKey; break }
                }
                if match == nil, let first = arr.first, let k = first["key"] as? String { match = k }
            }
            if let match { cacheQueue.sync { keyCache[citekey] = match } }
            completion(match)
        }.resume()
    }

    private static func fetchBib(itemKey: String, completion: @escaping (String?) -> Void) {
        guard let req = request("items/\(itemKey)", query: [
            .init(name: "format", value: "biblatex"),
        ]) else { return completion(nil) }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data.flatMap { String(data: $0, encoding: .utf8) })
        }.resume()
    }

    /// Rewrite the first `@type{oldkey` to use the user's citekey (each fetch
    /// returns exactly one entry, so only the first match matters).
    private static func rewriteKey(_ bib: String, to citekey: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"@(\w+)\s*\{\s*[^,\s]+"#) else { return bib }
        let ns = bib as NSString
        guard let m = re.firstMatch(in: bib, range: NSRange(location: 0, length: ns.length)),
              let typeR = Range(m.range(at: 1), in: bib) else { return bib }
        return ns.replacingCharacters(in: m.range, with: "@\(bib[typeR]){\(citekey)")
    }

    // MARK: Field helpers

    private static func derivedCitekey(from data: [String: Any]) -> String {
        citekeyInfo(from: data).key
    }

    /// Pull a BBT citation key from the extra field (pinned=true), else
    /// synthesize one (pinned=false). Only pinned keys are unique enough to
    /// cache for export — synthesized keys can collide across items.
    private static func citekeyInfo(from data: [String: Any]) -> (key: String, pinned: Bool) {
        if let extra = data["extra"] as? String {
            for line in extra.components(separatedBy: "\n") {
                if let r = line.range(of: #"(?i)^\s*(citation key|tex\.citationkey)\s*:\s*"#,
                                      options: .regularExpression) {
                    let key = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { return (key, true) }
                }
            }
        }
        // Synthesize: firstAuthorLastName + year + firstTitleWord.
        let creators = data["creators"] as? [[String: Any]] ?? []
        let last = (creators.first?["lastName"] as? String)
            ?? (creators.first?["name"] as? String) ?? "ref"
        let surname = last.components(separatedBy: " ").last ?? last
        let year = yearOf(data["date"])
        let word = (data["title"] as? String)?.components(separatedBy: " ").first { $0.count > 3 } ?? ""
        let raw = "\(surname)\(year)\(word)"
        return (String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased(), false)
    }

    private static func creatorString(_ any: Any?) -> String {
        guard let arr = any as? [[String: Any]] else { return "" }
        let authors = arr.filter { ($0["creatorType"] as? String) == "author" }
        let names = authors.prefix(3).map { a -> String in
            (a["lastName"] as? String) ?? (a["name"] as? String) ?? ""
        }.filter { !$0.isEmpty }
        let s = names.joined(separator: ", ")
        return authors.count > 3 ? s + " et al." : s
    }

    private static func yearOf(_ any: Any?) -> String {
        guard let s = any as? String,
              let r = s.range(of: #"\d{4}"#, options: .regularExpression) else { return "" }
        return String(s[r])
    }
}
