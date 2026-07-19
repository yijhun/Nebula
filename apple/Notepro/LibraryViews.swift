import SwiftUI
import AppKit
import UniformTypeIdentifiers



/// Notes library — the typed research notes in the vault, split into tabs:
/// 論文 (literature notes: PDF annotations + arXiv/ADS imports) and
/// 會議 (meeting / seminar notes from the recorder or the menu). Both accept
/// legacy `type` spellings so older notes still show up.
struct LiteratureLibraryView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var index: IndexService
    let onOpen: (URL) -> Void
    let onChanged: (URL) -> Void        // a note was rewritten on disk (Zotero backfill)
    let onClose: () -> Void

    @State private var tab = "literature"          // "literature" | "meeting"
    @State private var query = ""
    @State private var sortBy = "year"
    @State private var statusFilter = "all"        // papers only
    @State private var groupBySeries = true        // meetings: timeline per event
    @State private var backfilling = Set<String>() // note paths with a Zotero fetch in flight
    @State private var backfillMsg = ""
    @AppStorage("litReadPaths") private var readPathsData = Data()

    static let litTypes: Set<String> = ["literature", "literature-note"]
    private static let meetingTypes: Set<String> = ["meeting", "演講記錄"]

    /// Whether a frontmatter `type` value is one of the literature spellings.
    static func isLiteratureType(_ type: String?) -> Bool { litTypes.contains(type ?? "") }

    private var readPaths: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: readPathsData)) ?? []
    }
    private func setRead(_ url: URL, _ read: Bool) {
        var s = readPaths
        if read { s.insert(url.path) } else { s.remove(url.path) }
        readPathsData = (try? JSONEncoder().encode(s)) ?? Data()
    }

    private var isMeeting: Bool { tab == "meeting" }

    private var items: [IndexEntry] {
        let types = isMeeting ? Self.meetingTypes : Self.litTypes
        var list = index.entries.filter { types.contains($0.properties["type"] ?? "") }
        if !isMeeting, statusFilter != "all" {
            list = list.filter { ($0.properties["status"] ?? "to-read") == statusFilter }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q)
                || ($0.properties["authors"] ?? "").lowercased().contains(q)
                || ($0.properties["speaker"] ?? "").lowercased().contains(q)
                || ($0.properties["event"] ?? "").lowercased().contains(q)
                || ($0.properties["cite"] ?? "").lowercased().contains(q)
                || $0.content.lowercased().contains(q)
            }
        }
        if isMeeting {
            return list.sorted { ($0.properties["date"] ?? "") > ($1.properties["date"] ?? "") }
        }
        switch sortBy {
        case "author": return list.sorted { ($0.properties["authors"] ?? "") < ($1.properties["authors"] ?? "") }
        case "title": return list.sorted { $0.title < $1.title }
        default: return list.sorted { ($0.properties["year"] ?? "") > ($1.properties["year"] ?? "") }
        }
    }

    /// Meetings grouped by `event` (series), most recently active series first;
    /// within a series the meetings run newest → oldest (a timeline).
    private var seriesGroups: [(name: String, meetings: [IndexEntry])] {
        let byEvent = Dictionary(grouping: items) { e -> String in
            let ev = (e.properties["event"] ?? "").trimmingCharacters(in: .whitespaces)
            return ev.isEmpty ? LZ("（未分系列）") : ev
        }
        return byEvent
            .map { (name: $0.key, meetings: $0.value) }   // items is already date-sorted
            .sorted { ($0.meetings.first?.properties["date"] ?? "") > ($1.meetings.first?.properties["date"] ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(LZ("論文")).tag("literature")
                Text(LZ("會議")).tag("meeting")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 200).padding(.top, 12)
            HStack(spacing: 10) {
                Image(systemName: isMeeting ? "person.wave.2" : "books.vertical").foregroundStyle(.secondary)
                TextField(isMeeting ? LZ("搜尋主題 / 講者 / 場合…") : LZ("搜尋標題 / 作者 / citekey…"), text: $query)
                    .textFieldStyle(.plain).font(.title3)
                if isMeeting {
                    Toggle(LZ("依系列"), isOn: $groupBySeries)
                        .toggleStyle(.switch).controlSize(.small)
                        .help(LZ("同一場合的歷次會議串成時間軸"))
                } else {
                    Picker("", selection: $sortBy) {
                        Text(LZ("年份")).tag("year")
                        Text(LZ("作者")).tag("author")
                        Text(LZ("標題")).tag("title")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
            }
            .padding(12)
            if !isMeeting {
                Picker("", selection: $statusFilter) {
                    Text(LZ("全部")).tag("all")
                    Text(LZ("待讀")).tag("to-read")
                    Text(LZ("讀中")).tag("reading")
                    Text(LZ("讀完")).tag("done")
                }.pickerStyle(.segmented).labelsHidden()
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: isMeeting ? "person.wave.2" : "books.vertical")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text(isMeeting ? LZ("還沒有會議筆記") : LZ("還沒有文獻筆記")).foregroundStyle(.secondary)
                    Text(isMeeting
                         ? LZ("用「錄演講 / 轉文字」錄音，或選單「會議筆記」新增。")
                         : LZ("用「找文獻 arXiv/ADS」匯入，或在 PDF 閱讀器按「建立文獻筆記」。"))
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isMeeting && groupBySeries {
                List {
                    ForEach(seriesGroups, id: \.name) { g in
                        Section {
                            ForEach(g.meetings) { e in meetingRow(e, inSeries: true) }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar.badge.clock")
                                Text(g.name)
                                Text("· \(g.meetings.count) \(LZ("場"))").foregroundStyle(.secondary)
                            }.font(.caption.weight(.semibold))
                        }
                    }
                }.listStyle(.inset)
            } else {
                List(items) { e in isMeeting ? AnyView(meetingRow(e)) : AnyView(paperRow(e)) }
                    .listStyle(.plain)
            }
            Divider()
            HStack {
                Text(backfillMsg.isEmpty ? "\(items.count) \(isMeeting ? LZ("場") : LZ("篇"))" : backfillMsg)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 680, height: 560)
    }

    private func paperRow(_ e: IndexEntry) -> some View {
        let isRead = readPaths.contains(e.url.path)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                setRead(e.url, !isRead)
            } label: {
                Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isRead ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain).help(isRead ? "標為未讀" : "標為已讀")
            VStack(alignment: .leading, spacing: 3) {
                Text(e.properties["title"] ?? e.title)
                    .font(.callout.weight(isRead ? .regular : .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(e.properties["authors"] ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let y = e.properties["year"], !y.isEmpty {
                        Text("· \(y)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = e.properties["source"], !s.isEmpty {
                        Text(s).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if let st = e.properties["status"], !st.isEmpty, st != "to-read" {
                        Text(st).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if backfilling.contains(e.url.path) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { backfill(e) } label: { Image(systemName: "arrow.down.doc") }
                        .buttonStyle(.borderless).help(LZ("從 Zotero 回填書目"))
                }
                Button { onOpen(e.url) } label: { Image(systemName: "doc.text") }
                    .buttonStyle(.borderless).help("開啟筆記")
                if let cite = e.properties["cite"], !cite.isEmpty {
                    Button { EditorModel.openInZotero(citekey: cite) } label: { Image(systemName: "books.vertical.circle") }
                        .buttonStyle(.borderless).help("在 Zotero 開啟")
                    Button { EditorModel.openPDFInZotero(citekey: cite) } label: { Image(systemName: "doc.richtext") }
                        .buttonStyle(.borderless).help(LZ("在 Zotero 開 PDF"))
                }
                if let urlStr = e.properties["url"], let u = URL(string: urlStr) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless).help("開啟連結")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(e.url) }
    }

    /// Pull the item's full record from Zotero and fill the note's blank fields.
    private func backfill(_ e: IndexEntry) {
        let path = e.url.path
        guard !backfilling.contains(path) else { return }
        backfilling.insert(path); backfillMsg = ""
        LiteratureFill.backfill(url: e.url, props: e.properties, title: e.title,
                                vaultRoot: vault.rootURL) { msg, changed in
            backfilling.remove(path)
            backfillMsg = msg
            if let changed { onChanged(changed) }
        }
    }

    private func meetingRow(_ e: IndexEntry, inSeries: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if inSeries {
                // Timeline marker: the date leads, dot + rail underneath.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String((e.properties["date"] ?? "").prefix(10)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(width: 78, alignment: .trailing)
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 4)
            } else {
                Image(systemName: "person.wave.2.fill").foregroundStyle(.secondary).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(e.properties["title"].flatMap { $0.isEmpty ? nil : $0 } ?? e.title)
                    .font(.callout.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let sp = e.properties["speaker"], !sp.isEmpty {
                        Text(sp).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !inSeries, let ev = e.properties["event"], !ev.isEmpty {
                        Text("· \(ev)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let k = e.properties["kind"], !k.isEmpty {
                        Text(k).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                if !inSeries, let d = e.properties["date"], !d.isEmpty {
                    Text(d).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button { onOpen(e.url) } label: { Image(systemName: "doc.text") }
                .buttonStyle(.borderless).help("開啟筆記")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(e.url) }
    }
}


/// 我的待辦 — every open `- [ ]` checkbox across the vault gathered into one
/// list, grouped by source note. Defaults to meeting notes (where action items
/// pile up) with a toggle to scan everything. Ticking an item writes `- [x]`
/// back to the file (snapshotted first) so it stays in sync with the note.
struct TodoLibraryView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var index: IndexService
    let onOpen: (URL, Int?) -> Void
    let onChanged: (URL) -> Void        // file rewritten on disk → reload + reindex
    let onClose: () -> Void

    @State private var meetingsOnly = true
    @State private var query = ""

    struct Todo: Identifiable {
        let url: URL
        let line: Int          // 1-based
        let text: String
        var id: String { "\(url.path):\(line)" }
    }

    private static let meetingTypes: Set<String> = ["meeting", "演講記錄"]
    // Leading bullet ("- ", "* ", "+ ", with optional indent) + an empty box.
    private static let boxRE = try! NSRegularExpression(
        pattern: #"^\s*[-*+]\s+\[ \]\s?(.*)$"#)

    private var groups: [(entry: IndexEntry, todos: [Todo])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(IndexEntry, [Todo])] = []
        let scanned = index.entries.filter {
            $0.ext == "md" &&
            (!meetingsOnly || Self.meetingTypes.contains($0.properties["type"] ?? ""))
        }
        for e in scanned {
            var todos: [Todo] = []
            let lines = e.content.components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let ns = raw as NSString
                guard let m = Self.boxRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length))
                else { continue }
                let text = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }        // skip the blank template placeholder
                if !q.isEmpty, !text.lowercased().contains(q), !e.title.lowercased().contains(q) { continue }
                todos.append(Todo(url: e.url, line: i + 1, text: text))
            }
            if !todos.isEmpty { out.append((e, todos)) }
        }
        return out.sorted { ($0.0.properties["date"] ?? $0.0.title) > ($1.0.properties["date"] ?? $1.0.title) }
    }

    private var total: Int { groups.reduce(0) { $0 + $1.todos.count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                TextField(LZ("搜尋待辦…"), text: $query)
                    .textFieldStyle(.plain).font(.title3)
                Toggle(LZ("只看會議"), isOn: $meetingsOnly).toggleStyle(.switch).controlSize(.small)
            }
            .padding(12)
            Divider()
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(LZ("沒有未完成的待辦")).foregroundStyle(.secondary)
                    Text(LZ("會議筆記「## 待辦」裡的 - [ ] 會出現在這裡。"))
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.entry.id) { g in
                        Section {
                            ForEach(g.todos) { t in row(t) }
                        } header: {
                            Button {
                                onOpen(g.entry.url, nil)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: Self.meetingTypes.contains(g.entry.properties["type"] ?? "")
                                          ? "person.wave.2" : "doc.text")
                                    Text(g.entry.properties["title"].flatMap { $0.isEmpty ? nil : $0 } ?? g.entry.title)
                                        .lineLimit(1)
                                }.font(.caption.weight(.semibold))
                            }.buttonStyle(.plain)
                        }
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(total) \(LZ("項待辦"))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    digestToDaily()
                } label: {
                    Label(LZ("彙整到 Daily Note"), systemImage: "calendar.badge.plus")
                }
                .disabled(groups.isEmpty)
                .help(LZ("把目前列出的未完成待辦寫進今天的 Daily Note（重跑會更新同一段）"))
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 620, height: 540)
    }

    /// Write the currently-listed open todos into today's daily note as a
    /// "## 待辦彙整" section with [[wikilinks]] back to each source note.
    /// Re-running replaces the previous digest section instead of stacking.
    private func digestToDaily() {
        guard let url = vault.todayNote(),
              let original = try? String(contentsOf: url, encoding: .utf8) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var section = "## 待辦彙整 (\(fmt.string(from: Date())))\n"
        for g in groups {
            let base = g.entry.url.deletingPathExtension().lastPathComponent
            section += "\n### [[\(base)]]\n"
            for t in g.todos { section += "- [ ] \(t.text)\n" }
        }
        var lines = original.components(separatedBy: "\n")
        // Replace an existing digest (any date) or append at the end.
        if let start = lines.firstIndex(where: { $0.hasPrefix("## 待辦彙整") }) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            lines.replaceSubrange(start..<end, with: section.components(separatedBy: "\n"))
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: section.components(separatedBy: "\n"))
        }
        HistoryStore.snapshot(root: vault.rootURL, file: url, content: original)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        onChanged(url)
        onOpen(url, nil)
    }

    private func row(_ t: Todo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { markDone(t) } label: {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }.buttonStyle(.plain).help(LZ("標為完成"))
            Text(t.text).font(.callout).lineLimit(3)
            Spacer()
            Button { onOpen(t.url, t.line) } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(.borderless).help(LZ("到原文"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(t.url, t.line) }
    }

    /// Tick a box on disk: rewrite the matched line's `[ ]` → `[x]`, snapshot
    /// first, then reindex so the item drops out of the list.
    private func markDone(_ t: Todo) {
        guard let original = try? String(contentsOf: t.url, encoding: .utf8) else { return }
        var lines = original.components(separatedBy: "\n")
        guard t.line - 1 < lines.count else { return }
        let idx = t.line - 1
        // Only rewrite if it still looks like the same open box (avoid clobbering
        // if the file changed under us).
        guard let r = lines[idx].range(of: "[ ]") else { return }
        HistoryStore.snapshot(root: vault.rootURL, file: t.url, content: original)
        lines[idx].replaceSubrange(r, with: "[x]")
        let updated = lines.joined(separator: "\n")
        try? updated.write(to: t.url, atomically: true, encoding: .utf8)
        // Reload any open tab on this file, then rebuild the index (RootView).
        onChanged(t.url)
    }
}


