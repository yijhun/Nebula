import SwiftUI
import AppKit

extension Notification.Name {
    static let noteproThemeChanged = Notification.Name("NoteproThemeChanged")
    static let noteproVimChanged = Notification.Name("NoteproVimChanged")
    static let noteproConfigChanged = Notification.Name("NoteproConfigChanged")
    static let noteproNoteList = Notification.Name("NoteproNoteList")
    static let noteproRequestNoteList = Notification.Name("NoteproRequestNoteList")
    static let noteproOpenWikilink = Notification.Name("NoteproOpenWikilink")
    static let noteproOpenDatabase = Notification.Name("NoteproOpenDatabase")
    static let noteproOpenGraph = Notification.Name("NoteproOpenGraph")
    static let noteproOpenHistory = Notification.Name("NoteproOpenHistory")
    static let noteproOpenPalette = Notification.Name("NoteproOpenPalette")
    static let noteproOpenSemantic = Notification.Name("NoteproOpenSemantic")
    static let noteproOpenProject = Notification.Name("NoteproOpenProject")   // userInfo["folder"]: URL
    static let noteproNewProject = Notification.Name("NoteproNewProject")
    static let noteproOpenShortcuts = Notification.Name("NoteproOpenShortcuts")
    static let noteproOpenTranscribe = Notification.Name("NoteproOpenTranscribe")
    static let noteproOpenLiterature = Notification.Name("NoteproOpenLiterature")
    static let noteproOpenCowork = Notification.Name("NoteproOpenCowork")
    static let noteproOpenInSplit = Notification.Name("NoteproOpenInSplit")   // userInfo["url"]: URL
    static let noteproOpenInNewTab = Notification.Name("NoteproOpenInNewTab") // userInfo["url"]: URL
    static let noteproOpenInWindow = Notification.Name("NoteproOpenInWindow") // userInfo["url"]: URL
    static let noteproMirrorContent = Notification.Name("NoteproMirrorContent") // userInfo["url": URL, "text": String]
}

/// Default editable AI presets ("label | instruction" per line).
let defaultAIPresetsText = """
潤飾 | 潤飾下面的文字，使其更通順自然，保持原意與原本的語言。
文法 | 修正下面文字的文法與錯字，只更正錯誤，不要改寫風格。
精簡 | 將下面文字精簡，去除冗詞贅句，保留所有要點。
改寫 | 改寫下面文字，使其更清楚、更專業。
翻譯→英文 | 將下面文字翻譯成自然流暢的英文。
"""

/// Settings window (⌘,). All values are @AppStorage; changes post notifications
/// that EditorModel observes to re-apply to every open editor.
struct SettingsView: View {
    @AppStorage("theme") private var theme = "system"
    @AppStorage("vimMode") private var vimMode = false
    @AppStorage("defaultTemplate") private var defaultTemplate = "apj"
    @AppStorage("aiModel") private var aiModel = "qwen3:8b"
    @AppStorage("zoteroEnabled") private var zoteroEnabled = true
    // Configurable (pushed to the web core)
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("lineHeight") private var lineHeight = 1.6
    @AppStorage("fontFamily") private var fontFamily = "ui-monospace, \"SF Mono\", Menlo, monospace"
    @AppStorage("citeLatexCommand") private var citeLatexCommand = "autocite"
    @AppStorage("previewCiteStyle") private var previewCiteStyle = "author-year"
    @AppStorage("aiPresetsText") private var aiPresetsText = defaultAIPresetsText
    @AppStorage("snippetsText") private var snippetsText = ""
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("checkBeforeCompile") private var checkBeforeCompile = true
    @AppStorage("whisperModel") private var whisperModel = ""
    @AppStorage("adsToken") private var adsToken = ""
    @AppStorage("zoteroUserID") private var zoteroUserID = ""
    @AppStorage("zoteroAPIKey") private var zoteroAPIKey = ""
    // Dropped-image (attachment) location: "folder" (<vault>/<name>), "note"
    // (same folder as the note), or "root" (vault root).
    @AppStorage("attachmentMode") private var attachmentMode = "folder"
    @AppStorage("attachmentFolder") private var attachmentFolder = "Assets"

    @State private var assistantText = ""
    @State private var assistantBusy = false
    @State private var assistantStatus = ""

    private func notifyConfig() { NotificationCenter.default.post(name: .noteproConfigChanged, object: nil) }

