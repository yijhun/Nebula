import Foundation

/// One indexed file: path + extracted title + full content (for search) +
/// parsed tags and outgoing wikilink targets (lowercased basenames).
struct IndexEntry: Identifiable, Hashable {
    let url: URL
    let title: String
    let content: String
    let tags: Set<String>
    let links: Set<String>
    let category: String?
    let mtime: Date
    /// All scalar frontmatter key→value pairs (for the database / property views).
    var properties: [String: String] = [:]
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var basenameKey: String { url.deletingPathExtension().lastPathComponent.lowercased() }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

/// A full-text search hit.
struct SearchHit: Identifiable, Hashable {
    let url: URL
    let line: Int
    let snippet: String
    var id: String { "\(url.path):\(line)" }
}

/// In-memory index of the vault's files for quick-open and full-text search.
///
/// HYBRID note: this is the index layer of the file-management design. It is
/// in-memory for now; #4 (tags / backlinks) will back it with the SwiftData
/// models in Sources/Models and add frontmatter/wikilink parsing + persistence.
final class IndexService: ObservableObject {
    @Published private(set) var entries: [IndexEntry] = []
    private var builtRoot: URL?
    private var builtCount = -1
    /// Off-main build queue + a generation counter so a stale build finishing
    /// late can't clobber a newer one.
    private let buildQueue = DispatchQueue(label: "nebula.index", qos: .utility)
    private var generation = 0

    /// Rebuild only if the vault changed since last build (cheap to call often).
    func buildIfNeeded(_ vault: VaultModel) {
        let files = Self.flatten(vault.tree)
        if vault.rootURL == builtRoot, files.count == builtCount, !entries.isEmpty { return }
        schedule(files: files, root: vault.rootURL)
    }

    func forceRebuild(_ vault: VaultModel) {
        schedule(files: Self.flatten(vault.tree), root: vault.rootURL)
    }

    /// Incremental + off-main. The FSWatcher fires on every save (autosave =
    /// every ~2s while typing); the old code re-READ every file in the vault
    /// synchronously on the main thread each time — a repeating I/O storm and
    /// the app's single biggest typing-lag source. Now: files whose mtime is
    /// unchanged reuse their already-parsed entry; only changed/new files are
    /// read, and all of it happens on a background queue.
    private func schedule(files: [URL], root: URL?) {
        generation += 1
        let gen = generation
        let previous = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        builtRoot = root
        builtCount = files.count
        buildQueue.async { [weak self] in
            let fm = FileManager.default
            let built: [IndexEntry] = files.map { url in
                let mtime = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                    ?? Date.distantPast
                if let old = previous[url], old.mtime == mtime { return old }
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return IndexEntry(
                    url: url,
                    title: Self.title(content, url),
                    content: content,
                    tags: Self.parseTags(content),
                    links: Self.parseLinks(content),
                    category: Self.parseFrontmatterValue(content, key: "category"),
                    mtime: mtime,
                    properties: Self.parseFrontmatter(content)
                )
            }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.entries = built
            }
        }
    }

    /// Read a single scalar value from the leading YAML frontmatter.
    static func parseFrontmatterValue(_ content: String, key: String) -> String? {
        guard content.hasPrefix("---") else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        for raw in lines[1..<end] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\(key):") {
                let v = String(line.dropFirst(key.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Parse all scalar `key: value` pairs from the leading YAML frontmatter.
    static func parseFrontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        let lines = content.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return [:] }
        var props: [String: String] = [:]
        for raw in lines[1..<end] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("-"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]"))
            if !key.isEmpty && !val.isEmpty { props[key] = val }
        }
        return props
    }

    // MARK: - Smart categories

    func drafts() -> [IndexEntry] { entries.filter { $0.ext == "md" || $0.ext == "markdown" } }
    func formal() -> [IndexEntry] { entries.filter { $0.ext == "tex" } }
    func recent(_ limit: Int = 10) -> [IndexEntry] {
        entries.sorted { $0.mtime > $1.mtime }.prefix(limit).map { $0 }
    }
    func categories() -> [(name: String, entries: [IndexEntry])] {
        var groups: [String: [IndexEntry]] = [:]
        for e in entries { if let c = e.category { groups[c, default: []].append(e) } }
        return groups.sorted { $0.key < $1.key }.map { (name: $0.key, entries: $0.value) }
    }
    func entries(for urls: Set<String>) -> [IndexEntry] {
        entries.filter { urls.contains($0.url.path) }.sorted { $0.name < $1.name }
    }

    // MARK: - Tags & links parsing

