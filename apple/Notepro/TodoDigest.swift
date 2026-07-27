import Foundation

/// Shared to-do digest: gathers open `- [ ]` items and writes/updates the
/// "## 待辦彙整" section in today's daily note. Used by the 我的待辦 modal's
/// button and by the weekly auto-digest on launch.
enum TodoDigest {
    static let meetingTypes: Set<String> = ["meeting", "演講記錄"]
    static let boxRE = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+\[ \]\s?(.*)$"#)

    struct Group {
        let entry: IndexEntry
        let todos: [String]
    }

    /// Open todos grouped by source note (meeting notes only when
    /// `meetingsOnly`), newest note first. Blank template placeholders skipped.
    static func collect(_ entries: [IndexEntry], meetingsOnly: Bool) -> [Group] {
        var out: [Group] = []
        for e in entries where e.ext == "md" {
            if meetingsOnly, !meetingTypes.contains(e.properties["type"] ?? "") { continue }
            var todos: [String] = []
            for raw in e.content.components(separatedBy: "\n") {
                let ns = raw as NSString
                guard let m = boxRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length))
                else { continue }
                let text = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { todos.append(text) }
            }
            if !todos.isEmpty { out.append(Group(entry: e, todos: todos)) }
        }
        return out.sorted { ($0.entry.properties["date"] ?? $0.entry.title)
                          > ($1.entry.properties["date"] ?? $1.entry.title) }
    }

    /// Write the digest into today's daily note. Replaces a previous
    /// "## 待辦彙整" section instead of stacking; snapshots first. Returns the
    /// daily note URL when something was written.
    @discardableResult
    static func write(_ groups: [Group], vault: VaultModel) -> URL? {
        guard !groups.isEmpty,
              let url = vault.todayNote(),
              let original = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var section = "## 待辦彙整 (\(fmt.string(from: Date())))\n"
        for g in groups {
            let base = g.entry.url.deletingPathExtension().lastPathComponent
            section += "\n### [[\(base)]]\n"
            for t in g.todos { section += "- [ ] \(t)\n" }
        }
        var lines = original.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.hasPrefix("## 待辦彙整") }) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            lines.replaceSubrange(start..<end, with: section.components(separatedBy: "\n"))
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: section.components(separatedBy: "\n"))
        }
        let updated = lines.joined(separator: "\n")
        guard updated != original else { return nil }
        HistoryStore.snapshot(root: vault.rootURL, file: url, content: original)
        try? updated.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Weekly auto-run (launch-time): gated by the Settings toggle and by
    /// "last ran ≥ 7 days ago". Returns the daily note URL if a digest was
    /// written this call.
    static func autoRunIfDue(_ entries: [IndexEntry], vault: VaultModel) -> URL? {
        let d = UserDefaults.standard
        guard d.object(forKey: "autoTodoDigest") as? Bool ?? true else { return nil }
        let now = Date()
        if let last = d.object(forKey: "lastTodoDigest") as? Date,
           now.timeIntervalSince(last) < 7 * 86400 { return nil }
        let groups = collect(entries, meetingsOnly: true)
        guard let url = write(groups, vault: vault) else {
            // Nothing to digest — still mark the attempt so we don't re-check
            // every launch this week.
            d.set(now, forKey: "lastTodoDigest")
            return nil
        }
        d.set(now, forKey: "lastTodoDigest")
        return url
    }
}
