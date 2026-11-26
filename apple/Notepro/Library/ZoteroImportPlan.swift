import Foundation

// MARK: - The plan (also written as plan.json for the real import to consume)

struct PlanIDs: Codable, Equatable {
    var doi: String?
    var arxiv: String?
    var bibcode: String?
}

struct PlannedFile: Codable {
    let zoteroKey: String
    let zoteroPath: String
    let resolvedPath: String?
    let exists: Bool
    let bytes: Int64?
}

struct AnnotationCounts: Codable, Equatable {
    var highlight = 0, note = 0, ink = 0, other = 0
    /// Image (area) annotations become figure regions, not annotations.
    var figureRegions = 0
    var total: Int { highlight + note + ink + other + figureRegions }
}

struct PlannedPaper: Codable {
    let zoteroKey: String
    let citekey: String
    var folder: String
    let itemType: String
    let title: String
    let year: String
    let authors: [String]
    let ids: PlanIDs
    let pdf: PlannedFile?
    let otherAttachments: Int
    let annotations: AnnotationCounts
    let projects: [String]
    let tags: [String]
    let keywords: [String]
    let status: String?
    let childNotes: Int
    var issues: [String]
}

struct DuplicateGroup: Codable {
    let reasons: [String]          // e.g. "doi 10.1086/…", "title+year"
    let citekeys: [String]
}

struct Orphan: Codable {
    enum Kind: String, Codable { case pdf, file, link, note }
    let kind: Kind
    let zoteroKey: String
    let label: String
    let exists: Bool?
    let collections: [String]
}

enum CollectionAction: String, Codable { case project, tag, drop }

struct CollectionRule: Codable {
    var action: CollectionAction
    let papers: Int
    /// Standalone files (PDFs without a parent paper) in the collection.
    var files: Int = 0
    let reason: String
}

struct VaultCheck: Codable {
    let vault: String
    let filesScanned: Int
    let citedKeys: Int
    /// Cited keys that no imported paper has, split by where they are instead.
    let unresolved: [String]
    let inZoteroTrash: [String]
    let onlyInVaultBib: [String]
    let notFound: [String]
}

struct ImportTotals: Codable {
    var liveItems = 0, trashedItems = 0, papers = 0, withPDF = 0, withoutPDF = 0
    var missingPDFFiles = 0, duplicateGroups = 0
    var orphanPDFs = 0, orphanFiles = 0, orphanLinks = 0, orphanNotes = 0
    var annotations = AnnotationCounts()
    /// On PDFs with no parent paper: they move with those PDFs.
    var annotationsOnOrphans = 0
    /// On attachments in the trash.
    var annotationsSkipped = 0
    var invariantFailures: [String] = []
}

struct ImportPlan: Codable {
    let generated: String
    let zoteroDir: String
    var totals: ImportTotals
    var papers: [PlannedPaper]
    var duplicates: [DuplicateGroup]
    var orphans: [Orphan]
    var collections: [String: CollectionRule]
    /// Citekeys of items in Zotero's trash (not imported), to explain citations.
    var trashedCitekeys: [String]
    var vault: VaultCheck?
}

// MARK: - Building the plan

enum ZoteroImportPlanner {

    /// Status words in tags become the paper's reading status.
    static let statusTags: [String: String] = [
        "unread": "unread", "to read": "unread", "reading": "reading", "read": "read",
    ]

