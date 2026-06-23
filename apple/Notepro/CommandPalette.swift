import SwiftUI

/// Quick-open (fuzzy filename) and full-text search palette, à la Obsidian's
/// quick switcher / search. Presented as a sheet from RootView.
struct CommandPalette: View {
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var vault: VaultModel
    let mode: EditorModel.PaletteMode
    var initialQuery: String = ""
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var seeded = false
    @FocusState private var focused: Bool

    private var fileResults: [IndexEntry] { mode == .files ? index.quickOpen(query) : [] }
    private var contentResults: [SearchHit] { mode == .content ? index.search(query) : [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .files ? "doc.text.magnifyingglass" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(mode == .files ? "快速開啟檔案…" : "搜尋內容…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(openFirst)
            }
            .padding(12)
            Divider()

            if mode == .files {
                fileList
            } else {
                contentList
            }
        }
        .frame(width: 580, height: 440)
        .background(.regularMaterial)
        .onAppear {
            index.buildIfNeeded(vault)
            if !seeded { query = initialQuery; seeded = true }
            focused = true
        }
        .onExitCommand(perform: onClose) // Esc
    }

    private var fileList: some View {
        let results = fileResults
        return Group {
            if results.isEmpty {
                empty("找不到檔案")
            } else {
                List(results) { e in
                    Button { onOpen(e.url) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: e.url.pathExtension.lowercased() == "tex" ? "doc.plaintext" : "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name)
                                if !e.folder.isEmpty {
                                    Text(e.folder).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var contentList: some View {
        let hits = contentResults
        return Group {
            if query.count < 2 {
                empty("輸入至少兩個字搜尋內容")
            } else if hits.isEmpty {
                empty("沒有符合的內容")
            } else {
                List(hits) { hit in
                    Button { onOpen(hit.url) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.url.lastPathComponent).font(.callout)
                            Text("行 \(hit.line)：\(hit.snippet)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private func openFirst() {
        if mode == .files { if let f = fileResults.first { onOpen(f.url) } }
        else { if let h = contentResults.first { onOpen(h.url) } }
    }
}
