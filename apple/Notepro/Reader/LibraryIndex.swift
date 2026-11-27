import Foundation
import Combine

/// One paper as the library tab shows it: its meta plus the display and sort
/// values the table needs, computed once when the library is loaded.
struct LibraryEntry: Identifiable {
    let folder: String
    var id: String { folder }
    let meta: PaperMeta
    let creators: String            // "Frau et al."
    let publication: String
    let added: String               // as stored; sorts as text
    let lastOpened: String
    let hasPDF: Bool
    let annotationCount: Int
    let notes: [String]             // file names in notes/
    /// Lowercased citekey, title, creators, year, publication, tags,
    /// keywords and identifiers, for multi-word search.
    let haystack: String

    /// The title without the markup Zotero keeps in it (`<i>Herschel</i>`).
    var title: String { meta.title.isEmpty ? meta.citekey : Self.plain(meta.title) }

    /// AASTeX journal macros that ADS BibTeX leaves in the journal field
    /// (`\apj`; `\aap` arrives as "åp" when `\aa` was read as å).
    static let journalMacros: [String: String] = [
        "apj": "ApJ", "apjl": "ApJL", "apjs": "ApJS", "aj": "AJ", "aap": "A&A", "aaps": "A&AS", "aapr": "A&ARv",
        "mnras": "MNRAS", "pasp": "PASP", "pasj": "PASJ", "pasa": "PASA", "araa": "ARA&A", "nat": "Nature",
        "apss": "Ap&SS", "icarus": "Icarus", "procspie": "Proc. SPIE", "physrep": "Phys. Rep.", "prl": "PRL",
        "na": "New Astron.", "nar": "New Astron. Rev.", "ssr": "Space Sci. Rev.", "aplett": "Astrophys. Lett.",
        "baas": "BAAS", "rmxaa": "RMxAA", "jcap": "JCAP", "memsai": "Mem. SAIt", "qjras": "QJRAS",
    ]

    static func journal(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\\"), let name = journalMacros[String(t.dropFirst()).lowercased()] { return name }
        if t.hasPrefix("å") { return journalMacros["aa" + t.dropFirst()] ?? t }
        return t
    }

    /// Zotero stores dates as "1952-04-01 1952-04-01" (sortable, then as
    /// entered); show the part as entered.
    static func displayDate(_ s: String) -> String {
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return parts[1] }
        return s
    }

    static func plain(_ s: String) -> String {
        guard s.contains("<") else { return s }
        return s.replacingOccurrences(of: "</?(i|b|em|strong|sub|sup|sc|span)[^>]*>", with: "",
                                      options: [.regularExpression, .caseInsensitive])
    }
    var year: String { meta.year }
    var unread: Bool { meta.status == "unread" }

    init(folder: String, meta m: PaperMeta, annotationCount: Int = 0, notes: [String] = []) {
        self.folder = folder
        self.meta = m
        self.creators = Self.creatorLabel(m.bibliographic.creators)
        let f = m.bibliographic.fields
        self.publication = Self.journal(["publicationTitle", "journalAbbreviation", "bookTitle", "proceedingsTitle",
                            "websiteTitle", "repository", "publisher"].lazy.compactMap { f[$0] }.first { !$0.isEmpty } ?? "")
        self.added = m.added
        self.lastOpened = m.lastOpened ?? ""
        self.hasPDF = m.pdf != nil
        self.annotationCount = annotationCount
        self.notes = notes
        let people = m.bibliographic.creators.map { "\($0.family) \($0.given)" }.joined(separator: " ")
        let ids = [m.ids.doi, m.ids.bibcode, m.ids.arxiv].compactMap { $0 }.joined(separator: " ")
        self.haystack = [m.citekey, m.title, people, m.year, publication, m.tags.joined(separator: " "),
                         m.keywords.joined(separator: " "), m.projects.joined(separator: " "), ids,
                         m.aliases.joined(separator: " ")].joined(separator: " ").lowercased()
    }

    /// "Frau", "Frau and Girart", "Frau et al." — authors, else editors.
    static func creatorLabel(_ cs: [PersonName]) -> String {
        let authors = cs.filter { $0.role == "author" }
        let names = (authors.isEmpty ? cs : authors).map { $0.family.isEmpty ? $0.given : $0.family }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) et al."
        }
    }
}

