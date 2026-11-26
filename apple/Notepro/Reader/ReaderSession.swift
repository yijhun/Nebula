import Foundation
import PDFKit
import AppKit

/// Where a tab was reading.
struct ReaderPosition: Codable, Equatable {
    var page: Int = 0
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 0          // 0 = fit width
}

/// One tab: a paper (or any PDF) and where it was read up to. A tab whose
/// document is not in the session's small cache is "suspended": it costs a
/// few bytes and reopens at its position when selected (PAPER-LIBRARY.md §10).
struct ReaderTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    /// Library folder name when the PDF is a library paper's `paper.pdf`.
    var folder: String?
    var title: String
    var position = ReaderPosition()
}

/// The reader's tabs, shared by the reader window. Documents are kept open
/// only for the most recently used tabs; the rest are suspended.
final class ReaderSession: ObservableObject {
    static let shared = ReaderSession()

    @Published private(set) var tabs: [ReaderTab] = []
    @Published var activeID: UUID?
    /// Bumped when the active tab's document should be (re)attached to the view.
    @Published private(set) var generation = 0
    /// Set by the "Open Paper" menu command; the reader window shows its picker.
    @Published var requestQuickOpen = false

    /// A place to show once the tab is on screen (from a nebula://paper link).
    struct Goto: Equatable { let tab: UUID; let page: Int; let quote: String? }
    @Published var pendingGoto: Goto?

    // MARK: paper links

    /// nebula://paper/<citekey>?page=N&quote=… → open that paper at that place.
    func openLink(_ url: URL) {
        guard let link = Self.parse(url), let folder = folder(forCitekey: link.key) else { return }
        openFolder(folder)
        if let id = activeID { pendingGoto = Goto(tab: id, page: link.page, quote: link.quote) }
    }

    /// Is the link's quote really on its page? (Unparsable or unknown → false.)
    func verify(link: String) -> Bool {
        guard let url = URL(string: link), let l = Self.parse(url), let folder = folder(forCitekey: l.key),
              let doc = verifyDoc(folder), let page = doc.page(at: l.page) else { return false }
        guard let q = l.quote, !q.isEmpty else { return true }
        return ReaderMCPTools.quoteOnPage(q, page: page)
    }

    static func parse(_ url: URL) -> (key: String, page: Int, quote: String?)? {
        guard url.scheme == "nebula", url.host == "paper" else { return nil }
        let key = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !key.isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = max(1, Int(items.first { $0.name == "page" }?.value ?? "1") ?? 1) - 1
        return (key, page, items.first { $0.name == "quote" }?.value)
    }

    private var keyToFolder: [String: String] = [:]
    func folder(forCitekey key: String) -> String? {
        if store.meta(folder: key) != nil { return key }
        if keyToFolder.isEmpty {
            for p in store.allPapers() {
                keyToFolder[p.meta.citekey] = p.folder
                for a in p.meta.aliases { keyToFolder[a] = p.folder }
            }
        }
        return keyToFolder[key]
    }

    private var verifyDocs: [String: PDFDocument] = [:]
    private func verifyDoc(_ folder: String) -> PDFDocument? {
        if let d = verifyDocs[folder] { return d }
        guard let d = PDFDocument(url: store.folder(folder).appendingPathComponent("paper.pdf")) else { return nil }
        if verifyDocs.count > 3 { verifyDocs.removeAll() }
        verifyDocs[folder] = d
        return d
    }

    /// How many documents stay open; the rest of the tabs are suspended.
    static let liveDocuments = 5
    private var docs: [UUID: PDFDocument] = [:]
    private var lru: [UUID] = []
    private var closed: [ReaderTab] = []

    let store: PaperLibraryStore
    /// Off in tests: no tabs or positions read from / written to UserDefaults.
    private let persists: Bool
    private lazy var zoteroPathToFolder: [String: String] = Self.loadPathIndex(store)

    init(store: PaperLibraryStore = PaperLibraryStore(root: PaperLibraryStore.defaultRoot), persists: Bool = true) {
        self.store = store
        self.persists = persists
        if persists { restore() }
    }

    var active: ReaderTab? { tabs.first { $0.id == activeID } }
    func isLive(_ id: UUID) -> Bool { docs[id] != nil }

    // MARK: open / close

