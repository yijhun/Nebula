import SwiftUI

/// Notepro — macOS shell (Spike B+).
/// SwiftUI + WKWebView. The web core owns editing + live preview +
/// Markdown→LaTeX; the native side owns the vault (file explorer), windows,
/// file I/O, and PDF export (Tectonic). The vault is shared across windows.
@main
struct NoteproApp: App {
    @StateObject private var vault = VaultModel()
    @StateObject private var index = IndexService()
    @StateObject private var semIndex = SemanticIndex()
    @StateObject private var projects = ProjectsModel()
    @FocusedValue(\.editorModel) private var focusedEditor
    @FocusedValue(\.tabsModel) private var focusedTabs

    var body: some Scene {
        // `for: UUID.self` — on current macOS a value-less WindowGroup's
        // openWindow(id:) only re-focuses the existing window; giving each
        // window a unique value makes openWindow(value: UUID()) spawn a real
        // new one. The launch window binds a nil value (ignored).
        WindowGroup(id: "main", for: UUID.self) { _ in
            RootView()
                .environmentObject(vault)
                .environmentObject(index)
                .environmentObject(semIndex)
                .environmentObject(projects)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { vault.restoreLastVault() }   // re-open your Obsidian vault
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(LZ("新文件 New Note")) {
                    if let u = vault.newNote(in: vault.rootURL) { focusedEditor?.open(u) }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(vault.rootURL == nil)

                Button(LZ("新資料夾 New Folder")) { vault.createFolder(in: vault.rootURL) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(vault.rootURL == nil)

                Button(LZ("今天的筆記 Daily Note")) {
                    if let u = vault.todayNote() { focusedEditor?.open(u) }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(vault.rootURL == nil || focusedEditor == nil)

                Button(LZ("新專案 New Project")) {
                    NotificationCenter.default.post(name: .noteproNewProject, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(vault.rootURL == nil)

                Menu(LZ("從範本新增 New from Template")) {
                    ForEach(EditorPane.templates, id: \.id) { t in
                        Button(t.label) { focusedEditor?.newFromTemplate(t.id, vault: vault) }
                    }
                }
                .disabled(focusedEditor == nil)

                Divider()

                Button(LZ("開啟資料夾… Open Vault")) { vault.openVault() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Menu(LZ("開啟 Obsidian Vault")) {
                    let vaults = VaultModel.obsidianVaults()
                    if vaults.isEmpty {
                        Button(LZ("未偵測到 Obsidian vault")) {}.disabled(true)
                    } else {
                        ForEach(vaults, id: \.self) { v in
                            Button(v.lastPathComponent) { vault.setVault(v) }
                        }
                    }
                }
            }
            CommandGroup(after: .saveItem) {
                Button(LZ("儲存 Save")) { focusedEditor?.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(focusedEditor == nil)
                Divider()
                Button(LZ("轉 / 切換 LaTeX ⇄ Markdown")) { if let e = focusedEditor { e.toggleMdLatex(vault: vault) } }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(focusedEditor == nil)
                Button(LZ("匯出 PDF… Export PDF")) { focusedEditor?.exportPDF() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(focusedEditor == nil)
                Button(LZ("匯出 LaTeX… Export .tex")) { focusedEditor?.exportLaTeX() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(focusedEditor == nil)
                Divider()
                Button(LZ("版本歷史 History")) {
                    NotificationCenter.default.post(name: .noteproOpenHistory, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(focusedEditor == nil)
                Button(LZ("還原最近的乾淨 Markdown 版本")) { focusedEditor?.restoreLatestCleanMarkdown() }
                    .disabled(focusedEditor == nil)
            }
            CommandGroup(after: .textEditing) {
                Button(LZ("AI 協助… AI Assist")) { focusedEditor?.triggerAI() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(focusedEditor == nil)
                Button(LZ("AI 修復 LaTeX")) { focusedEditor?.aiFixLatex() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(focusedEditor == nil)
            }
            CommandMenu(Text(LZ("插入 Insert"))) {
                Button(LZ("插入引用（Zotero）")) { focusedEditor?.triggerCite() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(focusedEditor == nil)
                Button(LZ("在 Zotero 開啟此引用")) { focusedEditor?.openCiteAtCursorInZotero() }
                    .keyboardShortcut("k", modifiers: [.command, .option, .shift])
                    .disabled(focusedEditor == nil)
                Divider()
                Menu(LZ("圖表 Chart")) {
                    Button(LZ("互動圖表編輯器")) { focusedEditor?.chartStudio() }
                    Button(LZ("圖解編輯器（幾何示意圖）")) { focusedEditor?.diagramStudio() }
                    Button(LZ("轉成 TikZ（插在下方）")) { focusedEditor?.chartToTikz() }
                }
                .disabled(focusedEditor == nil)
                Menu(LZ("表格 Table")) {
                    Button(LZ("格式化表格")) { focusedEditor?.tableOp("format") }
                    Divider()
                    Button(LZ("下方插入列")) { focusedEditor?.tableOp("insertRowBelow") }
                    Button(LZ("右方插入欄")) { focusedEditor?.tableOp("insertColRight") }
                    Divider()
                    Button(LZ("刪除目前列")) { focusedEditor?.tableOp("deleteRow") }
                    Button(LZ("刪除目前欄")) { focusedEditor?.tableOp("deleteCol") }
                    Divider()
                    Button(LZ("切換欄對齊")) { focusedEditor?.tableOp("cycleAlign") }
                }
                .disabled(focusedEditor == nil)
            }
            CommandGroup(replacing: .help) {
                Button(LZ("快捷鍵 Shortcuts")) {
                    NotificationCenter.default.post(name: .noteproOpenShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button(LZ("在文件內尋找 Find")) { focusedEditor?.find() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(focusedEditor == nil)
                Button(LZ("語意搜尋 / 問你的筆記…")) { focusedEditor?.triggerSemantic() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(focusedEditor == nil)
            }
            CommandMenu(Text(LZ("檢視 View"))) {
                Button(LZ("編輯模式")) { focusedEditor?.viewMode = .edit }
                    .keyboardShortcut("1", modifiers: .command).disabled(focusedEditor == nil)
                Button(LZ("並排模式")) { focusedEditor?.viewMode = .split }
                    .keyboardShortcut("2", modifiers: .command).disabled(focusedEditor == nil)
                Button(LZ("預覽模式")) { focusedEditor?.viewMode = .preview }
                    .keyboardShortcut("3", modifiers: .command).disabled(focusedEditor == nil)
                Divider()
                Button(LZ("分割視窗 Split")) { focusedTabs?.splitOn.toggle() }
                    .keyboardShortcut("\\", modifiers: .command).disabled(focusedTabs == nil)
                Button(LZ("新分頁 New Tab")) { focusedTabs?.newTab() }
                    .keyboardShortcut("t", modifiers: .command).disabled(focusedTabs == nil)
                Button(LZ("下一個分頁 Next Tab")) { focusedTabs?.nextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(focusedTabs == nil)
                Button(LZ("上一個分頁 Prev Tab")) { focusedTabs?.prevTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(focusedTabs == nil)
                // ⌃1 .. ⌃9 — jump to the N-th tab. Command-1/2/3 are already
                // claimed by edit/split/preview view modes, so we use Control.
                // ForEach inside CommandMenu doesn't register keyboard shortcuts
                // on macOS — each Button has to be declared explicitly.
                Button(LZ("分頁 1")) { focusedTabs?.activate(at: 1) }
                    .keyboardShortcut("1", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 2")) { focusedTabs?.activate(at: 2) }
                    .keyboardShortcut("2", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 3")) { focusedTabs?.activate(at: 3) }
                    .keyboardShortcut("3", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 4")) { focusedTabs?.activate(at: 4) }
                    .keyboardShortcut("4", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 5")) { focusedTabs?.activate(at: 5) }
                    .keyboardShortcut("5", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 6")) { focusedTabs?.activate(at: 6) }
                    .keyboardShortcut("6", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 7")) { focusedTabs?.activate(at: 7) }
                    .keyboardShortcut("7", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 8")) { focusedTabs?.activate(at: 8) }
                    .keyboardShortcut("8", modifiers: .control).disabled(focusedTabs == nil)
                Button(LZ("分頁 9")) { focusedTabs?.activate(at: 9) }
                    .keyboardShortcut("9", modifiers: .control).disabled(focusedTabs == nil)
                Divider()
                Button(LZ("資料庫檢視 Database")) {
                    NotificationCenter.default.post(
                        name: .noteproOpenDatabase, object: nil,
                        userInfo: vault.rootURL.map { ["folder": $0, "title": $0.lastPathComponent] }
                            ?? ["title": "資料庫"])
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(vault.rootURL == nil)
                Button(LZ("關係圖譜 Graph")) {
                    NotificationCenter.default.post(name: .noteproOpenGraph, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(vault.rootURL == nil)
            }
        }

        // Paper-reading windows (read + highlight a PDF → literature note).
        WindowGroup("論文 Paper", id: "pdf", for: URL.self) { $url in
            if let url {
                PDFReaderView(url: url)
                    .environmentObject(vault)
                    .frame(minWidth: 560, minHeight: 520)
            }
        }

        // Standalone single-note windows (right-click ▸ 在新視窗開啟).
        WindowGroup("筆記 Note", id: "note", for: URL.self) { $url in
            if let url {
                NoteWindowView(url: url)
                    .environmentObject(vault)
                    .environmentObject(index)
                    .environmentObject(semIndex)
                    .environmentObject(projects)
                    .frame(minWidth: 480, minHeight: 360)
            }
        }

        // Detached live HTML-preview windows (pop-out from split/preview).
        WindowGroup("預覽 Preview", id: "preview", for: URL.self) { $url in
            if let url {
                PreviewWindowView(url: url)
                    .environmentObject(vault)
                    .frame(minWidth: 420, minHeight: 320)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