/// Vault-wide search & replace: plain or regex, per-match preview with
/// highlighted context, per-file selection, HistoryStore snapshot before every
/// write so anything is restorable from 版本歷史.
struct SearchReplaceView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var index: IndexService
    let onOpen: (URL) -> Void
    let onReplaced: ([URL]) -> Void
    let onClose: () -> Void

    struct Match: Identifiable {
        let id = UUID()
        let url: URL
        let ordinal: Int   // index of this match within its file (for precise replace)
        let line: Int
        let prefix: String
        let hit: String
        let suffix: String
        var included = true
    }

    @State private var query = ""
    @State private var replacement = ""
    @State private var useRegex = false
    @State private var caseSensitive = false
    @State private var matches: [Match] = []
    @State private var status = ""
    @State private var searched = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(LZ("搜尋整個資料夾…"), text: $query)
                        .textFieldStyle(.plain).font(.title3).onSubmit(runSearch)
                    Toggle(".*", isOn: $useRegex).toggleStyle(.button).help("正則表達式")
                    Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button).help("區分大小寫")
                    Button(LZ("搜尋"), action: runSearch).keyboardShortcut(.return)
                }
                HStack {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                    TextField(LZ("取代為…（regex 可用 $1）"), text: $replacement)
                        .textFieldStyle(.plain)
                }
            }
            .padding(12)
            Divider()
            if matches.isEmpty {
                VStack { Spacer()
                    Text(searched ? LZ("沒有符合的結果") : LZ("輸入關鍵字，按 Enter 搜尋。"))
                        .foregroundStyle(.secondary)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List($matches) { $m in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $m.included).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.url.lastPathComponent):\(m.line)")
                                .font(.caption2).foregroundStyle(.secondary)
                            (Text(m.prefix) + Text(m.hit).bold().foregroundColor(.orange) + Text(m.suffix))
                                .font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        }
                        Spacer()
                        Button { onOpen(m.url) } label: { Image(systemName: "arrow.up.right") }
                            .buttonStyle(.borderless).help("開啟檔案")
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Text(status.isEmpty ? "\(matches.count) \(LZ("個符合")) · \(LZ("取代前會自動存版本快照"))" : status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(LZ("取代勾選的")) { replaceSelected() }
                    .disabled(matches.allSatisfy { !$0.included } || query.isEmpty)
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 720, height: 540)
    }

    private func makeRegex() -> NSRegularExpression? {
        let pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        var opts: NSRegularExpression.Options = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    private func runSearch() {
        matches = []; status = ""; searched = true
        guard !query.isEmpty, let re = makeRegex() else {
            status = LZ("正則表達式無效"); return
        }
        var out: [Match] = []
        for entry in index.entries where entry.ext == "md" || entry.ext == "tex" {
            let ns = entry.content as NSString
            for (ordinal, m) in re.matches(in: entry.content, range: NSRange(location: 0, length: ns.length)).enumerated() {
                let lineStart = ns.substring(to: m.range.location).components(separatedBy: "\n")
                let line = lineStart.count
                let ctxFrom = max(0, m.range.location - 40)
                let ctxTo = min(ns.length, m.range.location + m.range.length + 40)
                out.append(Match(
                    url: entry.url,
                    ordinal: ordinal,
                    line: line,
                    prefix: ns.substring(with: NSRange(location: ctxFrom, length: m.range.location - ctxFrom))
                        .replacingOccurrences(of: "\n", with: " "),
                    hit: ns.substring(with: m.range),
                    suffix: ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                                       length: ctxTo - m.range.location - m.range.length))
                        .replacingOccurrences(of: "\n", with: " ")
                ))
                if out.count >= 500 { break }
            }
            if out.count >= 500 { status = LZ("結果太多，只顯示前 500 筆"); break }
        }
        matches = out
    }

    private func replaceSelected() {
        guard let re = makeRegex() else { return }
        // Group included matches by file; replace ONLY the checked ones, working
        // from the end of the file backwards so earlier ranges stay valid.
        let byFile = Dictionary(grouping: matches.filter(\.included), by: \.url)
        var changed: [URL] = []
        let template = useRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        for (url, ms) in byFile {
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Snapshot BEFORE the change so 版本歷史 can restore it.
            HistoryStore.snapshot(root: vault.rootURL, file: url, content: original)
            let included = Set(ms.map(\.ordinal))
            let all = re.matches(in: original, range: NSRange(location: 0, length: (original as NSString).length))
            var result = original
            for (i, m) in all.enumerated().reversed() where included.contains(i) {
                let rep = re.replacementString(for: m, in: original, offset: 0, template: template)
                result = (result as NSString).replacingCharacters(in: m.range, with: rep)
            }
            if result != original {
                try? result.write(to: url, atomically: true, encoding: .utf8)
                changed.append(url)
            }
        }
        status = "\(LZ("已取代")) \(byFile.count) \(LZ("個檔案"))（\(LZ("可從版本歷史還原")))"
        onReplaced(changed)
        runSearch()   // refresh the list against the new contents
    }
}