/// What the library tab's left column can select.
enum LibrarySource: Hashable {
    case all, unread, recent, noPDF, files
    case project(String)            // a project path; also selects its sub-projects
    case tag(String)
}

/// A project in the left column. Paths like `10stage_paper/2025jan06_HCHii`
/// make a tree; a parent that exists only as a prefix is created for them.
struct ProjectNode: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var children: [ProjectNode]?
}

/// The library as the reader's library tab sees it: every paper's meta read
/// once, off the main thread, and again only when asked (no polling,
/// PAPER-LIBRARY.md §10). Used from the main thread only.
final class LibraryIndex: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var files: [FileEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedOnce = false

    let store: PaperLibraryStore
    private var generation = 0

    init(store: PaperLibraryStore) { self.store = store }

    func reload() {
        generation += 1
        let gen = generation, store = store
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (entries, files) = Self.load(store)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.entries = entries
                self.files = files
                self.loading = false
                self.loadedOnce = true
            }
        }
    }

    func loadIfNeeded() { if !loadedOnce && !loading { reload() } }

    /// Reads the library folder. Safe off the main thread.
    static func load(_ store: PaperLibraryStore) -> ([LibraryEntry], [FileEntry]) {
        let fm = FileManager.default
        struct Count: Decodable { let id: String }
        let entries = store.allPapers().map { p -> LibraryEntry in
            let dir = store.folder(p.folder)
            let anns = store.read([Count].self, from: dir.appendingPathComponent("annotations.json"))?.count ?? 0
            let notes = ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("notes").path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
            return LibraryEntry(folder: p.folder, meta: p.meta, annotationCount: anns, notes: notes)
        }
        let files = store.read([FileEntry].self, from: store.filesDir.appendingPathComponent("files.json")) ?? []
        return (entries, files)
    }

    // MARK: filtering (static, so the self-test can check it without a view)

    static func matches(_ e: LibraryEntry, _ s: LibrarySource) -> Bool {
        switch s {
        case .all: return true
        case .unread: return e.unread
        case .recent: return !e.lastOpened.isEmpty
        case .noPDF: return !e.hasPDF
        case .files: return false
        case .project(let p): return e.meta.projects.contains { $0 == p || $0.hasPrefix(p + "/") }
        case .tag(let t): return e.meta.tags.contains(t)
        }
    }

    /// Every word must appear (case-insensitive) somewhere in the entry.
    static func search(_ es: [LibraryEntry], _ query: String) -> [LibraryEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return es }
        return es.filter { e in words.allSatisfy { e.haystack.contains($0) } }
    }

    static func projectTree(_ paths: [String]) -> [ProjectNode] {
        // Every path and every prefix of it is a node.
        var all = Set<String>()
        for p in paths {
            let parts = p.split(separator: "/").map(String.init)
            for i in 1...max(parts.count, 1) where !parts.isEmpty { all.insert(parts.prefix(i).joined(separator: "/")) }
        }
        func children(of parent: String?) -> [ProjectNode] {
            all.filter { path in
                let parts = path.split(separator: "/")
                if let parent { return path.hasPrefix(parent + "/") && parts.count == parent.split(separator: "/").count + 1 }
                return parts.count == 1
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { path in
                let kids = children(of: path)
                return ProjectNode(path: path, children: kids.isEmpty ? nil : kids)
            }
        }
        return children(of: nil)
    }

    var projectTree: [ProjectNode] { Self.projectTree(entries.flatMap(\.meta.projects)) }

    /// Tags by how many papers have them, most first.
    var tagCounts: [(tag: String, count: Int)] {
        var c: [String: Int] = [:]
        for e in entries { for t in e.meta.tags { c[t, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    func count(_ s: LibrarySource) -> Int {
        s == .files ? files.count : entries.reduce(0) { $0 + (Self.matches($1, s) ? 1 : 0) }
    }
}