    static func plan(_ lib: ZoteroLibrary, zoteroDir: URL,
                     mapping: [String: CollectionAction]? = nil) -> ImportPlan {
        let live = lib.items.filter { !$0.deleted }
        let liveIDs = Set(live.map(\.itemID))
        var totals = ImportTotals()
        totals.liveItems = live.count
        totals.trashedItems = lib.items.count - live.count

        // Collections → rules (proposed unless a mapping was given).
        let collPath = collectionPaths(lib.collections)
        var collCount: [Int64: Int] = [:], collFiles: [Int64: Int] = [:]
        for it in live { for c in Set(it.collectionIDs) { collCount[c, default: 0] += 1 } }
        for a in lib.attachments where !a.deleted && a.parentID == nil {
            for c in Set(a.collectionIDs) { collFiles[c, default: 0] += 1 }
        }
        let hasChildren = Set(lib.collections.compactMap(\.parentID))
        var rules: [String: CollectionRule] = [:]
        for c in lib.collections {
            let name = collPath[c.id] ?? c.name
            let n = collCount[c.id] ?? 0
            let proposed: (CollectionAction, String)
            if live.count >= 10, Double(n) >= 0.6 * Double(live.count) {
                proposed = (.drop, "holds \(n) of \(live.count) papers, so it says little")
            } else if hasChildren.contains(c.id) || c.parentID != nil
                        || c.name.lowercased().contains("project") {
                proposed = (.project, "looks like a project (name or sub-collections)")
            } else {
                proposed = (.tag, "default: a topic tag")
            }
            let action = mapping?[name] ?? proposed.0
            rules[name] = CollectionRule(action: action, papers: n, files: collFiles[c.id] ?? 0,
                                         reason: mapping?[name] != nil ? "from your mapping file" : proposed.1)
        }

        // Attachments and annotations by parent.
        let liveAtt = lib.attachments.filter { !$0.deleted }
        var attByParent: [Int64: [ZAttachment]] = [:]
        for a in liveAtt { if let p = a.parentID { attByParent[p, default: []].append(a) } }
        let attParent = Dictionary(uniqueKeysWithValues: liveAtt.map { ($0.itemID, $0.parentID) })
        var annByItem: [Int64: AnnotationCounts] = [:]
        for an in lib.annotations {
            guard let parentOfAtt = attParent[an.attachmentID] else { totals.annotationsSkipped += 1; continue }
            guard let item = parentOfAtt else { totals.annotationsOnOrphans += 1; continue }
            guard liveIDs.contains(item) else { totals.annotationsSkipped += 1; continue }
            var c = annByItem[item] ?? AnnotationCounts()
            switch an.type {
            case 1: c.highlight += 1
            case 2: c.note += 1
            case 3: c.figureRegions += 1
            case 4: c.ink += 1
            default: c.other += 1
            }
            annByItem[item] = c
        }
        var childNotes: [Int64: Int] = [:]
        for n in lib.notes where !n.deleted { if let p = n.parentID { childNotes[p, default: 0] += 1 } }

        // Papers.
        var papers: [PlannedPaper] = []
        var usedFolders: [String: String] = [:]   // lowercased folder → citekey
        for it in live.sorted(by: { $0.citekey.lowercased() < $1.citekey.lowercased() }) {
            var issues: [String] = []
            let atts = attByParent[it.itemID] ?? []
            let pdfs = atts.filter { $0.contentType == "application/pdf" && $0.linkMode != 3 }
                .sorted { ($0.linkMode == 2 ? 1 : 0) < ($1.linkMode == 2 ? 1 : 0) }
            var pdf: PlannedFile?
            if let first = pdfs.first {
                pdf = resolve(first, storage: lib.storageDir)
                if pdfs.count > 1 { issues.append("\(pdfs.count) PDFs attached; using \(first.key)") }
                if pdf?.exists == false { issues.append("PDF file not found"); totals.missingPDFFiles += 1 }
            }
            let other = atts.count - (pdf == nil ? 0 : 1)

            var citekey = it.citekey
            if citekey.isEmpty { issues.append("no citekey in Zotero"); citekey = "zotero-\(it.key)" }
            var folder = safeFolderName(citekey)
            if folder != citekey { issues.append("citekey has characters unsafe in a folder name; folder is \(folder)") }
            if let clash = usedFolders[folder.lowercased()] {
                var n = 2
                while usedFolders["\(folder)-\(n)".lowercased()] != nil { n += 1 }
                issues.append("folder name clashes with \(clash) (macOS ignores case); folder is \(folder)-\(n)")
                folder = "\(folder)-\(n)"
            }
            usedFolders[folder.lowercased()] = citekey

            var tags: [String] = [], keywords: [String] = [], status: String?
            for t in it.tags {
                let low = t.name.lowercased().trimmingCharacters(in: .whitespaces)
                if let s = statusTags[low] { status = s; continue }
                if t.automatic || isJournalKeyword(t.name) {
                    keywords.append(normaliseKeyword(t.name))
                } else {
                    tags.append(t.name)
                }
            }
            var projects: [String] = []
            for c in it.collectionIDs {
                guard let name = collPath[c], let rule = rules[name] else { continue }
                switch rule.action {
                case .project: projects.append(name)
                case .tag: tags.append(lastComponent(name))
                case .drop: break
                }
            }

            let paper = PlannedPaper(
                zoteroKey: it.key, citekey: citekey, folder: folder, itemType: it.type,
                title: it.fields["title"] ?? "", year: year(it.fields["date"]),
                authors: it.creators, ids: ids(it.fields),
                pdf: pdf, otherAttachments: other,
                annotations: annByItem[it.itemID] ?? AnnotationCounts(),
                projects: uniq(projects), tags: uniq(tags), keywords: uniq(keywords),
                status: status, childNotes: childNotes[it.itemID] ?? 0, issues: issues)
            papers.append(paper)
            if pdf != nil { totals.withPDF += 1 } else { totals.withoutPDF += 1 }
            let a = paper.annotations
            totals.annotations.highlight += a.highlight; totals.annotations.note += a.note
            totals.annotations.ink += a.ink; totals.annotations.other += a.other
            totals.annotations.figureRegions += a.figureRegions
        }
        totals.papers = papers.count

        // Orphans: attachments and notes with no parent paper.
        var orphans: [Orphan] = []
        for a in liveAtt where a.parentID == nil {
            let f = resolve(a, storage: lib.storageDir)
            let kind: Orphan.Kind = a.linkMode == 3 ? .link : (a.contentType == "application/pdf" ? .pdf : .file)
            orphans.append(Orphan(kind: kind, zoteroKey: a.key,
                                  label: a.path.map { stripStorage($0) } ?? a.contentType,
                                  exists: kind == .link ? nil : f.exists,
                                  collections: a.collectionIDs.compactMap { collPath[$0] }.sorted()))
            switch kind { case .pdf: totals.orphanPDFs += 1; case .file: totals.orphanFiles += 1; case .link: totals.orphanLinks += 1; case .note: break }
        }
        for n in lib.notes where !n.deleted && n.parentID == nil {
            orphans.append(Orphan(kind: .note, zoteroKey: "\(n.itemID)", label: n.title, exists: nil, collections: []))
            totals.orphanNotes += 1
        }

        let dups = duplicates(papers)
        totals.duplicateGroups = dups.count

        // Invariants: every live item planned exactly once, every live
        // attachment accounted for, every annotation counted or skipped.
        if papers.count != live.count {
            totals.invariantFailures.append("planned \(papers.count) papers for \(live.count) live items")
        }
        if Set(papers.map(\.zoteroKey)).count != papers.count {
            totals.invariantFailures.append("a Zotero item was planned twice")
        }
        let accounted = papers.reduce(0) { $0 + ($1.pdf == nil ? 0 : 1) + $1.otherAttachments }
            + orphans.filter { $0.kind != .note }.count
        let parentedToTrash = liveAtt.filter { a in a.parentID.map { !liveIDs.contains($0) } ?? false }.count
        if accounted + parentedToTrash != liveAtt.count {
            totals.invariantFailures.append("attachments: \(accounted) accounted + \(parentedToTrash) under trashed items ≠ \(liveAtt.count) live")
        }
        if totals.annotations.total + totals.annotationsOnOrphans + totals.annotationsSkipped != lib.annotations.count {
            totals.invariantFailures.append("annotations: \(totals.annotations.total) planned + \(totals.annotationsOnOrphans) on orphan PDFs + \(totals.annotationsSkipped) in trash ≠ \(lib.annotations.count)")
        }

        return ImportPlan(generated: ISO8601DateFormatter().string(from: Date()),
                          zoteroDir: zoteroDir.path, totals: totals, papers: papers,
                          duplicates: dups, orphans: orphans, collections: rules,
                          trashedCitekeys: lib.items.filter(\.deleted).map(\.citekey).filter { !$0.isEmpty }.sorted(),
                          vault: nil)
    }