    /// Open a PDF in a tab (or switch to the tab already showing it).
    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let t = tabs.first(where: { $0.url == url }) { select(t.id); return }
        let folder = libraryFolder(for: url)
        var title = url.deletingPathExtension().lastPathComponent
        var tab = ReaderTab(url: folder.map { store.folder($0).appendingPathComponent("paper.pdf") } ?? url,
                            folder: folder, title: title)
        if let f = folder, let m = store.meta(folder: f) {
            title = m.citekey
            tab.title = title
            if let p = m.lastPage { tab.position.page = p }
        }
        if persists, let saved = Self.savedPositions[tab.url.path] { tab.position = saved }
        tabs.append(tab)
        select(tab.id)
    }

    func openFolder(_ folder: String) {
        open(store.folder(folder).appendingPathComponent("paper.pdf"))
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        touch(id)
        generation += 1
        persist()
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let t = tabs.remove(at: i)
        closed.append(t)
        if closed.count > 20 { closed.removeFirst() }
        docs[id] = nil
        lru.removeAll { $0 == id }
        if activeID == id {
            activeID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
            if let a = activeID { touch(a) }
            generation += 1
        }
        persist()
    }

    func reopenClosed() {
        guard let t = closed.popLast() else { return }
        tabs.append(t)
        select(t.id)
    }

    func selectNext(_ step: Int = 1) {
        guard let a = activeID, let i = tabs.firstIndex(where: { $0.id == a }), !tabs.isEmpty else { return }
        select(tabs[(i + step + tabs.count) % tabs.count].id)
    }

    // MARK: documents

    /// The document for a tab, opening it (and suspending the least recently
    /// used one) if needed.
    func document(for id: UUID) -> PDFDocument? {
        if let d = docs[id] { return d }
        guard let tab = tabs.first(where: { $0.id == id }),
              let d = ReaderDocument.open(tab.url) else { return nil }
        if let f = tab.folder { ReaderAnnotations.load(into: d, folder: f, store: store) }
        docs[id] = d
        touch(id)
        return d
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
        while lru.count > Self.liveDocuments {
            let old = lru.removeFirst()
            if let d = docs[old], let tab = tabs.first(where: { $0.id == old }) {
                saveAnnotations(tab: tab, document: d)
            }
            docs[old] = nil
        }
        objectWillChange.send()
    }

    // MARK: position and annotations

    func updatePosition(_ id: UUID, _ pos: ReaderPosition) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].position != pos else { return }
        tabs[i].position = pos
        if persists { Self.savedPositions[tabs[i].url.path] = pos }
        if let f = tabs[i].folder, var m = store.meta(folder: f), m.lastPage != pos.page {
            m.lastPage = pos.page
            m.lastOpened = ISO8601DateFormatter().string(from: Date())
            try? store.write(m, to: store.folder(f).appendingPathComponent("meta.json"))
        }
        persist()
    }

    /// Library papers keep annotations in annotations.json; other PDFs keep
    /// them inside the PDF, as before.
    func saveAnnotations(tab: ReaderTab, document: PDFDocument) {
        if let f = tab.folder {
            ReaderAnnotations.save(from: document, folder: f, store: store)
        } else if document.documentURL?.isFileURL == true, ReaderAnnotations.dirty(document) {
            document.write(to: tab.url)
            ReaderAnnotations.markClean(document)
        }
    }

    func saveActive() {
        guard let id = activeID, let d = docs[id], let t = active else { return }
        saveAnnotations(tab: t, document: d)
    }

    func saveAll() {
        for (id, d) in docs { if let t = tabs.first(where: { $0.id == id }) { saveAnnotations(tab: t, document: d) } }
    }

    // MARK: library lookup

    /// A PDF is a library paper if it is a folder's paper.pdf, or the Zotero
    /// file a library paper was imported from.
    func libraryFolder(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let root = store.root.standardizedFileURL.path + "/"
        if path.hasPrefix(root), url.lastPathComponent == "paper.pdf" {
            let folder = url.deletingLastPathComponent().lastPathComponent
            return store.meta(folder: folder) != nil ? folder : nil
        }
        return zoteroPathToFolder[path]
    }

    private static func loadPathIndex(_ store: PaperLibraryStore) -> [String: String] {
        guard let plan = store.read(ImportPlan.self, from: store.importDir.appendingPathComponent("plan.json")) else { return [:] }
        var out: [String: String] = [:]
        for p in plan.papers { if let path = p.pdf?.resolvedPath { out[URL(fileURLWithPath: path).standardizedFileURL.path] = p.folder } }
        return out
    }

    // MARK: persistence (tabs survive a relaunch, all suspended)

    private static let tabsKey = "readerTabs", activeKey = "readerActiveTab", posKey = "readerPositions"

    static var savedPositions: [String: ReaderPosition] {
        get {
            guard let d = UserDefaults.standard.data(forKey: posKey) else { return [:] }
            return (try? JSONDecoder().decode([String: ReaderPosition].self, from: d)) ?? [:]
        }
        set {
            var v = newValue
            if v.count > 500 { v = Dictionary(uniqueKeysWithValues: v.prefix(500).map { ($0.key, $0.value) }) }
            UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: posKey)
        }
    }

    private func persist() {
        guard persists else { return }
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(tabs), forKey: Self.tabsKey)
        d.set(activeID?.uuidString, forKey: Self.activeKey)
    }

    private func restore() {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: Self.tabsKey),
              let saved = try? JSONDecoder().decode([ReaderTab].self, from: data) else { return }
        tabs = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        activeID = d.string(forKey: Self.activeKey).flatMap(UUID.init) ?? tabs.first?.id
        if let a = activeID, !tabs.contains(where: { $0.id == a }) { activeID = tabs.first?.id }
    }
}

/// Opens PDFs with the reader's page class (for dark mode).
enum ReaderDocument {
    static func open(_ url: URL) -> PDFDocument? {
        guard let d = PDFDocument(url: url) else { return nil }
        d.delegate = ReaderPageClass.shared
        return d
    }
}

final class ReaderPageClass: NSObject, PDFDocumentDelegate {
    static let shared = ReaderPageClass()
    func classForPage() -> AnyClass { ReaderPage.self }
}