    private func pickWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        if panel.runModal() == .OK, let url = panel.url { whisperModel = url.path }
    }

    private func notifyAll() {
        NotificationCenter.default.post(name: .noteproThemeChanged, object: nil)
        NotificationCenter.default.post(name: .noteproVimChanged, object: nil)
        NotificationCenter.default.post(name: .noteproConfigChanged, object: nil)
    }

    private static func extractJSON(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }

    private func runAssistant() {
        let req = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty else { return }
        assistantBusy = true; assistantStatus = "思考中…"
        let prompt = """
        你是 Nebula 的設定助手。依使用者需求輸出一個 JSON 物件，只包含需要「變更」的鍵，值需在允許範圍內。只輸出 JSON，不要解釋或 markdown 圍欄。
        可用鍵：
        theme: "system"|"light"|"dark"
        vimMode: true|false
        fontSize: 10~24 整數
        lineHeight: 1.2~2.4
        fontFamily: 字串
        citeLatexCommand: "autocite"|"cite"|"citep"|"citet"|"parencite"|"textcite"
        previewCiteStyle: "author-year"|"citekey"
        aiModel: 字串
        zoteroEnabled: true|false
        defaultTemplate: "article"|"academic"
        addAIPreset: {"label":字串,"instruction":字串}

        使用者需求：\(req)
        """
        AIProvider.shared.complete(prompt: prompt) { result in
            assistantBusy = false
            switch result {
            case .failure(let e):
                assistantStatus = "失敗：\(e.localizedDescription)"
            case .success(let text):
                guard let json = Self.extractJSON(text), let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    assistantStatus = "無法解析 AI 回應"; return
                }
                let changed = applyAssistant(obj)
                assistantStatus = changed.isEmpty ? "沒有可套用的設定" : "已套用：" + changed.joined(separator: "、")
            }
        }
    }

    private func applyAssistant(_ obj: [String: Any]) -> [String] {
        var changed: [String] = []
        if let v = obj["theme"] as? String, ["system", "light", "dark"].contains(v) { theme = v; changed.append("外觀") }
        if let v = obj["vimMode"] as? Bool { vimMode = v; changed.append("Vim") }
        if let n = obj["fontSize"] as? NSNumber { fontSize = min(24, max(10, n.doubleValue)); changed.append("字級") }
        if let n = obj["lineHeight"] as? NSNumber { lineHeight = min(2.4, max(1.2, n.doubleValue)); changed.append("行距") }
        if let v = obj["fontFamily"] as? String, !v.isEmpty { fontFamily = v; changed.append("字體") }
        if let v = obj["citeLatexCommand"] as? String { citeLatexCommand = v; changed.append("引用巨集") }
        if let v = obj["previewCiteStyle"] as? String { previewCiteStyle = v; changed.append("引用顯示") }
        if let v = obj["aiModel"] as? String, !v.isEmpty { aiModel = v; changed.append("AI 模型") }
        if let v = obj["zoteroEnabled"] as? Bool { zoteroEnabled = v; changed.append("Zotero") }
        if let v = obj["defaultTemplate"] as? String { defaultTemplate = v; changed.append("模板") }
        if let p = obj["addAIPreset"] as? [String: Any],
           let l = p["label"] as? String, let ins = p["instruction"] as? String, !l.isEmpty {
            aiPresetsText += "\n\(l) | \(ins)"; changed.append("AI 預設")
        }
        if !changed.isEmpty { notifyAll() }
        return changed
    }

    var body: some View {
        TabView {
            Form {
                Picker(LZ("語言 Language"), selection: $appLanguage) {
                    Text(LZ("跟隨系統 System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .onChange(of: appLanguage) { _, new in applyLanguageAndRelaunch(new) }
                Picker(LZ("外觀 Appearance"), selection: $theme) {
                    Text(LZ("跟隨系統 System")).tag("system")
                    Text(LZ("淺色 Light")).tag("light")
                    Text(LZ("深色 Dark")).tag("dark")
                }
                .onChange(of: theme) { _, _ in NotificationCenter.default.post(name: .noteproThemeChanged, object: nil) }
                Toggle(LZ("Vim 模式（無鼠標編輯）"), isOn: $vimMode)
                    .onChange(of: vimMode) { _, _ in NotificationCenter.default.post(name: .noteproVimChanged, object: nil) }
                Toggle(LZ("自動存檔"), isOn: $autoSave)
                Toggle(LZ("編譯前先檢查語法"), isOn: $checkBeforeCompile)
                HStack {
                    Text(LZ("Whisper 模型"))
                    Spacer()
                    Text(whisperModel.isEmpty ? LZ("自動偵測") : (whisperModel as NSString).lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button(LZ("選擇…")) { pickWhisperModel() }
                    if !whisperModel.isEmpty { Button(LZ("清除")) { whisperModel = "" } }
                }
                Picker(LZ("預設 LaTeX 模板"), selection: $defaultTemplate) {
                    Text("ApJ (AASTeX)").tag("apj")
                    Text("Academic (A4)").tag("academic")
                    Text("Article").tag("article")
                }
                .onChange(of: defaultTemplate) { _, _ in notifyConfig() }

                Picker(LZ("附件預設位置"), selection: $attachmentMode) {
                    Text(LZ("指定資料夾")).tag("folder")
                    Text(LZ("同筆記資料夾")).tag("note")
                    Text(LZ("Vault 根目錄")).tag("root")
                }
                if attachmentMode == "folder" {
                    TextField(LZ("附件資料夾名稱"), text: $attachmentFolder)
                }
            }
            .padding().tabItem { Label(LZ("一般"), systemImage: "gearshape") }

            Form {
                Slider(value: $fontSize, in: 10...24, step: 1) { Text("字級 \(Int(fontSize))") }
                    .onChange(of: fontSize) { _, _ in notifyConfig() }
                Slider(value: $lineHeight, in: 1.2...2.4, step: 0.1) { Text("行距 \(String(format: "%.1f", lineHeight))") }
                    .onChange(of: lineHeight) { _, _ in notifyConfig() }
                TextField("字體 Font family", text: $fontFamily)
                    .onSubmit(notifyConfig)
            }
            .padding().tabItem { Label(LZ("外觀"), systemImage: "textformat.size") }

            Form {
                Picker("LaTeX 引用巨集", selection: $citeLatexCommand) {
                    ForEach(["autocite", "cite", "citep", "citet", "parencite", "textcite"], id: \.self) { Text("\\\($0)").tag($0) }
                }
                .onChange(of: citeLatexCommand) { _, _ in notifyConfig() }
                Picker("預覽引用顯示", selection: $previewCiteStyle) {
                    Text("作者-年 (Chen et al. 2017)").tag("author-year")
                    Text("原始 citekey").tag("citekey")
                }
                .onChange(of: previewCiteStyle) { _, _ in notifyConfig() }
                Divider()
                SecureField("NASA ADS API token", text: $adsToken)
                Text("用於「找文獻 ▸ NASA ADS」。免費申請：ui.adsabs.harvard.edu ▸ Account ▸ API Token。arXiv 不需 token。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding().tabItem { Label(LZ("引用"), systemImage: "quote.opening") }

            Form {
                TextField("Ollama 模型", text: $aiModel)
                Text("每行一個 AI 指令：「標籤 | 提示內容」").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $aiPresetsText)
                    .font(.system(size: 12, design: .monospaced)).frame(minHeight: 110)
                    .onChange(of: aiPresetsText) { _, _ in notifyConfig() }
            }
            .padding().tabItem { Label(LZ("AI"), systemImage: "sparkles") }

            SnippetsEditor(text: $snippetsText, onChange: notifyConfig)
                .padding().tabItem { Label(LZ("片段"), systemImage: "text.cursor") }

            Form {
                Toggle("啟用 Zotero 自動引用與 .bib", isOn: $zoteroEnabled)
                Text("優先用本機 Better BibTeX（需 Zotero 開著）。下面填了 Web API 後，Zotero 沒開時會自動改用雲端。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Zotero Web API（離線後備）").font(.caption).bold()
                TextField("使用者 ID（數字）", text: $zoteroUserID)
                SecureField("API Key", text: $zoteroAPIKey)
                Text("申請：zotero.org/settings/keys（建新 key，勾「Allow library access」）。User ID 在同一頁。填了之後 Zotero 不用開也能搜尋/產生 .bib。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding().tabItem { Label(LZ("Zotero"), systemImage: "books.vertical") }

            VStack(alignment: .leading, spacing: 10) {
                Text("用自然語言描述你想要的設定，AI 會幫你套用。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("例：「我想要深色主題、大一點的字、開啟 Vim、引用用 citep」")
                    .font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $assistantText)
                    .font(.system(size: 13)).frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Button(action: runAssistant) {
                        Label("套用", systemImage: "wand.and.stars")
                    }
                    .disabled(assistantBusy || assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if assistantBusy { ProgressView().controlSize(.small) }
                    Text(assistantStatus).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding().tabItem { Label(LZ("AI 助手"), systemImage: "wand.and.stars") }
        }
        .frame(width: 680, height: 460)
    }
}

/// Snippet management UI — a list editor for LaTeX completion snippets.
/// Persists to the same `snippetsText` blob ("trigger | template" lines, with
/// `\n` for literal newlines) the web core already consumes, so it's fully
/// backward-compatible with the old plain-text field.
struct SnippetsEditor: View {
    @Binding var text: String
    let onChange: () -> Void

    struct Snip: Identifiable, Equatable {
        let id = UUID()
        var trigger: String
        var template: String   // real newlines here; serialized with \n
    }

    @State private var snips: [Snip] = []
    @State private var selection: Snip.ID?
    @FocusState private var templateFocused: Bool

    /// Starter snippets a user can drop in. Templates use real newlines.
    private static let starters: [(String, String, String)] = [
        ("圖片 figure", "\\fig",
         "\\begin{figure}\n\t\\centering\n\t\\includegraphics[width=\\linewidth]{${}}\n\t\\caption{${}}\n\t\\label{fig:${}}\n\\end{figure}"),
        ("雙欄圖 figure*", "\\figs",
         "\\begin{figure*}\n\t\\centering\n\t\\includegraphics[width=\\textwidth]{${}}\n\t\\caption{${}}\n\t\\label{fig:${}}\n\\end{figure*}"),
        ("表格 table", "\\tab",
         "\\begin{table}\n\t\\centering\n\t\\caption{${}}\n\t\\label{tab:${}}\n\t\\begin{tabular}{${cc}}\n\t\t\\hline\n\t\t${} \\\\\n\t\t\\hline\n\t\\end{tabular}\n\\end{table}"),
        ("方程式 equation", "\\eq",
         "\\begin{equation}\n\t${}\n\t\\label{eq:${}}\n\\end{equation}"),
        ("對齊 align", "\\al",
         "\\begin{align}\n\t${}\n\\end{align}"),
        ("觀測參數", "\\obs",
         "$v_{\\rm LSR} = ${} \\mathrm{km\\,s^{-1}}$, $d = ${} \\mathrm{kpc}$"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自訂 LaTeX 補全片段。打觸發字按 Tab 展開；`${}` 是游標停留點，多個會用 Tab 依序跳。")
                .font(.caption).foregroundStyle(.secondary)

            HSplitView {
                // ── master list ──
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(snips) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.trigger.isEmpty ? "（未命名）" : s.trigger)
                                    .font(.system(size: 12, design: .monospaced)).bold()
                                Text(s.template.replacingOccurrences(of: "\n", with: " ").prefix(40))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(s.id)
                        }
                        .onDelete { idx in snips.remove(atOffsets: idx); commit() }
                        .onMove { from, to in snips.move(fromOffsets: from, toOffset: to); commit() }
                    }
                    .frame(minHeight: 150)
                    HStack {
                        Button { addBlank() } label: { Image(systemName: "plus") }
                        Button { if let id = selection, let i = snips.firstIndex(where: { $0.id == id }) { snips.remove(at: i); commit() } }
                            label: { Image(systemName: "minus") }
                            .disabled(selection == nil)
                        Spacer()
                        Menu {
                            ForEach(Self.starters, id: \.1) { name, trig, tmpl in
                                Button(name) { add(trigger: trig, template: tmpl) }
                            }
                        } label: { Label("常用範本", systemImage: "sparkles") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    .buttonStyle(.borderless).padding(6)
                }
                .frame(minWidth: 180)

                // ── detail editor ──
                if let id = selection, let idx = snips.firstIndex(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("觸發字").font(.caption).foregroundStyle(.secondary)
                        TextField("\\mysnippet", text: Binding(
                            get: { snips[idx].trigger },
                            set: { snips[idx].trigger = $0; commit() }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        HStack {
                            Text("展開內容").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("插入 ${ }") { insertTabStop(idx) }
                                .font(.caption2).buttonStyle(.borderless)
                        }
                        TextEditor(text: Binding(
                            get: { snips[idx].template },
                            set: { snips[idx].template = $0; commit() }))
                            .font(.system(size: 12, design: .monospaced))
                            .focused($templateFocused)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                    .padding(8)
                    .frame(minWidth: 240)
                } else {
                    VStack { Spacer()
                        Text("選一個片段來編輯，或按 + 新增").foregroundStyle(.secondary).font(.caption)
                        Spacer() }
                        .frame(minWidth: 240, maxHeight: .infinity)
                }
            }
        }
        .onAppear { parse() }
    }

    // MARK: serialization (round-trips through the existing snippetsText format)

    private func parse() {
        snips = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { return nil }
            let trig = parts[0].trimmingCharacters(in: .whitespaces)
            let tmpl = parts[1...].joined(separator: "|").trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
            return trig.isEmpty ? nil : Snip(trigger: trig, template: tmpl)
        }
    }

    private func commit() {
        text = snips.map { s in
            let tmpl = s.template.replacingOccurrences(of: "\n", with: "\\n")
            return "\(s.trigger) | \(tmpl)"
        }.joined(separator: "\n")
        onChange()
    }

    private func addBlank() { add(trigger: "\\", template: "") }
    private func add(trigger: String, template: String) {
        let s = Snip(trigger: trigger, template: template)
        snips.append(s); selection = s.id; commit()
    }
    private func insertTabStop(_ idx: Int) {
        snips[idx].template += "${}"; commit()
    }
}
