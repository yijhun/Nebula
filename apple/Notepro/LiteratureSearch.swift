import Foundation

/// A paper found via arXiv or NASA ADS.
struct Paper: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var authors: [String]
    var year: String
    var abstract: String
    var identifier: String   // arXiv id, or ADS bibcode
    var doi: String
    var url: String
    var source: String       // "arXiv" | "ADS"

    var authorLine: String {
        if authors.isEmpty { return "" }
        return authors.count > 3 ? authors.prefix(3).joined(separator: ", ") + " et al." : authors.joined(separator: ", ")
    }
}

/// Search arXiv (open API, no key) and NASA ADS (needs a free user token) and
/// turn results into BibTeX + a literature note. Complements the Zotero path.
enum LiteratureSearch {
    static var adsToken: String { UserDefaults.standard.string(forKey: "adsToken") ?? "" }

    // MARK: arXiv (no key)

    static func arxiv(_ query: String, completion: @escaping ([Paper]) -> Void) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://export.arxiv.org/api/query?search_query=all:\(q)&start=0&max_results=25&sortBy=relevance") else {
            return DispatchQueue.main.async { completion([]) }
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let papers = data.map { ArxivParser($0).parse() } ?? []
            DispatchQueue.main.async { completion(papers) }
        }.resume()
    }

    // MARK: NASA ADS (Bearer token)

    static func ads(_ query: String, completion: @escaping (Result<[Paper], Error>) -> Void) {
        let token = adsToken
        guard !token.isEmpty else {
            return DispatchQueue.main.async { completion(.failure(ADSError.noToken)) }
        }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let fl = "title,author,year,bibcode,abstract,doi"
        guard let url = URL(string: "https://api.adsabs.harvard.edu/v1/search/query?q=\(q)&rows=25&sort=date+desc&fl=\(fl)") else {
            return DispatchQueue.main.async { completion(.failure(ADSError.badResponse)) }
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            DispatchQueue.main.async {
                if (resp as? HTTPURLResponse)?.statusCode == 401 { return completion(.failure(ADSError.unauthorized)) }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = obj["response"] as? [String: Any],
                      let docs = response["docs"] as? [[String: Any]] else {
                    return completion(.failure(ADSError.badResponse))
                }
                let papers = docs.map { d -> Paper in
                    let title = (d["title"] as? [String])?.first ?? (d["title"] as? String ?? "")
                    let authors = d["author"] as? [String] ?? []
                    let doi = (d["doi"] as? [String])?.first ?? ""
                    let bibcode = d["bibcode"] as? String ?? ""
                    return Paper(title: title, authors: authors, year: d["year"] as? String ?? "",
                                 abstract: d["abstract"] as? String ?? "", identifier: bibcode,
                                 doi: doi, url: "https://ui.adsabs.harvard.edu/abs/\(bibcode)", source: "ADS")
                }
                completion(.success(papers))
            }
        }.resume()
    }

    /// ADS "citation network": the references OF a paper, or the papers that
    /// CITE it. `mode` is "references" or "citations".
    static func adsRelated(_ bibcode: String, mode: String,
                           completion: @escaping (Result<[Paper], Error>) -> Void) {
        let token = adsToken
        guard !token.isEmpty else {
            return DispatchQueue.main.async { completion(.failure(ADSError.noToken)) }
        }
        // `q=references(bibcode:X)` / `q=citations(bibcode:X)` is ADS's operator syntax.
        let op = mode == "citations" ? "citations" : "references"
        let raw = "\(op)(bibcode:\(bibcode))"
        let q = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let fl = "title,author,year,bibcode,abstract,doi"
        guard let url = URL(string: "https://api.adsabs.harvard.edu/v1/search/query?q=\(q)&rows=50&sort=date+desc&fl=\(fl)") else {
            return DispatchQueue.main.async { completion(.failure(ADSError.badResponse)) }
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            DispatchQueue.main.async {
                if (resp as? HTTPURLResponse)?.statusCode == 401 { return completion(.failure(ADSError.unauthorized)) }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = obj["response"] as? [String: Any],
                      let docs = response["docs"] as? [[String: Any]] else {
                    return completion(.failure(ADSError.badResponse))
                }
                let papers = docs.map { d -> Paper in
                    let bibcode = d["bibcode"] as? String ?? ""
                    return Paper(title: (d["title"] as? [String])?.first ?? "",
                                 authors: d["author"] as? [String] ?? [],
                                 year: d["year"] as? String ?? "",
                                 abstract: d["abstract"] as? String ?? "",
                                 identifier: bibcode,
                                 doi: (d["doi"] as? [String])?.first ?? "",
                                 url: "https://ui.adsabs.harvard.edu/abs/\(bibcode)", source: "ADS")
                }
                completion(.success(papers))
            }
        }.resume()
    }

    /// Download an arXiv paper's PDF to `dir`, returning the saved file URL.
    /// `id` is the arXiv id (e.g. "2101.01234"); works only for `source==arXiv`.
    static func downloadArxivPDF(id: String, to dir: URL,
                                 completion: @escaping (URL?) -> Void) {
        let clean = id.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        guard !clean.isEmpty, let url = URL(string: "https://arxiv.org/pdf/\(clean).pdf") else {
            return DispatchQueue.main.async { completion(nil) }
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            guard ok, let data, data.starts(with: [0x25, 0x50, 0x44, 0x46]) else {  // %PDF
                return DispatchQueue.main.async { completion(nil) }
            }
            let safe = clean.replacingOccurrences(of: "/", with: "_")
            let dest = dir.appendingPathComponent("arXiv-\(safe).pdf")
            try? data.write(to: dest)
            DispatchQueue.main.async { completion(FileManager.default.fileExists(atPath: dest.path) ? dest : nil) }
        }.resume()
    }

    /// ADS canonical BibTeX for a bibcode (uses ADS's export endpoint).
    static func adsBibtex(_ bibcode: String, completion: @escaping (String?) -> Void) {
        let token = adsToken
        guard !token.isEmpty, let url = URL(string: "https://api.adsabs.harvard.edu/v1/export/bibtex") else {
            return DispatchQueue.main.async { completion(nil) }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["bibcode": [bibcode]])
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let bib = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["export"] as? String
            DispatchQueue.main.async { completion(bib) }
        }.resume()
    }

    enum ADSError: LocalizedError {
        case noToken, unauthorized, badResponse
        var errorDescription: String? {
            switch self {
            case .noToken: return "未設定 NASA ADS API token（設定 ▸ 引用）"
            case .unauthorized: return "ADS token 無效或過期"
            case .badResponse: return "ADS 回應無效"
            }
        }
    }

    // MARK: BibTeX + citekey

    /// A citekey like `balbus1991powerful` (first-author surname + year + word).
    static func citekey(for p: Paper) -> String {
        let surname = (p.authors.first ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ", ")).first ?? "ref"
        let word = p.title.components(separatedBy: " ")
            .first { $0.count > 3 } ?? ""
        let raw = "\(surname)\(p.year)\(word)"
        return String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    /// Synthesize a BibTeX entry for an arXiv paper.
    static func arxivBibtex(_ p: Paper, key: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "") }
        var lines = ["@article{\(key),",
                     "  title = {{\(esc(p.title))}},",
                     "  author = {\(p.authors.map(esc).joined(separator: " and "))},",
                     "  year = {\(p.year)},",
                     "  eprint = {\(p.identifier)},",
                     "  archivePrefix = {arXiv}"]
        if !p.doi.isEmpty { lines.append("  ,doi = {\(p.doi)}") }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Minimal Atom XML parser for the arXiv API response.
