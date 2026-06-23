import Foundation

/// One Zotero library item (from Better BibTeX).
struct ZoteroItem: Identifiable, Hashable {
    let citekey: String
    let title: String
    let authors: String
    let year: String
    var id: String { citekey }
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
    static func search(_ query: String, completion: @escaping ([ZoteroItem]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !q.isEmpty else { DispatchQueue.main.async { completion([]) }; return }
        rpc("item.search", [q]) { result in
            var items: [ZoteroItem] = []
            if case .success(let r) = result, let arr = r as? [[String: Any]] {
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
        }
    }

    /// Export the given citekeys as biblatex (only those entries).
    static func exportBib(_ citekeys: [String], completion: @escaping (String) -> Void) {
        let keys = Array(Set(citekeys)).filter { !$0.isEmpty }
        guard enabled, !keys.isEmpty else { DispatchQueue.main.async { completion("") }; return }
        rpc("item.export", [keys, "biblatex"]) { result in
            var bib = ""
            if case .success(let r) = result { bib = (r as? String) ?? "" }
            DispatchQueue.main.async { completion(bib) }
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
