import Foundation

// The on-disk paper library (PAPER-LIBRARY.md §4.1): plain files, one folder
// per paper, named by citekey.
//
//   <library>/
//     <citekey>/
//       paper.pdf           the PDF (never modified)
//       meta.json           PaperMeta
//       annotations.json    [LibraryAnnotation]
//       figures.json        [LibraryFigure]
//     _files/               files that are not papers (FileEntry list in files.json)
//     .import/              what the last import was given and did

// MARK: - Models

struct PersonName: Codable, Equatable {
    var family: String
    var given: String
    var role: String = "author"
}

/// Bibliographic data, kept losslessly from Zotero: its item type, every
/// field it had, and the creators with their roles. `.bib` export maps this.
struct Bibliographic: Codable {
    var itemType: String
    var fields: [String: String]
    var creators: [PersonName]
}

struct PaperMeta: Codable {
    var citekey: String
    /// Keys of duplicates merged into this paper; they still resolve.
    var aliases: [String] = []
    var ids: PlanIDs
    var title: String
    var year: String
    var bibliographic: Bibliographic
    /// unread / reading / read, or nil when unknown.
    var status: String?
    var tags: [String] = []
    var keywords: [String] = []
    var projects: [String] = []
    /// preprint / published, when known (arXiv-only items start as preprint).
    var version: String?
    var pdf: String?                // file name inside the folder, e.g. "paper.pdf"
    var added: String
    var lastOpened: String?
    var lastPage: Int?
    /// Where it came from, so a re-import updates instead of duplicating.
    var zoteroKey: String?
}

struct LibraryAnnotation: Codable, Equatable {
    enum Kind: String, Codable { case highlight, note, ink }
    var id: String
    var kind: Kind
    var page: Int                   // 0-based page index
    /// PDF points, bottom-left origin: rects for highlight/note, paths for ink.
    var rects: [[Double]]? = nil
    var paths: [[Double]]? = nil
    var width: Double? = nil
    var color: String
    var text: String = ""
    var comment: String = ""
    var author: String = "user"     // "user" or "claude"
    var created: String = ""
}

struct LibraryFigure: Codable, Equatable {
    var label: String               // "Figure 3", "Table 1"
    var page: Int
    var rect: [Double]              // x1, y1, x2, y2 in PDF points, bottom-left origin
    var source: String              // zotero-figure / pdffigures2 / user / arxiv-source
    var caption: String = ""
}

struct FileEntry: Codable, Equatable {
    var name: String                // path inside _files/
    var collections: [String]
    var zoteroKey: String
    /// Set when the file looks like a paper (e.g. named by an ADS bibcode)
    /// and should be looked up and turned into one.
    var paperCandidate: String?
}

// MARK: - Store

/// Reads and writes the library folder. Every write is atomic (temp file +
/// rename), so a crash never leaves half a meta.json behind.
struct PaperLibraryStore {
    let root: URL

    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Nebula Library", isDirectory: true)
    }

    var filesDir: URL { root.appendingPathComponent("_files", isDirectory: true) }
    var importDir: URL { root.appendingPathComponent(".import", isDirectory: true) }

    func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    func meta(folder name: String) -> PaperMeta? {
        read(PaperMeta.self, from: folder(name).appendingPathComponent("meta.json"))
    }

    /// Every paper folder (anything with a meta.json), by folder name.
    func allPapers() -> [(folder: String, meta: PaperMeta)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { n in
            guard !n.hasPrefix("."), !n.hasPrefix("_"), let m = meta(folder: n) else { return nil }
            return (n, m)
        }
    }
}
