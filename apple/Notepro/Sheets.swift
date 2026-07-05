import SwiftUI
import AppKit
import UniformTypeIdentifiers



/// Keyboard-shortcut cheat sheet (⌘/). A simple grouped reference.
struct ShortcutsView: View {
    let onClose: () -> Void

    private let groups: [(String, [(String, String)])] = [
        ("檔案 File", [
            ("⌘N", "新文件 New note"), ("⇧⌘N", "新資料夾 New folder"),
            ("⌥⌘T", "今天的筆記 Daily note"), ("⇧⌘P", "新專案 New project"),
            ("⇧⌘O", "開啟資料夾 Open vault"), ("⌘S", "儲存 Save"),
        ]),
        ("搜尋 Search", [
            ("⌘O", "快速開啟 Quick open"), ("⇧⌘F", "全文搜尋 Search content"),
            ("⌘F", "文件內尋找 Find in document"), ("⌥⌘F", "語意搜尋 / 問筆記 Ask notes"),
            ("⋯ ▸ 搜尋與取代", "跨檔案取代（regex 可用）"),
        ]),
        ("檢視 View", [
            ("⌘1 / ⌘2 / ⌘3", "編輯 / 並排 / 預覽"), ("⌘\\", "分割視窗 Split"),
            ("⌘T", "新分頁 New tab"), ("⌥⌘N", "新視窗 New window"),
            ("⇧⌘] / ⇧⌘[", "下一個 / 上一個分頁"), ("⌃1…⌃9", "跳到第 N 個分頁"),
            ("⇧⌘D", "資料庫 Database"), ("⇧⌘G", "關係圖譜 Graph"),
        ]),
        ("LaTeX / 寫作", [
            ("⌥⌘L", "轉 / 切換 LaTeX ⇄ Markdown"), ("⌘E", "匯出 PDF Export PDF"),
            ("⇧⌘L", "匯出 .tex"), ("⇧⌘H", "版本歷史 History"),
            ("插入 ▸ 表格", "表格：插列 / 插欄 / 對齊 / 格式化"),
        ]),
        ("AI / 引用", [
            ("⌘K", "AI 協助 / 續寫"), ("⌥⌘K", "AI 修復 LaTeX"),
            ("⌘⇧K", "插入引用 Zotero"), ("⌥⇧⌘K", "在 Zotero 開啟游標引用"),
        ]),
        ("預覽 Preview", [
            ("雙擊預覽段落", "跳到原始行"), ("⤢（預覽右上）", "拖出 / 彈出即時預覽"),
            ("雙擊 PDF 預覽", "SyncTeX 跳回編輯器該行"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                Text(LZ("快捷鍵 Shortcuts")).font(.headline)
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.0).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.1, id: \.0) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.0)
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                        .frame(width: 96, alignment: .leading)
                                    Text(row.1).font(.caption)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 440)
        .onExitCommand(perform: onClose)
    }
}


/// Record a talk (or import an audio file) → local Whisper transcription →
/// optional local-AI summary → saved as a note. Fully offline.
struct TranscribeView: View {
    @EnvironmentObject var vault: VaultModel
    @StateObject private var rec = MeetingRecorder()
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    private func writeNote(_ title: String, _ content: String) -> URL? {
        vault.newFile(baseName: title, ext: "md", content: content)
    }
    private func timeStr(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text(LZ("錄演講 / 轉文字")).font(.headline)
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }

