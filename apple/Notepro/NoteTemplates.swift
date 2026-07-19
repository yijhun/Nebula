import Foundation

/// Typed-note templates. A note's `type:` frontmatter classifies it (meeting /
/// literature) — the Properties panel edits the fields, the notes library
/// browses by type. Notes live in the vault root (classified by type, not
/// folders, per the chosen design).
enum NoteTemplates {
    private static func stamp(_ date: Date, format: String) -> String {
        let f = DateFormatter(); f.dateFormat = format
        return f.string(from: date)
    }

    /// A meeting / seminar / colloquium note. `summary`/`transcript` are filled
    /// by the recorder; a hand-created note leaves them empty.
    static func meeting(date: Date = Date(), kind: String = "group-meeting",
                        speaker: String = "", event: String = "", title: String = "",
                        related: String = "", summary: String? = nil,
                        transcript: String? = nil) -> (title: String, body: String) {
        let day = stamp(date, format: "yyyy-MM-dd HHmm")
        let heading = title.isEmpty ? "會議 \(day)" : title
        // The recorder's summary already carries its own confidence-tiered
        // sections (## Key points / ## To verify / ## Suspected transcription
        // errors), so drop it in as-is. A hand-created note gets a blank 重點.
        let pointsBlock = summary?.isEmpty == false ? summary! : "## 重點\n\n- "
        var body = """
        ---
        type: meeting
        date: \(stamp(date, format: "yyyy-MM-dd HH:mm"))
        kind: \(kind)
        speaker: \(speaker)
        event: \(event)
        title: \(title)
        related: \(related)
        tags:
        ---

        # \(heading)

        \(pointsBlock)

        ## 待辦

        - [ ]\u{20}

        """
        if let transcript, !transcript.isEmpty {
            body += "\n## 逐字稿\n\n\(transcript)\n"
        }
        // File name: "會議 - <title or day>".
        let base = "會議 - " + (title.isEmpty ? day : String(title.prefix(50)).replacingOccurrences(of: "/", with: "-"))
        return (base, body)
    }

    /// A literature (reading) note. The importer (Zotero/arXiv/ADS/PDF) fills the
    /// metadata; a hand-created note starts blank. `zotero` is the stable Zotero
    /// item key — the durable anchor, since Better BibTeX may regenerate `cite`,
    /// so machine reconnection keys off `zotero`/`doi`/`arxiv`, not `cite`.
    static func literature(title: String = "", authors: String = "", year: String = "",
                           cite: String = "", doi: String = "", arxiv: String = "",
                           url: String = "", journal: String = "", volume: String = "",
                           pages: String = "", source: String = "", zotero: String = "",
                           pdf: String = "", topics: String = "", status: String = "to-read",
                           abstract: String = "", date: Date = Date()) -> (title: String, body: String) {
        let heading = title.isEmpty ? "文獻筆記" : title
        // Human citation line: "Authors (year) · Journal · [@cite] · [📄 PDF]".
        var citeLine = ""
        if !cite.isEmpty || !authors.isEmpty {
            var parts: [String] = []
            if !authors.isEmpty { parts.append(year.isEmpty ? authors : "\(authors) (\(year))") }
            if !journal.isEmpty { parts.append(journal) }
            if !cite.isEmpty { parts.append("`[@\(cite)]`") }
            if !pdf.isEmpty { parts.append("[📄 PDF](\(pdf))") }
            if !parts.isEmpty { citeLine = parts.joined(separator: " · ") + "\n\n" }
        }
        let body = """
        ---
        type: literature
        title: \(title)
        authors: \(authors)
        year: \(year)
        journal: \(journal)
        volume: \(volume)
        pages: \(pages)
        cite: \(cite)
        doi: \(doi)
        arxiv: \(arxiv)
        url: \(url)
        source: \(source)
        zotero: \(zotero)
        pdf: \(pdf)
        status: \(status)
        relevance:\u{20}
        topics: \(topics)
        added: \(stamp(date, format: "yyyy-MM-dd"))
        ---

        # \(heading)

        \(citeLine)## 摘要

        \(abstract)

        ## 方法

        ## 結果

        ## 我的評論

        ## 與我研究的關聯

        ## 引文

        """
        let base = "文獻 - " + (title.isEmpty ? "未命名" : String(title.prefix(50)).replacingOccurrences(of: "/", with: "-"))
        return (base, body)
    }
}
