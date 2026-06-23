import SwiftUI

/// One line in a diff view.
struct DiffLine: Identifiable {
    enum Kind { case equal, insert, delete }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// LCS-based line diff (old → new). `delete` = only in old, `insert` = only in new.
func lineDiff(_ old: [String], _ new: [String]) -> [DiffLine] {
    let n = old.count, m = new.count
    if n > 4000 || m > 4000 {   // guard: huge files → just show new
        return new.map { DiffLine(kind: .equal, text: $0) }
    }
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
    }
    var out: [DiffLine] = []
    var i = 0, j = 0
    while i < n && j < m {
        if old[i] == new[j] { out.append(.init(kind: .equal, text: old[i])); i += 1; j += 1 }
        else if dp[i + 1][j] >= dp[i][j + 1] { out.append(.init(kind: .delete, text: old[i])); i += 1 }
        else { out.append(.init(kind: .insert, text: new[j])); j += 1 }
    }
    while i < n { out.append(.init(kind: .delete, text: old[i])); i += 1 }
    while j < m { out.append(.init(kind: .insert, text: new[j])); j += 1 }
    return out
}

/// Revision history for the current file: pick a snapshot and see — IDE-style —
/// what changed between it and the current document (green = added since,
/// red = removed since). Restore writes the snapshot back (undoable).
struct HistoryView: View {
    @EnvironmentObject var editor: EditorModel
    let onClose: () -> Void

    @State private var snaps: [HistoryStore.Snapshot] = []
    @State private var selected: HistoryStore.Snapshot?
    @State private var diff: [DiffLine] = []
    @State private var mode = 0   // 0 = diff, 1 = full content

    private var fmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text(LZ("版本歷史 History")).font(.headline)
                if let url = editor.currentURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }
            .padding(10)
            Divider()
            if snaps.isEmpty {
                VStack { Spacer(); Text(LZ("尚無版本紀錄（存檔後會自動建立）")).foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(snaps, selection: $selected) { s in
                        Text(fmt.string(from: s.date)).font(.callout.monospacedDigit()).tag(s)
                    }
                    .frame(width: 190)
                    rightPane
                }
            }
        }
        .frame(width: 760, height: 500)
        .onAppear {
            if let url = editor.currentURL {
                snaps = HistoryStore.list(root: editor.vaultRoot, for: url)
                selected = snaps.first
                recompute()
            }
        }
        .onChange(of: selected) { _, _ in recompute() }
        .onExitCommand(perform: onClose)
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    Text(LZ("差異")).tag(0)
                    Text(LZ("內容")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                if mode == 0 {
                    Label(LZ("綠＝新增"), systemImage: "plus").font(.caption2).foregroundStyle(.green)
                    Label(LZ("紅＝刪除"), systemImage: "minus").font(.caption2).foregroundStyle(.red)
                    Text(LZ("（與目前版本比較）")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            Divider()
            ScrollView {
                if mode == 1 {
                    Text(selected.map { HistoryStore.content($0) } ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(10)
                } else {
                    diffView
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(LZ("還原此版本")) {
                    if let s = selected { editor.restoreSnapshot(s); onClose() }
                }
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(8)
        }
    }

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(sign(line.kind)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 12)
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(bg(line.kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private func sign(_ k: DiffLine.Kind) -> String {
        switch k { case .insert: return "+"; case .delete: return "−"; case .equal: return "" }
    }
    private func bg(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .insert: return .green.opacity(0.16)
        case .delete: return .red.opacity(0.16)
        case .equal: return .clear
        }
    }

    private func recompute() {
        guard let sel = selected, let url = editor.currentURL else { diff = []; return }
        let old = HistoryStore.content(sel).components(separatedBy: "\n")
        let new = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        diff = lineDiff(old, new)
    }
}