            if !TranscriptionService.isAvailable {
                Label("找不到 whisper-cli 或模型。請 `brew install whisper-cpp` 並在設定指定模型路徑。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            switch rec.phase {
            case .idle:
                VStack(spacing: 12) {
                    Toggle("用本地 AI 整理摘要", isOn: $rec.summarize)
                    Toggle("逐字稿含時間戳", isOn: $rec.timestamps)
                    HStack(spacing: 16) {
                        Button {
                            rec.startRecording()
                        } label: {
                            Label("開始錄音", systemImage: "record.circle").font(.title3)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(!TranscriptionService.isAvailable)

                        Button { importAudio() } label: {
                            Label("匯入音檔…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!TranscriptionService.isAvailable)
                    }
                }
            case .recording:
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(.red)
                    Text(timeStr(rec.elapsed)).font(.system(.title, design: .monospaced))
                    Button {
                        rec.stopAndProcess(write: writeNote, open: onOpen)
                    } label: {
                        Label("停止並轉錄", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .transcribing:
                VStack(spacing: 8) {
                    ProgressView(value: rec.transcribeProgress).frame(width: 240)
                    Text("轉錄中… \(Int(rec.transcribeProgress * 100))%（本地 Whisper）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .summarizing:
                VStack(spacing: 8) {
                    if rec.summaryTotal > 1 { ProgressView(value: Double(rec.summaryStep), total: Double(rec.summaryTotal)).frame(width: 240) }
                    else { ProgressView().controlSize(.large) }
                    Text(rec.summaryTotal > 1 ? "本地 AI 整理摘要中… (\(rec.summaryStep)/\(rec.summaryTotal))" : "本地 AI 整理摘要中…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .error(let msg):
                VStack(spacing: 10) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("回到開始") { rec.phase = .idle }
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 440, height: 320)
        .onExitCommand(perform: onClose)
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        panel.prompt = "轉錄"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rec.processFile(url, write: writeNote, open: onOpen)
    }
}


/// Search arXiv / NASA ADS → import a paper as a BibTeX entry (appended to the
/// vault's references.bib) + a literature note, and insert its citation.
struct LiteratureSearchView: View {
    @EnvironmentObject var vault: VaultModel
    @EnvironmentObject var editor: EditorModel
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var source = "arxiv"
    @State private var query = ""
    @State private var results: [Paper] = []
    @State private var busy = false
    @State private var status = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $source) {
                    Text("arXiv").tag("arxiv")
                    Text("NASA ADS").tag("ads")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋論文（標題 / 作者 / 關鍵字）…", text: $query)
                        .textFieldStyle(.plain).font(.title3).focused($focused).onSubmit(run)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                VStack { Spacer()
                    Text(busy ? "搜尋中…" : "輸入關鍵字，按 Enter 搜尋。").foregroundStyle(.secondary)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { p in row(p) }.listStyle(.plain)
            }
            Divider()
            HStack {
                Text(status.isEmpty ? (vault.rootURL == nil ? "請先開啟資料夾" : "匯入會寫進 \(vault.rootURL?.lastPathComponent ?? "")/references.bib + 建文獻筆記") : status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(LZ("關閉"), action: onClose)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 680, height: 540)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
    }

    private func row(_ p: Paper) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.title).font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text(p.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !p.year.isEmpty { Text("· \(p.year)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { importPaper(p) } label: { Label("匯入並引用", systemImage: "square.and.arrow.down") }
                    .controlSize(.small).disabled(vault.rootURL == nil)
            }
            if !p.abstract.isEmpty {
                Text(p.abstract).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true; status = ""
        if source == "arxiv" {
            LiteratureSearch.arxiv(q) { r in results = r; busy = false; if r.isEmpty { status = "沒有結果" } }
        } else {
            LiteratureSearch.ads(q) { result in
                busy = false
                switch result {
                case .success(let r): results = r; if r.isEmpty { status = "沒有結果" }
                case .failure(let e): status = "⚠ \(e.localizedDescription)"
                }
            }
        }
    }

    private func importPaper(_ p: Paper) {
        guard vault.rootURL != nil else { status = "請先開啟資料夾"; return }
        if p.source == "ADS" {
            LiteratureSearch.adsBibtex(p.identifier) { bib in
                finish(p, bibtex: bib ?? LiteratureSearch.arxivBibtex(p, key: LiteratureSearch.citekey(for: p)))
            }
        } else {
            finish(p, bibtex: LiteratureSearch.arxivBibtex(p, key: LiteratureSearch.citekey(for: p)))
        }
    }

    private func finish(_ p: Paper, bibtex: String) {
        guard let root = vault.rootURL else { return }
        let key = bibKey(bibtex) ?? LiteratureSearch.citekey(for: p)
        // 1. Append to <vault>/references.bib (dedup by key).
        let bibURL = root.appendingPathComponent("references.bib")
        let existing = (try? String(contentsOf: bibURL, encoding: .utf8)) ?? ""
        if !existing.contains("{\(key),") && !existing.contains("{\(key) ,") {
            let merged = existing.isEmpty ? bibtex : existing + "\n" + bibtex
            try? merged.write(to: bibURL, atomically: true, encoding: .utf8)
        }
        // 2. Literature note.
        let body = """
        ---
        type: literature-note
        title: \(p.title)
        authors: \(p.authorLine)
        year: \(p.year)
        cite: \(key)
        source: \(p.source)
        url: \(p.url)
        doi: \(p.doi)
        ---

        # \(p.title)

        \(p.authorLine) (\(p.year)) · [\(p.source)](\(p.url)) · `[@\(key)]`

        ## 摘要

        \(p.abstract)

        ## 筆記


        """
        let safeTitle = String(p.title.prefix(50)).replacingOccurrences(of: "/", with: "-")
        let url = vault.newFile(baseName: "文獻 - \(safeTitle)", ext: "md", content: body)
        // 3. Insert the citation into the active editor.
        editor.insertCitation(key)
        status = "已匯入 [@\(key)] — references.bib + 文獻筆記"
        if let url { onOpen(url) }
    }

    private func bibKey(_ bib: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"@\w+\s*\{\s*([^,\s]+)"#) else { return nil }
        let ns = bib as NSString
        guard let m = re.firstMatch(in: bib, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}


/// Cowork with Claude — pick a scope (selection / heading-bounded section /
/// whole note), a preset task, write/edit the prompt, then "Copy & Open
/// claude.ai". Goes via the user's claude.ai subscription — no API key.
struct CoworkView: View {
    @EnvironmentObject var editor: EditorModel
    let onClose: () -> Void
    @State private var scope = "selection"
    @State private var preset = "improve"
    @State private var instruction = ""
    @State private var payload = ""
    @State private var status = ""

    private struct Preset { let id, label, prompt: String }
    private let presets: [Preset] = [
        .init(id: "improve",  label: "改寫得更清楚精煉",
              prompt: "請把下面這段學術寫作改得更清楚精煉(保留術語、數學、引用),用條列點出主要修改原因。\n\n"),
        .init(id: "review",   label: "審稿/找邏輯漏洞",
              prompt: "請以期刊審稿人角度評論下面這段,找邏輯漏洞、過度推論、缺少證據之處,並列改進建議。\n\n"),
        .init(id: "explain",  label: "解釋這個推導/方程式",
              prompt: "請詳細解釋下面這段 LaTeX 公式或推導:每一步在做什麼、用了什麼假設、結果的物理意義。\n\n"),
        .init(id: "summary",  label: "摘要(中文)",
              prompt: "請用 3~5 句中文摘要下面這段,保留關鍵數字與結論。\n\n"),
        .init(id: "translate",label: "翻成英文(學術)",
              prompt: "請把下面這段翻成適合天文期刊的英文(自然、簡練、保留術語):\n\n"),
        .init(id: "outline",  label: "從這段擴寫成段落大綱",
              prompt: "請把下面這個粗胚擴寫成一段論文段落的大綱(每點一句、保留邏輯順序):\n\n"),
        .init(id: "freeform", label: "自訂(下面自己寫)", prompt: ""),
    ]

    private var fullPrompt: String {
        let head = preset == "freeform"
            ? instruction
            : (presets.first { $0.id == preset }?.prompt ?? "") + instruction
        return head + "---\n" + payload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LZ("與 Claude 共筆")).font(.headline)
                Spacer()
                Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
            }

            HStack(spacing: 16) {
                Picker(LZ("範圍"), selection: $scope) {
                    Text(LZ("選取")).tag("selection")
                    Text(LZ("本章節")).tag("section")
                    Text(LZ("整篇")).tag("full")
                }.pickerStyle(.segmented).labelsHidden().onChange(of: scope) { _, _ in refresh() }

                Picker("", selection: $preset) {
                    ForEach(presets, id: \.id) { p in Text(LZ(p.label)).tag(p.id) }
                }.labelsHidden().frame(width: 240)
            }

            if preset == "freeform" {
                Text(LZ("自訂指令")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $instruction).frame(minHeight: 60)
                    .font(.system(size: 13)).border(Color.secondary.opacity(0.3))
            } else {
                Text(LZ("附加說明(可空)")).font(.caption).foregroundStyle(.secondary)
                TextField("", text: $instruction).textFieldStyle(.roundedBorder)
            }

            Text(LZ("內容") + "  ·  \(payload.count) " + LZ("字元"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(payload.isEmpty ? "(空 — 換個範圍或先選取文字)" : payload)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.gray.opacity(0.08))
            .frame(maxHeight: 200)

            HStack {
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button(LZ("只複製到剪貼簿")) { copyOnly() }
                Button(LZ("複製 + 開 claude.ai")) { copyAndOpen() }
                    .keyboardShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(payload.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 620, height: 540)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        editor.getCoworkPayload(scope: scope) { p in payload = p }
    }
    private func copyOnly() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPrompt, forType: .string)
        status = LZ("已複製到剪貼簿")
    }
    private func copyAndOpen() {
        copyOnly()
        if let url = URL(string: "https://claude.ai/new") { NSWorkspace.shared.open(url) }
        status = LZ("已複製 — 到 claude.ai 按 ⌘V 貼上")
    }
}
