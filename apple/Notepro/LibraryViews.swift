import SwiftUI
import AppKit
import UniformTypeIdentifiers



/// Literature library — every literature note in the vault (frontmatter
/// `type: literature-note`, i.e. PDF annotations + arXiv/ADS imports) in one
/// searchable, sortable list with read/unread tracking.
struct LiteratureLibraryView: View {
    @EnvironmentObject var index: IndexService
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var sortBy = "year"
    @AppStorage("litReadPaths") private var readPathsData = Data()

    private var readPaths: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: readPathsData)) ?? []
    }
    private func setRead(_ url: URL, _ read: Bool) {
        var s = readPaths
        if read { s.insert(url.path) } else { s.remove(url.path) }
        readPathsData = (try? JSONEncoder().encode(s)) ?? Data()
    }

    private var items: [IndexEntry] {
        var list = index.entries.filter { $0.properties["type"] == "literature-note" }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q)
                || ($0.properties["authors"] ?? "").lowercased().contains(q)
                || ($0.properties["cite"] ?? "").lowercased().contains(q)
                || $0.content.lowercased().contains(q)
            }
        }
        switch sortBy {
        case "author": return list.sorted { ($0.properties["authors"] ?? "") < ($1.properties["authors"] ?? "") }
        case "title": return list.sorted { $0.title < $1.title }
        default: return list.sorted { ($0.properties["year"] ?? "") > ($1.properties["year"] ?? "") }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical").foregroundStyle(.secondary)
                TextField(LZ("搜尋標題 / 作者 / citekey…"), text: $query)
                    .textFieldStyle(.plain).font(.title3)
                Picker("", selection: $sortBy) {
                    Text(LZ("年份")).tag("year")
                    Text(LZ("作者")).tag("author")
                    Text(LZ("標題")).tag("title")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(LZ("還沒有文獻筆記")).foregroundStyle(.secondary)
                    Text(LZ("用「找文獻 arXiv/ADS」匯入，或在 PDF 閱讀器按「建立文獻筆記」。"))
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { e in row(e) }.listStyle(.plain)
            }
            Divider()
            HStack {
                Text("\(items.count) \(LZ("篇"))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 680, height: 520)
    }

    private func row(_ e: IndexEntry) -> some View {
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
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button { onOpen(e.url) } label: { Image(systemName: "doc.text") }
                    .buttonStyle(.borderless).help("開啟筆記")
                if let cite = e.properties["cite"], !cite.isEmpty {
                    Button { EditorModel.openInZotero(citekey: cite) } label: { Image(systemName: "books.vertical.circle") }
                        .buttonStyle(.borderless).help("在 Zotero 開啟")
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
