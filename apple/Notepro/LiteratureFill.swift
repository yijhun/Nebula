import Foundation

/// Fills a literature note's bibliographic details from Zotero, **without
/// overwriting anything already written** — empty frontmatter fields and an
/// empty `## 摘要` only. Idempotent: safe to run again after Zotero gains more
/// data. The note is snapshotted before every write so 版本歷史 can restore it.
enum LiteratureFill {

    /// Resolve the note's Zotero record (by `cite`, then DOI / arXiv id / title),
    /// fill the blanks, and write it back. `completion` runs on the main thread
    /// with a human status message and the URL if the file actually changed.
    static func backfill(url: URL, props: [String: String], title: String,
                         vaultRoot: URL?,
                         completion: @escaping (_ message: String, _ changed: URL?) -> Void) {
        guard ZoteroService.enabled else {
            DispatchQueue.main.async { completion("Zotero 整合已關閉（在設定開啟）", nil) }; return
        }
        let cite = (props["cite"] ?? "").trimmingCharacters(in: .whitespaces)
        let doi = props["doi"] ?? ""
        let arxiv = props["arxiv"] ?? ""
        let noteTitle = props["title"].flatMap { $0.isEmpty ? nil : $0 } ?? title

        // Try the existing citekey first; if it isn't in Zotero (e.g. an
        // app-generated arXiv key), fall back to matching by DOI / arXiv / title.
        func writeBack(_ m: ZoteroMeta) {
            guard let original = try? String(contentsOf: url, encoding: .utf8) else {
                completion("讀不到筆記檔", nil); return
            }
            guard let updated = apply(m, to: original), updated != original else {
                completion("已經是最新的，沒有可補的空白欄位", nil); return
            }
            HistoryStore.snapshot(root: vaultRoot, file: url, content: original)
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
                completion("已從 Zotero 回填 [@\(m.citekey)]", url)
            } catch { completion("寫入失敗：\(error.localizedDescription)", nil) }
        }

        func fetchThenWrite(_ key: String, orResolve: Bool) {
            ZoteroService.fullMeta([key]) { map in
                if let m = map[key] { writeBack(m); return }
                guard orResolve else { completion("Zotero 找不到 [@\(key)]", nil); return }
                resolveAndFetch()
            }
        }

        func resolveAndFetch() {
            ZoteroService.resolveCitekey(doi: doi, arxiv: arxiv, title: noteTitle) { key in
                guard let key, !key.isEmpty else {
                    completion("Zotero 書庫裡找不到對應項目（試著先加入 Zotero）", nil); return
                }
                fetchThenWrite(key, orResolve: false)
            }
        }

        if !cite.isEmpty { fetchThenWrite(cite, orResolve: true) }
        else { resolveAndFetch() }
    }

    /// Merge a Zotero record into raw note content, filling only blanks. Returns
    /// the updated content, or nil if the note has no frontmatter.
    static func apply(_ m: ZoteroMeta, to content: String) -> String? {
        guard content.hasPrefix("---") else { return nil }
        var lines = content.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        // Only non-empty values can fill blanks. `cite` comes from the record's
        // (authoritative) citekey; `source` defaults to Zotero when unset.
        let fields: [(String, String)] = [
            ("title", clean(m.title)), ("authors", clean(m.authors)), ("year", clean(m.year)),
            ("journal", clean(m.journal)), ("volume", clean(m.volume)), ("pages", clean(m.pages)),
            ("cite", clean(m.citekey)), ("doi", clean(m.doi)), ("url", clean(m.url)),
        ].filter { !$0.1.isEmpty }

        var present = Set<String>()
        for i in 1..<end {
            guard let colon = lines[i].firstIndex(of: ":") else { continue }
            let key = String(lines[i][..<colon]).trimmingCharacters(in: .whitespaces)
            present.insert(key)
            let after = String(lines[i][lines[i].index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard after.isEmpty, let val = fields.first(where: { $0.0 == key })?.1 else { continue }
            lines[i] = "\(key): \(val)"
        }
        // Keys the note doesn't have at all → insert before the closing ---.
        let missing = fields.filter { !present.contains($0.0) }
        if !missing.isEmpty { lines.insert(contentsOf: missing.map { "\($0.0): \($0.1)" }, at: end) }
        var out = lines.joined(separator: "\n")

        if !m.abstract.isEmpty { out = fillSection(out, "## 摘要", clean(m.abstract)) }
        return out
    }

    /// Put `text` under `heading` only if that section is currently empty
    /// (heading immediately followed by blanks up to the next `## `).
    private static func fillSection(_ content: String, _ heading: String, _ text: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading })
        else { return content }
        var j = h + 1
        while j < lines.count {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") { break }
            if !t.isEmpty { return content }   // section already has content
            j += 1
        }
        lines.insert(contentsOf: ["", text], at: h + 1)
        return lines.joined(separator: "\n")
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .trimmingCharacters(in: .whitespaces)
    }
}
