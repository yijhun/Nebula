import Foundation

/// Per-file revision snapshots, stored in the vault's hidden `.notepro/history/`
/// folder (ignored by the file scan + Obsidian). Each save writes a snapshot
/// (deduped against the latest); the user can browse and restore any version.
enum HistoryStore {
    struct Snapshot: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    private static let keep = 60

    /// History folder for a file (relative path flattened into the name).
    static func historyDir(root: URL?, for file: URL) -> URL? {
        guard let root else { return nil }
        let rootPath = root.standardizedFileURL.path
        var rel = file.standardizedFileURL.path
        if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)) }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let safe = rel.replacingOccurrences(of: "/", with: "__")
        return root.standardizedFileURL
            .appendingPathComponent(".notepro/history", isDirectory: true)
            .appendingPathComponent(safe.isEmpty ? "untitled" : safe, isDirectory: true)
    }

    /// All snapshots for a file, newest first. The filename is a millisecond
    /// timestamp — used for both the date and the ordering (reliable, unique).
    static func list(root: URL?, for file: URL) -> [Snapshot] {
        guard let dir = historyDir(root: root, for: file),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "snap" }
            .compactMap { u -> Snapshot? in
                guard let ms = Int64(u.deletingPathExtension().lastPathComponent) else { return nil }
                return Snapshot(url: u, date: Date(timeIntervalSince1970: Double(ms) / 1000))
            }
            .sorted { $0.date > $1.date }
    }

    static func content(_ snap: Snapshot) -> String {
        (try? String(contentsOf: snap.url, encoding: .utf8)) ?? ""
    }

    /// Save a snapshot of `content` for `file` (skips if identical to the latest).
    static func snapshot(root: URL?, file: URL, content text: String) {
        guard let dir = historyDir(root: root, for: file) else { return }
        let existing = list(root: root, for: file)
        if let latest = existing.first, content(latest) == text { return } // dedupe
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ms = Int64(Date().timeIntervalSince1970 * 1000)
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(ms).snap").path) { ms += 1 }
        let url = dir.appendingPathComponent("\(ms).snap")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        prune(existing + [Snapshot(url: url, date: Date())])
    }

    private static func prune(_ snaps: [Snapshot]) {
        let keepers = retained(snaps.map(\.date), now: Date())
        for s in snaps where !keepers.contains(s.date) { try? FileManager.default.removeItem(at: s.url) }
    }

    /// Which snapshots survive. Autosave snapshots every couple of seconds, so
    /// a flat "newest N" would let a few minutes of saves, including saves of a
    /// damaged file, push out the last good version. Older ones are thinned
    /// instead: the newest 60, then one per hour for a week, then one per day.
    static func retained(_ dates: [Date], now: Date) -> Set<Date> {
        let sorted = dates.sorted(by: >)
        var out = Set(sorted.prefix(keep))
        var seen = Set<Int>()
        for date in sorted.dropFirst(keep) {
            let age = now.timeIntervalSince(date)
            let bucket = age < 7 * 86_400
                ? Int(date.timeIntervalSince1970 / 3_600)
                : -Int(date.timeIntervalSince1970 / 86_400)   // negative: never collides with an hour
            if seen.insert(bucket).inserted { out.insert(date) }
        }
        return out
    }
}