    // MARK: identifiers

    static func ids(_ f: [String: String]) -> PlanIDs {
        var out = PlanIDs()
        if let d = f["DOI"]?.trimmingCharacters(in: .whitespaces), !d.isEmpty {
            out.doi = normaliseDOI(d)
            if let a = firstMatch(#"^10\.48550/arxiv\.(.+)$"#, in: out.doi!) { out.arxiv = a }
        }
        let sources = [f["archiveID"], f["extra"], f["url"], f["publicationTitle"]].compactMap { $0 }
        for s in sources where out.arxiv == nil {
            out.arxiv = firstMatch(#"(?i)arxiv[:./ ]\s*(?:org/(?:abs|pdf)/)?(?:abs/)?((?:[a-z\-]+/)?\d{4}\.\d{4,5}|[a-z\-]+(?:\.[A-Z]{2})?/\d{7})"#, in: s)
                ?? firstMatch(#"(?im)^_eprint:\s*(\S+)"#, in: s)
        }
        if let a = out.arxiv { out.arxiv = a.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression) }
        for s in [f["extra"], f["url"]].compactMap({ $0 }) where out.bibcode == nil {
            out.bibcode = firstMatch(#"(?im)^(?:ads )?bibcode:\s*(\S{19})"#, in: s)
                ?? firstMatch(#"adsabs\.harvard\.edu/abs/([0-9]{4}[A-Za-z&.]{5}[0-9A-Za-z.]{9}[A-Z])"#, in: s)
        }
        return out
    }

    static func normaliseDOI(_ d: String) -> String {
        d.lowercased()
            .replacingOccurrences(of: #"^(https?://(dx\.)?doi\.org/|doi:\s*)"#, with: "", options: .regularExpression)
    }

    // MARK: duplicates

    /// Papers sharing a DOI, an arXiv id, or a normalised title + year, joined
    /// transitively (A~B by DOI and B~C by title make one group).
    static func duplicates(_ papers: [PlannedPaper]) -> [DuplicateGroup] {
        var parent = Array(papers.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var reasons: [Int: Set<String>] = [:]
        func join(_ keyed: [String: [Int]], _ label: String) {
            for (k, idx) in keyed where idx.count > 1 {
                for i in idx.dropFirst() { parent[find(i)] = find(idx[0]) }
                for i in idx { reasons[i, default: []].insert("\(label) \(k)") }
            }
        }
        var byDOI: [String: [Int]] = [:], byArxiv: [String: [Int]] = [:], byTitle: [String: [Int]] = [:]
        for (i, p) in papers.enumerated() {
            if let d = p.ids.doi, !d.hasPrefix("10.48550/") { byDOI[d, default: []].append(i) }
            if let a = p.ids.arxiv { byArxiv[a, default: []].append(i) }
            let t = p.title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            if t.count >= 12 { byTitle["\(String(String.UnicodeScalarView(t)))|\(p.year)", default: []].append(i) }
        }
        join(byDOI, "doi"); join(byArxiv, "arXiv")
        // Same title + year is only a duplicate when no identifier says
        // otherwise: chapters of one book share its title but not their DOIs.
        func conflict(_ a: PlannedPaper, _ b: PlannedPaper) -> Bool {
            // An arXiv DOI and a journal DOI are the same paper's two versions.
            func journalDOI(_ p: PlannedPaper) -> String? { p.ids.doi.flatMap { $0.hasPrefix("10.48550/") ? nil : $0 } }
            if let x = journalDOI(a), let y = journalDOI(b), x != y { return true }
            if let x = a.ids.arxiv, let y = b.ids.arxiv, x != y { return true }
            return false
        }
        // Title keys are long; show them as "title+year".
        for (k, idx) in byTitle where idx.count > 1 {
            let yr = k.components(separatedBy: "|").last ?? ""
            let label = yr.isEmpty ? "same title, no year" : "title+year (\(yr))"
            for (n, i) in idx.enumerated() {
                for j in idx[(n + 1)...] where !conflict(papers[i], papers[j]) {
                    parent[find(j)] = find(i)
                    reasons[i, default: []].insert(label); reasons[j, default: []].insert(label)
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in papers.indices where reasons[i] != nil { groups[find(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.map { idx in
            DuplicateGroup(reasons: Array(idx.reduce(into: Set<String>()) { $0.formUnion(reasons[$1] ?? []) }).sorted(),
                           citekeys: idx.map { papers[$0].citekey }.sorted())
        }.sorted { $0.citekeys[0].lowercased() < $1.citekeys[0].lowercased() }
    }

    // MARK: helpers

    static func resolve(_ a: ZAttachment, storage: URL) -> PlannedFile {
        let raw = a.path ?? ""
        var url: URL?
        if raw.hasPrefix("storage:") {
            url = storage.appendingPathComponent(a.key).appendingPathComponent(stripStorage(raw))
        } else if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        }
        let attrs = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        return PlannedFile(zoteroKey: a.key, zoteroPath: raw, resolvedPath: url?.path,
                           exists: attrs != nil, bytes: (attrs?[.size] as? NSNumber)?.int64Value)
    }

    static func stripStorage(_ p: String) -> String {
        p.hasPrefix("storage:") ? String(p.dropFirst("storage:".count)) : p
    }

    static func safeFolderName(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let out = String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return out.hasPrefix(".") ? "_" + out.dropFirst() : out
    }

    /// AAS-style ("stars: formation") and arXiv-category ("Astrophysics - …")
    /// keywords that came in with a paper's metadata, even when Zotero
    /// recorded them as manual tags.
    static func isJournalKeyword(_ t: String) -> Bool {
        t.contains(": ") || t.hasPrefix("Astrophysics - ") || t.hasPrefix("Physics - ")
    }

    static func normaliseKeyword(_ t: String) -> String {
        t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func collectionPaths(_ cs: [ZCollection]) -> [Int64: String] {
        let byID = Dictionary(uniqueKeysWithValues: cs.map { ($0.id, $0) })
        var out: [Int64: String] = [:]
        for c in cs {
            var parts = [c.name], p = c.parentID, guardN = 0
            while let pid = p, let pc = byID[pid], guardN < 32 { parts.insert(pc.name, at: 0); p = pc.parentID; guardN += 1 }
            out[c.id] = parts.joined(separator: "/")
        }
        return out
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func year(_ date: String?) -> String {
        guard let d = date else { return "" }
        return firstMatch(#"(\d{4})"#, in: d) ?? ""
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return Range(r, in: s).map { String(s[$0]) }
    }

    static func uniq(_ a: [String]) -> [String] {
        var seen = Set<String>(); return a.filter { seen.insert($0).inserted }
    }
}
