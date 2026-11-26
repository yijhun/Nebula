import Foundation
import SQLite3

// MARK: - A tiny read-only SQLite wrapper

/// Just enough SQLite for reading a Zotero database copy: open, query rows as
/// `[String: Any?]` (Int64 / Double / String / nil), close.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String, create: Bool = false) throws {
        // Opened read-write because a copied WAL is folded in on first read;
        // this is only ever a scratch copy, never the user's Zotero file.
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ZoteroImportError.database(msg)
        }
    }

    deinit { sqlite3_close(db) }

    /// Run statements with no result rows (used to build the self-test fixture).
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw ZoteroImportError.database(msg)
        }
    }

    func rows(_ sql: String) throws -> [[String: Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String: Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw ZoteroImportError.database(String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: Any?] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                default: row[name] = nil as Any?
                }
            }
            out.append(row)
        }
        return out
    }
}

enum ZoteroImportError: Error, CustomStringConvertible {
    case database(String)
    case missing(String)
    var description: String {
        switch self {
        case .database(let m): return "SQLite: \(m)"
        case .missing(let m): return m
        }
    }
}

// MARK: - What the importer reads from Zotero

struct ZAttachment {
    let itemID: Int64
    let key: String
    let parentID: Int64?
    let linkMode: Int64        // 0 imported file, 1 imported URL, 2 linked file, 3 linked URL
    let contentType: String
    let path: String?          // "storage:name.pdf" or an absolute path
    let deleted: Bool
    /// Standalone attachments can sit in collections themselves.
    let collectionIDs: [Int64]
}

struct ZAnnotation {
    let attachmentID: Int64
    let type: Int64            // 1 highlight, 2 note, 3 image, 4 ink (confirmed in the spike)
    let author: String
    let tags: [String]
}

struct ZNote {
    let itemID: Int64
    let parentID: Int64?
    let title: String
    let deleted: Bool
}

struct ZTag {
    let name: String
    let automatic: Bool        // itemTags.type 1 = added by an import, 0 = by the user
}

struct ZItem {
    let itemID: Int64
    let key: String
    let type: String
    let fields: [String: String]
    let creators: [String]     // last names (or single-field names), in order
    let tags: [ZTag]
    let collectionIDs: [Int64]
    let deleted: Bool
    /// Zotero 7's `citationKey` field, else a key pinned in `extra` as
    /// `Citation Key: …` or `tex.citationkey: …` (as `ZoteroWeb` reads it).
    var citekey: String {
        if let k = fields["citationKey"]?.trimmingCharacters(in: .whitespaces), !k.isEmpty { return k }
        for line in (fields["extra"] ?? "").components(separatedBy: .newlines) {
            if let r = line.range(of: #"(?i)^\s*(citation key|tex\.citationkey)\s*:\s*"#,
                                  options: .regularExpression) {
                let key = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { return key }
            }
        }
        return ""
    }
}

struct ZCollection {
    let id: Int64
    let name: String
    let parentID: Int64?
}

/// Everything the planner needs, read once from a snapshot.
struct ZoteroLibrary {
    var items: [ZItem] = []
    var attachments: [ZAttachment] = []
    var annotations: [ZAnnotation] = []
    var notes: [ZNote] = []
    var collections: [ZCollection] = []
    /// Where `storage:` paths resolve: `<zotero dir>/storage/<attachment key>/`.
    var storageDir: URL
}

// MARK: - Snapshot

enum ZoteroSnapshot {

    /// Copy `zotero.sqlite` with its `-wal` / `-shm` companions into a fresh
    /// temp folder, so the copy includes changes Zotero has not checkpointed
    /// yet. Zotero holds an exclusive lock while running, so its file can't
    /// be read in place; the copy never touches the original.
    static func copy(zoteroDir: URL) throws -> URL {
        let fm = FileManager.default
        let src = zoteroDir.appendingPathComponent("zotero.sqlite")
        guard fm.fileExists(atPath: src.path) else {
            throw ZoteroImportError.missing("No zotero.sqlite in \(zoteroDir.path)")
        }
        let dir = fm.temporaryDirectory
            .appendingPathComponent("nebula-zotero-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = zoteroDir.appendingPathComponent("zotero.sqlite\(suffix)")
            if fm.fileExists(atPath: from.path) {
                try fm.copyItem(at: from, to: dir.appendingPathComponent("zotero.sqlite\(suffix)"))
            }
        }
        let copy = dir.appendingPathComponent("zotero.sqlite")
        // Zotero may write while we copy; refuse a torn copy.
        let check = try SQLiteDB(path: copy.path).rows("PRAGMA quick_check").first?["quick_check"] as? String
        guard check == "ok" else {
            throw ZoteroImportError.database("the copied database failed its integrity check (\(check ?? "no answer")); close Zotero and try again")
        }
        return copy
    }

