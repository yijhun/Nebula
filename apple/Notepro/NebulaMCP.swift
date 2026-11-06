import Foundation
import AppKit
import PDFKit

/// Nebula as an MCP tool server, so the chat panel's AI (Claude Code / Codex)
/// can reach the user's Zotero library and NASA ADS itself — search, read
/// abstracts and full texts, export BibTeX, and add missing papers.
///
/// Started as `Nebula --mcp` by the CLI (see `NebulaMCP.claudeArgs` /
/// `codexArgs`). It's the app's own binary, so it reuses ZoteroService,
/// LiteratureSearch and PDFKit rather than duplicating them. JSON-RPC 2.0,
/// one message per line on stdin/stdout. Nothing else may write to stdout.
enum NebulaMCP {
    static let serverName = "nebula"

    // MARK: - Wiring into the CLIs

    /// Settings toggle (default on).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "aiZoteroTools") as? Bool ?? true }

    /// Path of the running app's binary — the server is the same executable.
    static var executable: String? { Bundle.main.executablePath }

    /// Claude Code: an --mcp-config file, and every nebula tool pre-approved.
    /// (The one tool that writes, zotero_add, asks the user itself.)
    static func claudeArgs() -> [String] {
        guard enabled, let exe = executable else { return [] }
        let config: [String: Any] = ["mcpServers": [serverName: ["command": exe, "args": ["--mcp"]]]]
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("mcp.json")
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]),
              (try? data.write(to: file)) != nil else { return [] }
        return ["--mcp-config", file.path, "--allowedTools", "mcp__\(serverName)"]
    }

    /// Codex: config overrides for this run only (the user's config.toml is untouched).
    static func codexArgs() -> [String] {
        guard enabled, let exe = executable else { return [] }
        func toml(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // `exec` runs with no one to approve tool calls, so they'd all be
        // refused; pre-approve ours (zotero_add still asks the user itself).
        return ["-c", "mcp_servers.\(serverName).command=\(toml(exe))",
                "-c", "mcp_servers.\(serverName).args=[\"--mcp\"]",
                "-c", "mcp_servers.\(serverName).default_tools_approval_mode=\"approve\""]
    }

    /// What the AI is told about the tools (appended to its system prompt).
    static var instruction: String? {
        guard enabled else { return nil }
        return """
        You can reach the user's Zotero library and NASA ADS through the `nebula` tools.
        - Cite only with citekeys returned by zotero_search or zotero_get, written as [@citekey]. Never invent a citekey.
        - If a paper you want to cite is not in Zotero, find it with ads_search (or arxiv_search), then offer to add it with zotero_add — the user confirms in a dialog — and cite the key it returns.
        - To check numbers, equations or claims against a paper, read it with zotero_fulltext rather than relying on memory.
        """
    }

    // MARK: - Server loop

    private static let out = FileHandle.standardOutput
    private static let writeLock = NSLock()

    /// Never returns. Requests are handled on the main thread (the Zotero and
    /// ADS helpers complete there, and the confirmation dialog must run there).
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)          // a dialog, never a Dock icon
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { handle(msg) }
            }
            exit(0)                                   // the CLI closed our stdin
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    private static func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        writeLock.lock(); out.write(data); writeLock.unlock()
    }

    private static func reply(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func fail(_ id: Any?, code: Int, _ message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            reply(id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": serverName, "version": "1.0"],
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            call(name, args) { text, isError in
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
            }
        default:
            if id != nil { fail(id, code: -32601, "method not found: \(method)") }   // notifications: ignore
        }
    }

    // MARK: - Tools

    private static func schema(_ props: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    private static let str: [String: Any] = ["type": "string"]
    private static let strs: [String: Any] = ["type": "array", "items": ["type": "string"]]
    private static let int: [String: Any] = ["type": "integer"]

    static let tools: [[String: Any]] = [
        ["name": "zotero_search",
         "description": "Search the user's Zotero library by title, author or year (falls back to abstracts/full text). Returns citekeys to cite as [@citekey].",
         "inputSchema": schema(["query": str, "limit": int], required: ["query"])],
        ["name": "zotero_get",
         "description": "Bibliographic record for citekeys from the user's Zotero: authors, year, journal, volume, pages, DOI and abstract.",
         "inputSchema": schema(["citekeys": strs], required: ["citekeys"])],
        ["name": "zotero_bibtex",
         "description": "BibTeX entries for citekeys from the user's Zotero.",
         "inputSchema": schema(["citekeys": strs], required: ["citekeys"])],
        ["name": "zotero_fulltext",
         "description": "Text of a paper's PDF attached in the user's Zotero, page by page. Use page_from/page_to for long papers.",
         "inputSchema": schema(["citekey": str, "page_from": int, "page_to": int, "max_chars": int], required: ["citekey"])],
        ["name": "ads_search",
         "description": "Search NASA ADS (astronomy literature). Query uses ADS syntax, e.g. 'author:\"Sandell, G\" year:2020' or 'NGC 7538 IRS1 jet'. Returns bibcodes, DOIs and abstracts.",
         "inputSchema": schema(["query": str, "rows": int], required: ["query"])],
        ["name": "arxiv_search",
         "description": "Search arXiv by keywords. Returns arXiv ids and abstracts.",
         "inputSchema": schema(["query": str], required: ["query"])],
        ["name": "zotero_add",
         "description": "Add papers to the user's Zotero library (the collection currently selected in Zotero). Identifiers: ADS bibcodes, DOIs, or arXiv ids. The user is shown the list and must confirm; returns the new citekeys.",
         "inputSchema": schema(["identifiers": strs, "reason": str], required: ["identifiers"])],
    ]

    private static func call(_ name: String, _ a: [String: Any],
                             _ done: @escaping (String, Bool) -> Void) {
        switch name {
        case "zotero_search":
            let q = a["query"] as? String ?? ""
            let limit = max(1, min(a["limit"] as? Int ?? 10, 50))
            ZoteroService.search(q) { items in
                guard !items.isEmpty else {
                    return done("No match in Zotero for \"\(q)\". (Is Zotero running? If the paper isn't in the library, try ads_search.)", false)
                }
                done(items.prefix(limit).map { "[@\($0.citekey)] \($0.authors) (\($0.year)) — \($0.title)" }
                        .joined(separator: "\n"), false)
            }
        case "zotero_get":
            let keys = a["citekeys"] as? [String] ?? []
            ZoteroService.fullMeta(keys) { map in
                let lines = keys.map { k -> String in
                    guard let m = map[k] else { return "[@\(k)] — not in the user's Zotero library" }
                    return """
                    [@\(k)]
                    title: \(m.title)
                    authors: \(m.authors)
                    year: \(m.year)  journal: \(m.journal)  volume: \(m.volume)  pages: \(m.pages)
                    doi: \(m.doi)
                    abstract: \(m.abstract)
                    """
                }
                done(lines.joined(separator: "\n\n"), false)
            }
        case "zotero_bibtex":
            ZoteroService.exportBib(a["citekeys"] as? [String] ?? [], format: .bibtex) { bib in
                done(bib.isEmpty ? "None of these citekeys are in the user's Zotero library." : bib, bib.isEmpty)
            }
        case "zotero_fulltext":
            fulltext(a, done)
        case "ads_search":
            let rows = max(1, min(a["rows"] as? Int ?? 10, 25))
            LiteratureSearch.ads(a["query"] as? String ?? "") { result in
                switch result {
                case .success(let papers):
                    done(papers.isEmpty ? "No ADS results." : papers.prefix(rows).map(describe).joined(separator: "\n\n"), false)
                case .failure(let e):
                    done("ADS search failed: \(e.localizedDescription)", true)
                }
            }
        case "arxiv_search":
            LiteratureSearch.arxiv(a["query"] as? String ?? "") { papers in
                done(papers.isEmpty ? "No arXiv results." : papers.prefix(10).map(describe).joined(separator: "\n\n"), false)
            }
        case "zotero_add":
            add(a, done)
        default:
            done("Unknown tool \(name)", true)
        }
    }

    private static func describe(_ p: Paper) -> String {
        let abstract = p.abstract.count > 500 ? String(p.abstract.prefix(500)) + "…" : p.abstract
        return "\(p.source) \(p.identifier)\(p.doi.isEmpty ? "" : "  doi:\(p.doi)")\n\(p.authorLine) (\(p.year)) — \(p.title)\n\(abstract)"
    }

    private static func fulltext(_ a: [String: Any], _ done: @escaping (String, Bool) -> Void) {
        let key = a["citekey"] as? String ?? ""
        ZoteroService.attachments(key) { atts in
            guard let pdf = atts.first(where: \.isPDF),
                  let doc = PDFDocument(url: URL(fileURLWithPath: pdf.path)) else {
                return done("No PDF attached to [@\(key)] in Zotero.", true)
            }
            let n = doc.pageCount
            let from = max(1, a["page_from"] as? Int ?? 1)
            let to = min(n, a["page_to"] as? Int ?? n)
            let cap = max(2_000, min(a["max_chars"] as? Int ?? 40_000, 120_000))
            var text = "[@\(key)] — \(n) pages\n"
            var p = from
            while p <= to, text.count < cap {
                text += "\n--- page \(p) ---\n" + (doc.page(at: p - 1)?.string ?? "")
                p += 1
            }
            if text.count > cap { text = String(text.prefix(cap)) }
            if p <= to { text += "\n\n[truncated after page \(p - 1) of \(n); ask for page_from=\(p) to continue]" }
            done(text, false)
        }
    }

    // MARK: zotero_add

    /// Resolve each identifier to BibTeX (ADS first, then doi.org / arXiv),
    /// show the user exactly what will be added and where, and only on their
    /// OK import it through Zotero's connector. Returns the new citekeys.
    private static func add(_ a: [String: Any], _ done: @escaping (String, Bool) -> Void) {
        let ids = (a["identifiers"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return done("No identifiers given.", true) }
        let group = DispatchGroup()
        var found: [(id: String, bib: String)] = []
        var missing: [String] = []
        for id in ids {
            group.enter()
            resolveBibtex(id) { bib in
                if let bib, bib.contains("@") { found.append((id, bib)) } else { missing.append(id) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !found.isEmpty else {
                return done("Couldn't find metadata for: \(missing.joined(separator: ", ")).", true)
            }
            selectedCollection { place in
                let titles = found.map { "• " + summary(of: $0.bib) }
                let alert = NSAlert()
                alert.messageText = String(format: LZ("AI 想把 %d 篇論文加入你的 Zotero"), found.count)
                var info = titles.joined(separator: "\n")
                if let place { info += "\n\n" + LZ("加入位置") + "：" + place }
                if let reason = a["reason"] as? String, !reason.isEmpty { info += "\n" + LZ("原因") + "：" + reason }
                if !missing.isEmpty { info += "\n\n" + LZ("找不到資料") + "：" + missing.joined(separator: ", ") }
                alert.informativeText = info
                alert.addButton(withTitle: LZ("加入 Zotero"))
                alert.addButton(withTitle: LZ("取消"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return done("The user declined adding these papers. Don't add them; cite only papers already in Zotero.", false)
                }
                importBibtex(found.map(\.bib).joined(separator: "\n\n")) { ok, detail in
                    guard ok else { return done("Zotero refused the import: \(detail)", true) }
                    keysAfterImport(found.map(\.bib)) { keys in
                        var msg = "Added to Zotero\(place.map { " (\($0))" } ?? ""). Cite them as:\n"
                        msg += keys.map { "[@\($0)]" }.joined(separator: "\n")
                        if !missing.isEmpty { msg += "\nNot found: \(missing.joined(separator: ", "))" }
                        done(msg, false)
                    }
                }
            }
        }
    }

    /// "Author et al. (year) — Title" from a BibTeX entry, for the dialog.
    /// Handles one-field-per-line entries (ADS) and single-line ones (doi.org).
    static func summary(of bib: String) -> String {
        func field(_ f: String) -> String {
            let pattern = #"(?i)\b"# + f + #"\s*=\s*(?:\{((?:[^{}]|\{[^{}]*\})*)\}|"([^"]*)"|(\d+))"#
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: bib, range: NSRange(bib.startIndex..., in: bib)) else { return "" }
            for g in 1...3 {
                if let r = Range(m.range(at: g), in: bib) {
                    return String(bib[r]).replacingOccurrences(of: "{", with: "")
                        .replacingOccurrences(of: "}", with: "")
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }
        let authors = field("author").components(separatedBy: " and ")
        let first = authors.first?.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let who = authors.count > 1 ? "\(first) et al." : first
        return "\(who) (\(field("year"))) — \(field("title"))"
    }

    private static func resolveBibtex(_ id: String, _ done: @escaping (String?) -> Void) {
        let isDOI = id.lowercased().hasPrefix("10.") || id.lowercased().hasPrefix("doi:")
        let doi = id.replacingOccurrences(of: "doi:", with: "", options: .caseInsensitive)
        let isArxiv = id.range(of: #"^(arxiv:)?\d{4}\.\d{4,5}(v\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let bibcode = id.count == 19 && id.prefix(4).allSatisfy(\.isNumber)
        if bibcode { return LiteratureSearch.adsBibtex(id, completion: done) }
        let arxivID = id.replacingOccurrences(of: "arxiv:", with: "", options: .caseInsensitive)
        let q = isDOI ? "doi:\"\(doi)\"" : isArxiv ? "arXiv:\(arxivID)" : id
        // Without ADS: a DOI resolves through doi.org (any publisher), an
        // arXiv id through arXiv's own API.
        let fallback: () -> Void = {
            if isDOI { return doiBibtex(doi, done) }
            guard isArxiv else { return done(nil) }
            LiteratureSearch.arxivByID(arxivID) { p in
                guard let p, !p.title.isEmpty else { return done(nil) }
                done(LiteratureSearch.arxivBibtex(p, key: LiteratureSearch.citekey(for: p)))
            }
        }
        // ADS knows nearly every astronomy paper and gives clean BibTeX.
        guard !LiteratureSearch.adsToken.isEmpty else { return fallback() }
        LiteratureSearch.ads(q) { result in
            if case .success(let papers) = result, let p = papers.first, !p.identifier.isEmpty {
                LiteratureSearch.adsBibtex(p.identifier) { bib in
                    if let bib { return done(bib) }
                    fallback()
                }
            } else {
                fallback()
            }
        }
    }

    /// DOI content negotiation (any publisher, no key).
    private static func doiBibtex(_ doi: String, _ done: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://doi.org/\(doi)") else { return done(nil) }
        var req = URLRequest(url: url)
        req.setValue("application/x-bibtex", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            // doi.org HTML-escapes ampersands ("Astronomy &amp; Astrophysics").
            let s = ok ? data.flatMap { String(data: $0, encoding: .utf8) }?
                .replacingOccurrences(of: "&amp;", with: "\\&") : nil
            DispatchQueue.main.async { done(s) }
        }.resume()
    }

    private static let connector = URL(string: "http://127.0.0.1:23119/connector/")!

    /// "My Library ▸ ngc7538_project" — where Zotero will put imports.
    private static func selectedCollection(_ done: @escaping (String?) -> Void) {
        var req = URLRequest(url: connector.appendingPathComponent("getSelectedCollection"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let lib = obj?["libraryName"] as? String
            let col = obj?["name"] as? String
            let place = lib.map { l in col.map { $0 == l ? l : "\(l) ▸ \($0)" } ?? l }
            DispatchQueue.main.async { done(place) }
        }.resume()
    }

    private static func importBibtex(_ bib: String, _ done: @escaping (Bool, String) -> Void) {
        var req = URLRequest(url: connector.appendingPathComponent("import"))
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(bib.utf8)
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? ""
            DispatchQueue.main.async { done((200..<300).contains(code), "HTTP \(code) \(body.prefix(200))") }
        }.resume()
    }

    /// Better BibTeX assigns citekeys a moment after import; look each paper
    /// up by title until it shows up (up to ~6s).
    private static func keysAfterImport(_ bibs: [String], _ done: @escaping ([String]) -> Void) {
        let titles = bibs.map { summary(of: $0).components(separatedBy: " — ").last ?? "" }
        var keys: [String] = []
        var attempt = 0
        func tryOnce() {
            let group = DispatchGroup()
            var found: [String] = []
            for t in titles where !t.isEmpty {
                group.enter()
                ZoteroService.search(String(t.prefix(60))) { items in
                    if let k = items.first?.citekey { found.append(k) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                keys = found
                attempt += 1
                if keys.count >= titles.count || attempt >= 6 { done(keys) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryOnce() } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryOnce() }
    }
}
