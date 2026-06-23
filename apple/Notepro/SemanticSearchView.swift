import SwiftUI

/// "Search by meaning" + "ask your notes" (RAG) over the whole vault, powered by
/// the local SemanticIndex (nomic-embed) and the local LLM for answers.
struct SemanticSearchView: View {
    @EnvironmentObject var sem: SemanticIndex
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var vault: VaultModel
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    enum Mode: Hashable { case search, ask }
    @State private var mode: Mode = .search
    @State private var query = ""
    @State private var hits: [SemHit] = []
    @State private var answer = ""
    @State private var sources: [SemHit] = []
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .background(.regularMaterial)
        .onAppear {
            focused = true
            if !sem.ready && !sem.isIndexing { Task { await sem.build(index, vault: vault) } }
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text(LZ("語意搜尋")).tag(Mode.search)
                Text(LZ("問你的筆記")).tag(Mode.ask)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 8) {
                Image(systemName: mode == .ask ? "sparkles" : "brain")
                    .foregroundStyle(.secondary)
                TextField(mode == .ask ? "問一個問題，AI 會根據你的筆記回答…" : "用意思搜尋（不必關鍵字一致）…",
                          text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit(run)
                if busy || sem.isIndexing { ProgressView().controlSize(.small) }
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if sem.isIndexing {
            statusBox("建立語意索引中…\n\(sem.status)", showProgress: true)
        } else if !sem.ready {
            statusBox("尚未建立語意索引。\n\(sem.status)")
        } else if mode == .search {
            searchResults
        } else {
            askResults
        }
    }

    private var searchResults: some View {
        Group {
            if hits.isEmpty {
                statusBox(query.isEmpty ? "輸入內容，按 Enter 用語意搜尋。" : "沒有相關片段。")
            } else {
                List(hits) { h in
                    Button { onOpen(h.url) } label: { hitRow(h, showScore: true) }
                        .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var askResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if answer.isEmpty {
                    statusBox("問一個問題，AI 會根據你的筆記回答並標註來源。")
                } else {
                    Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !sources.isEmpty {
                        Divider()
                        Text("來源").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(sources.enumerated()), id: \.element.id) { (i, h) in
                            Button { onOpen(h.url) } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("【\(i + 1)】").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    hitRow(h, showScore: false)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func hitRow(_ h: SemHit, showScore: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(h.name).font(.callout)
                if !h.heading.isEmpty {
                    Text("› \(h.heading)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if showScore {
                    Text(String(format: "%.2f", h.score)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Text(h.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Text(sem.ready ? "已索引 \(sem.chunkCount) 段" : sem.status)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await sem.build(index, vault: vault, force: true); hits = []; answer = "" } } label: {
                Label("重建索引", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(sem.isIndexing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func statusBox(_ text: String, showProgress: Bool = false) -> some View {
        VStack(spacing: 10) {
            Spacer()
            if showProgress { ProgressView(value: sem.progress) .frame(width: 200) }
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, sem.ready, !busy else { return }
        busy = true
        Task {
            if mode == .search {
                hits = await sem.search(q)
            } else {
                let r = await sem.ask(q)
                answer = r.answer; sources = r.sources
            }
            busy = false
        }
    }
}
