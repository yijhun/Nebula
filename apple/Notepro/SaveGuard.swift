import AppKit

/// The last check before an editor's text overwrites a file. Whatever bug might
/// put the wrong text in the buffer, a save that would wipe out the file's
/// content doesn't happen silently: the file stays as it is, the new text goes
/// into version history, and the user decides.
///
/// Calibrated on a real vault's history (715 consecutive saves): fewer than 2%
/// kept under a quarter of the old text, and those were wholesale replacements,
/// including every save of the incident this exists for (0.176, 0.017, 0.028).
enum SaveGuard {
    enum Verdict: Equatable {
        case safe
        /// Most of the file's current text would be gone.
        case replacesDocument
        /// The text is byte-identical to another file this editor had open.
        case matchesOtherFile(URL)
    }

    static let minimumOldLength = 200
    static let minimumKeptFraction = 0.25
    /// Below this, identical text says nothing (empty notes, one-line skeletons).
    static let minimumMatchLength = 50

    /// `loaded` maps the files this editor has held to the hash of their text.
    static func verdict(disk: String?, proposed: String, target: URL,
                        loaded: [URL: Int]) -> Verdict {
        // No file (a new one) or no change: nothing can be overwritten.
        guard let disk, disk != proposed else { return .safe }
        if proposed.utf16.count >= minimumMatchLength {
            let hash = proposed.hashValue
            let path = target.standardizedFileURL.path
            if let other = loaded.first(where: {
                $0.value == hash && $0.key.standardizedFileURL.path != path
            })?.key {
                return .matchesOtherFile(other)
            }
        }
        if disk.utf16.count >= minimumOldLength,
           keptFraction(old: disk, new: proposed) < minimumKeptFraction {
            return .replacesDocument
        }
        return .safe
    }

    /// The share of `old`'s 8-character windows still present in `new`. Windows
    /// rather than lines, so editing a long paragraph (one "line") doesn't read
    /// as losing it, and CJK and English text count alike.
    static func keptFraction(old: String, new: String) -> Double {
        let before = windows(old)
        guard !before.isEmpty else { return 1 }
        return Double(before.intersection(windows(new)).count) / Double(before.count)
    }

    private static func windows(_ text: String, size: Int = 8) -> Set<Int> {
        let units = Array(text.utf16)
        guard units.count >= size else { return [] }
        var out = Set<Int>(minimumCapacity: units.count)
        for start in 0...(units.count - size) {
            var h = Hasher()
            for u in units[start..<(start + size)] { h.combine(u) }
            out.insert(h.finalize())
        }
        return out
    }

    // MARK: - Asking the user (replaced by the self-test)

    /// Blocks until answered. True means the new text should replace the file.
    static var askToReplace: (_ file: String, _ verdict: Verdict) -> Bool = { file, verdict in
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = LZ("這次儲存會取代這個檔案幾乎全部的內容") + "：\(file)"
        alert.informativeText = detail(verdict) + "\n\n" + LZ("檔案目前沒有被改動，編輯器裡的新文字已存入版本歷史。")
        alert.addButton(withTitle: LZ("保留原檔案"))
        alert.addButton(withTitle: LZ("用新內容取代"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// For saves nobody is waiting on (switching away from a file): the file
    /// was left alone and the text kept in history; say so.
    static var reportHeld: (_ file: String, _ detail: String) -> Void = { file, detail in
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = LZ("有一次儲存沒有寫入檔案") + "：\(file)"
            alert.informativeText = detail + "\n\n" + LZ("檔案維持原樣，那段文字可以在版本歷史找到。")
            alert.runModal()
        }
    }

    static func detail(_ verdict: Verdict) -> String {
        switch verdict {
        case .matchesOtherFile(let other):
            return LZ("編輯器裡的文字和另一個檔案完全相同") + "：\(other.lastPathComponent)"
        case .replacesDocument, .safe:
            return LZ("編輯器裡的文字幾乎不包含這個檔案原本的內容。")
        }
    }
}