    /// Inline `#tags` + frontmatter `tags:` (lowercased, no leading #).
    static func parseTags(_ content: String) -> Set<String> {
        var tags = Set<String>()
        // Inline #tags: '#' followed by a letter/underscore, then tag chars.
        let chars = Array(content)
        var i = 0
        while i < chars.count {
            if chars[i] == "#" {
                let prev = i > 0 ? chars[i - 1] : " "
                let nextOK = i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1] == "_")
                if !prev.isLetter && !prev.isNumber && prev != "#" && nextOK {
                    var j = i + 1
                    var tag = ""
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber
                        || chars[j] == "_" || chars[j] == "/" || chars[j] == "-" {
                        tag.append(chars[j]); j += 1
                    }
                    tags.insert(tag.lowercased())
                    i = j; continue
                }
            }
            i += 1
        }
        // Frontmatter tags: between leading --- ... ---
        if content.hasPrefix("---") {
            let lines = content.components(separatedBy: "\n")
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                let fm = lines[1..<end]
                var inTags = false
                for raw in fm {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if let r = line.range(of: "tags:") , line.hasPrefix("tags:") {
                        let rest = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if rest.hasPrefix("[") {
                            rest.dropFirst().dropLast()
                                .split(separator: ",")
                                .forEach { tags.insert($0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")).lowercased()) }
                            inTags = false
                        } else if rest.isEmpty {
                            inTags = true
                        } else {
                            tags.insert(rest.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")).lowercased())
                            inTags = false
                        }
                    } else if inTags, line.hasPrefix("- ") {
                        tags.insert(line.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")).lowercased())
                    } else if inTags {
                        inTags = false
                    }
                }
            }
        }
        tags.remove("")
        return tags
    }

    /// `[[Target]]` / `[[Target|alias]]` / `[[Target#h]]` → lowercased target basenames.
    static func parseLinks(_ content: String) -> Set<String> {
        var links = Set<String>()
        var search = content.startIndex
        while let open = content.range(of: "[[", range: search..<content.endIndex) {
            guard let close = content.range(of: "]]", range: open.upperBound..<content.endIndex) else { break }
            var inner = String(content[open.upperBound..<close.lowerBound])
            if let bar = inner.firstIndex(of: "|") { inner = String(inner[..<bar]) }
            if let hash = inner.firstIndex(of: "#") { inner = String(inner[..<hash]) }
            let target = inner.trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                let base = (target as NSString).lastPathComponent
                links.insert(base.replacingOccurrences(of: ".md", with: "").lowercased())
            }
            search = close.upperBound
        }
        return links
    }

    // MARK: - Tag / backlink queries

    /// All tags with their file counts, alphabetical.
    func allTags() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { for t in e.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.key < $1.key }.map { (tag: $0.key, count: $0.value) }
    }

    func files(withTag tag: String) -> [IndexEntry] {
        entries.filter { $0.tags.contains(tag.lowercased()) }
    }

    /// All note basenames (md + tex), for `[[` completion / link resolution.
    func noteNames() -> [String] {
        entries.map { $0.url.deletingPathExtension().lastPathComponent }
    }

    /// Resolve a `[[target]]` (basename, case-insensitive) to a file URL.
    func resolveNote(_ target: String) -> URL? {
        let key = (target as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return entries.first { $0.basenameKey == key }?.url
    }

    /// Files that link to `url` via `[[basename]]`.
    func backlinks(for url: URL?) -> [IndexEntry] {
        guard let url else { return [] }
        let key = url.deletingPathExtension().lastPathComponent.lowercased()
        return entries.filter { $0.url != url && $0.links.contains(key) }
    }

    private static func flatten(_ nodes: [FileNode]) -> [URL] {
        var out: [URL] = []
        for n in nodes {
            if n.isDirectory { out += flatten(n.children ?? []) } else { out.append(n.url) }
        }
        return out
    }

    private static func title(_ content: String, _ url: URL) -> String {
        for line in content.split(separator: "\n", maxSplits: 30, omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)) }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Queries

    /// Fuzzy filename match, best-first.
    func quickOpen(_ query: String) -> [IndexEntry] {
        let q = query.lowercased()
        if q.isEmpty { return Array(entries.prefix(50)) }
        return entries
            .compactMap { e -> (IndexEntry, Int)? in
                let s = Self.fuzzyScore(q, e.name.lowercased())
                return s > 0 ? (e, s) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(50)
            .map(\.0)
    }

    /// Full-text content search → line-level hits.
    func search(_ query: String) -> [SearchHit] {
        let q = query.lowercased()
        guard q.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        for e in entries {
            let lines = e.content.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() where line.lowercased().contains(q) {
                hits.append(SearchHit(url: e.url, line: i + 1,
                                      snippet: line.trimmingCharacters(in: .whitespaces)))
                if hits.count >= 200 { return hits }
            }
        }
        return hits
    }

    /// Subsequence fuzzy score (contiguous streaks and prefix matches score higher).
    private static func fuzzyScore(_ q: String, _ s: String) -> Int {
        var qi = q.startIndex
        var score = 0
        var streak = 0
        for ch in s {
            if qi < q.endIndex, ch == q[qi] {
                streak += 1
                score += streak
                qi = q.index(after: qi)
            } else {
                streak = 0
            }
        }
        guard qi == q.endIndex else { return 0 }
        return score + (s.hasPrefix(q) ? 8 : 0)
    }
}