private final class ArxivParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var papers: [Paper] = []
    private var cur: Paper?
    private var path: [String] = []
    private var text = ""
    init(_ data: Data) { self.data = data }

    func parse() -> [Paper] {
        let p = XMLParser(data: data); p.delegate = self; p.parse(); return papers
    }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(el); text = ""
        if el == "entry" { cur = Paper(title: "", authors: [], year: "", abstract: "", identifier: "", doi: "", url: "", source: "arXiv") }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        guard cur != nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inAuthor = path.contains("author")
        switch el {
        case "title" where path.dropLast().last == "entry":
            cur?.title = t.replacingOccurrences(of: "\n", with: " ")
        case "name" where inAuthor: if !t.isEmpty { cur?.authors.append(t) }
        case "summary": cur?.abstract = t.replacingOccurrences(of: "\n", with: " ")
        case "published": cur?.year = String(t.prefix(4))
        case "id" where path.dropLast().last == "entry":
            cur?.url = t
            cur?.identifier = t.components(separatedBy: "/abs/").last.map { $0.replacingOccurrences(of: "v\\d+$", with: "", options: .regularExpression) } ?? t
        case "doi": cur?.doi = t
        case "entry": if let c = cur { papers.append(c) }; cur = (path.dropLast().last == nil ? nil : cur); cur = nil
        default: break
        }
    }
}
