import SwiftUI

/// Identifies the folder a database view is opened for (whole vault when nil).
struct DBTarget: Identifiable {
    let id = UUID()
    let folder: URL?
    let title: String
}

/// Notion-style database over the notes in a folder: a Table view (frontmatter
/// properties as columns) and a Board view (Kanban grouped by a property).
/// The plain `.md` files stay the source of truth — this is a view over them.
struct DatabaseView: View {
    @EnvironmentObject var index: IndexService
    let target: DBTarget
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case table = "表格", board = "看板"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .table
    @State private var groupBy: String = ""

    private var rows: [IndexEntry] {
        let all = index.entries.filter { $0.ext == "md" || $0.ext == "markdown" }
        guard let folder = target.folder else { return all.sorted { $0.name < $1.name } }
        let p = folder.path
        return all
            .filter { $0.url.path.hasPrefix(p + "/") }
            .sorted { $0.name < $1.name }
    }

    private var propertyKeys: [String] {
        var keys = Set<String>()
        for r in rows { keys.formUnion(r.properties.keys) }
        return keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                empty
            } else if mode == .table {
                tableView
            } else {
                boardView
            }
        }
        .frame(width: 820, height: 560)
        .onAppear { if groupBy.isEmpty { groupBy = propertyKeys.first ?? "" } }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tablecells").foregroundStyle(.secondary)
            Text(target.title).font(.headline)
            Text("\(rows.count) 筆").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            if mode == .board && !propertyKeys.isEmpty {
                Picker("分組", selection: $groupBy) {
                    ForEach(propertyKeys, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 160)
            }
            Button(LZ("關閉"), action: onClose)
        }
        .padding(10)
    }

    private var empty: some View {
        VStack { Spacer(); Text("這個資料夾沒有筆記").foregroundStyle(.secondary); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Table

    private let colWidth: CGFloat = 130

    private var tableView: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    cell("標題", width: 200, bold: true)
                    ForEach(propertyKeys, id: \.self) { cell($0, width: colWidth, bold: true) }
                }
                .background(Color.secondary.opacity(0.12))
                Divider()
                ForEach(rows) { r in
                    Button { onOpen(r.url) } label: {
                        HStack(spacing: 0) {
                            cell(r.title, width: 200)
                            ForEach(propertyKeys, id: \.self) { k in
                                cell(r.properties[k] ?? "", width: colWidth, dim: r.properties[k] == nil)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func cell(_ text: String, width: CGFloat, bold: Bool = false, dim: Bool = false) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.caption)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(dim || text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 5).padding(.horizontal, 8)
    }

    // MARK: Board

    private var groups: [(key: String, items: [IndexEntry])] {
        let g = Dictionary(grouping: rows) { $0.properties[groupBy] ?? "（無）" }
        return g.sorted { $0.key < $1.key }.map { (key: $0.key, items: $0.value) }
    }

    private var boardView: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(groups, id: \.key) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.key).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(group.items.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(group.items) { r in
                            Button { onOpen(r.url) } label: { card(r) }.buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 200)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
        }
    }

    private func card(_ r: IndexEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.title).font(.caption.weight(.medium)).lineLimit(2)
            ForEach(propertyKeys.filter { $0 != groupBy }.prefix(2), id: \.self) { k in
                if let v = r.properties[k] {
                    Text("\(k): \(v)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