    /// Read a snapshot (or any Zotero-schema database) into memory.
    static func read(dbPath: URL, storageDir: URL) throws -> ZoteroLibrary {
        let db = try SQLiteDB(path: dbPath.path)
        var lib = ZoteroLibrary(storageDir: storageDir)

        let deleted = Set(try db.rows("SELECT itemID FROM deletedItems").compactMap { $0["itemID"] as? Int64 })

        var fields: [Int64: [String: String]] = [:]
        for r in try db.rows("""
            SELECT d.itemID, f.fieldName, v.value FROM itemData d
            JOIN fields f USING(fieldID) JOIN itemDataValues v USING(valueID)
            """) {
            guard let id = r["itemID"] as? Int64, let f = r["fieldName"] as? String,
                  let v = r["value"] as? String else { continue }
            fields[id, default: [:]][f] = v
        }

        var creators: [Int64: [String]] = [:]
        for r in try db.rows("""
            SELECT ic.itemID, c.lastName, c.firstName FROM itemCreators ic
            JOIN creators c USING(creatorID) ORDER BY ic.itemID, ic.orderIndex
            """) {
            guard let id = r["itemID"] as? Int64 else { continue }
            let last = (r["lastName"] as? String) ?? ""
            creators[id, default: []].append(last.isEmpty ? ((r["firstName"] as? String) ?? "") : last)
        }

        var tags: [Int64: [ZTag]] = [:]
        for r in try db.rows("SELECT it.itemID, t.name, it.type FROM itemTags it JOIN tags t USING(tagID)") {
            guard let id = r["itemID"] as? Int64, let n = r["name"] as? String else { continue }
            tags[id, default: []].append(ZTag(name: n, automatic: (r["type"] as? Int64) == 1))
        }

        var colls: [Int64: [Int64]] = [:]
        for r in try db.rows("SELECT collectionID, itemID FROM collectionItems") {
            guard let c = r["collectionID"] as? Int64, let i = r["itemID"] as? Int64 else { continue }
            colls[i, default: []].append(c)
        }

        for r in try db.rows("""
            SELECT i.itemID, i.key, t.typeName FROM items i JOIN itemTypes t USING(itemTypeID)
            """) {
            guard let id = r["itemID"] as? Int64, let key = r["key"] as? String,
                  let type = r["typeName"] as? String else { continue }
            switch type {
            case "attachment", "note", "annotation": continue
            default:
                lib.items.append(ZItem(itemID: id, key: key, type: type, fields: fields[id] ?? [:],
                                       creators: creators[id] ?? [], tags: tags[id] ?? [],
                                       collectionIDs: colls[id] ?? [], deleted: deleted.contains(id)))
            }
        }

        for r in try db.rows("""
            SELECT a.itemID, i.key, a.parentItemID, a.linkMode, a.contentType, a.path
            FROM itemAttachments a JOIN items i USING(itemID)
            """) {
            guard let id = r["itemID"] as? Int64, let key = r["key"] as? String else { continue }
            let parent = r["parentItemID"] as? Int64
            lib.attachments.append(ZAttachment(
                itemID: id, key: key, parentID: parent,
                linkMode: (r["linkMode"] as? Int64) ?? -1,
                contentType: (r["contentType"] as? String) ?? "",
                path: r["path"] as? String,
                deleted: deleted.contains(id) || parent.map { deleted.contains($0) } == true,
                collectionIDs: colls[id] ?? []))
        }

        for r in try db.rows("SELECT itemID, parentItemID, type, authorName FROM itemAnnotations") {
            guard let id = r["itemID"] as? Int64, let parent = r["parentItemID"] as? Int64 else { continue }
            if deleted.contains(id) { continue }
            lib.annotations.append(ZAnnotation(
                attachmentID: parent, type: (r["type"] as? Int64) ?? 0,
                author: (r["authorName"] as? String) ?? "",
                tags: (tags[id] ?? []).map(\.name)))
        }

        for r in try db.rows("SELECT itemID, parentItemID, title FROM itemNotes") {
            guard let id = r["itemID"] as? Int64 else { continue }
            let parent = r["parentItemID"] as? Int64
            lib.notes.append(ZNote(itemID: id, parentID: parent, title: (r["title"] as? String) ?? "",
                                   deleted: deleted.contains(id) || parent.map { deleted.contains($0) } == true))
        }

        for r in try db.rows("SELECT collectionID, collectionName, parentCollectionID FROM collections") {
            guard let id = r["collectionID"] as? Int64, let n = r["collectionName"] as? String else { continue }
            lib.collections.append(ZCollection(id: id, name: n, parentID: r["parentCollectionID"] as? Int64))
        }
        return lib
    }
}
