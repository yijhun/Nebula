import SwiftUI
import AppKit

/// Lightweight in-app localization. UI strings are written in the source as
/// their Traditional-Chinese form (the key); `LZ()` returns the English text
/// when the app language is English. Switching language writes the preference
/// and relaunches so every surface (incl. the menu bar) picks it up.
///
/// `appLanguage`: "system" | "zh" | "en".
func currentlyEnglish() -> Bool {
    switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
    case "en": return true
    case "zh": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("en") ?? false
    }
}

/// Localize a UI string written in its Chinese key form.
func LZ(_ zh: String) -> String {
    currentlyEnglish() ? (EN[zh] ?? zh) : zh
}

/// Apply a chosen language and relaunch the app so it takes effect everywhere.
func applyLanguageAndRelaunch(_ lang: String) {
    UserDefaults.standard.set(lang, forKey: "appLanguage")
    let url = Bundle.main.bundleURL
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", url.path]
    try? task.run()
    NSApp.terminate(nil)
}

/// Chinese-key → English translations for the app chrome.
let EN: [String: String] = [
    // File menu
    "新文件 New Note": "New Note",
    "新資料夾 New Folder": "New Folder",
    "今天的筆記 Daily Note": "Daily Note",
    "新專案 New Project": "New Project",
    "從範本新增 New from Template": "New from Template",
    "開啟資料夾… Open Vault": "Open Vault…",
    "開啟 Obsidian Vault": "Open Obsidian Vault",
    "未偵測到 Obsidian vault": "No Obsidian vault found",
    "儲存 Save": "Save",
    "轉 / 切換 LaTeX ⇄ Markdown": "Convert / Toggle LaTeX ⇄ Markdown",
    "匯出 PDF… Export PDF": "Export PDF…",
    "匯出 LaTeX… Export .tex": "Export .tex…",
    "AI 協助… AI Assist": "AI Assist…",
    "AI 修復 LaTeX": "AI Fix LaTeX", "AI 修復": "AI Fix",
    "插入 Insert": "Insert",
    "插入引用（Zotero）": "Insert Citation (Zotero)",
    "在 Zotero 開啟此引用": "Open Citation in Zotero",
    "在文件內尋找 Find": "Find in Document",
    "屬性 Properties": "Properties", "新增屬性…": "Add property…",
    "快捷鍵 Shortcuts": "Shortcuts", "字": "words", "編譯中": "Compiling",
    "錄演講 / 轉文字": "Record / Transcribe", "找文獻 arXiv/ADS": "Find Papers (arXiv/ADS)",
    "即時 PDF 預覽 Live PDF preview": "Live PDF preview",
    "下一個分頁 Next Tab": "Next Tab", "上一個分頁 Prev Tab": "Previous Tab",
    "分頁 1": "Tab 1", "分頁 2": "Tab 2", "分頁 3": "Tab 3",
    "分頁 4": "Tab 4", "分頁 5": "Tab 5", "分頁 6": "Tab 6",
    "分頁 7": "Tab 7", "分頁 8": "Tab 8", "分頁 9": "Tab 9",
    "與 Claude 共筆": "Cowork with Claude", "範圍": "Scope", "選取": "Selection", "本章節": "This section", "整篇": "Whole note",
    "改寫得更清楚精煉": "Polish for clarity", "審稿/找邏輯漏洞": "Peer review",
    "解釋這個推導/方程式": "Explain this derivation", "摘要(中文)": "Summarize (Chinese)",
    "翻成英文(學術)": "Translate to academic English", "從這段擴寫成段落大綱": "Expand into paragraph outline",
    "自訂(下面自己寫)": "Custom (write below)", "自訂指令": "Custom instruction",
    "附加說明(可空)": "Additional notes (optional)", "字元": "chars",
    "只複製到剪貼簿": "Copy only", "複製 + 開 claude.ai": "Copy + Open claude.ai",
    "已複製到剪貼簿": "Copied to clipboard", "已複製 — 到 claude.ai 按 ⌘V 貼上": "Copied — paste with ⌘V at claude.ai",
    "Whisper 模型": "Whisper model", "自動偵測": "Auto-detect", "選擇…": "Choose…", "清除": "Clear",
    "語意搜尋 / 問你的筆記…": "Semantic Search / Ask Your Notes…",
    "檢視 View": "View",
    "編輯模式": "Edit", "並排模式": "Split", "預覽模式": "Preview",
    "分割視窗 Split": "Split Pane", "新分頁 New Tab": "New Tab",
    "資料庫檢視 Database": "Database View", "關係圖譜 Graph": "Graph",
    // Settings
    "一般": "General", "外觀": "Appearance", "引用": "Citations",
    "AI": "AI", "片段": "Snippets", "Zotero": "Zotero", "AI 助手": "AI Assistant",
    "語言 Language": "Language", "跟隨系統 System": "System",
    "外觀 Appearance": "Appearance", "淺色 Light": "Light", "深色 Dark": "Dark",
    "Vim 模式（無鼠標編輯）": "Vim mode (keyboard-only editing)",
    "預設 LaTeX 模板": "Default LaTeX template",
    "字體 Font family": "Font family",
    "LaTeX 引用巨集": "LaTeX cite command", "預覽引用顯示": "Preview citation style",
    "作者-年 (Chen et al. 2017)": "Author-year (Chen et al. 2017)", "原始 citekey": "Raw citekey",
    "Ollama 模型": "Ollama model", "套用": "Apply",
    "啟用 Zotero 自動引用與 .bib": "Enable Zotero auto-citation & .bib",
    "自動存檔": "Auto-save",
    "編譯前先檢查語法": "Check syntax before compiling",
    "附件預設位置": "Attachment location", "附件資料夾名稱": "Attachment folder name",
    "指定資料夾": "Specified folder", "同筆記資料夾": "Same folder as note", "Vault 根目錄": "Vault root",
    "版本歷史 History": "Version History",
    "還原最近的乾淨 Markdown 版本": "Restore Latest Clean Markdown",
    "尚無版本紀錄（存檔後會自動建立）": "No revisions yet (created automatically on save)",
    "還原此版本": "Restore this version",
    "差異": "Diff", "內容": "Content",
    "綠＝新增": "Green = added", "紅＝刪除": "Red = removed",
    "（與目前版本比較）": "(compared to current)",
    // Sidebar sections
    "置頂 Pinned": "Pinned", "智慧分類 Smart": "Smart", "類別 Category": "Category",
    "標籤 Tags": "Tags", "Zotero 文獻": "Zotero Library",
    "大綱 Outline": "Outline", "相關筆記 Related": "Related Notes",
    "最近修改 Recent": "Recent",
    "搜尋 Zotero…": "Search Zotero…",
    "尚未開啟資料夾": "No vault open", "開啟資料夾…": "Open Vault…",
    // File ops / context menus
    "新文件": "New Note", "新資料夾": "New Folder", "以資料庫開啟": "Open as Database",
    "排序方式": "Sort by", "名稱": "Name", "修改日期": "Date Modified", "類型": "Type",
    "重新命名…": "Rename…", "顏色 Color": "Color", "無": "None",
    "在 Finder 顯示": "Reveal in Finder", "刪除": "Delete", "複製": "Duplicate", "開啟": "Open",
    "在右側並排開啟": "Open in Split (right)", "在新分頁開啟": "Open in New Tab",
    "在新視窗開啟": "Open in New Window", "筆記 Note": "Note",
    "即時預覽彈出視窗": "Pop out live preview", "預覽 Preview": "Preview",
    // ⋯ menu sections + new tools
    "研究": "Research", "視窗": "Window",
    "文獻庫": "Literature Library", "搜尋與取代（跨檔案）": "Search & Replace (all files)",
    "投稿前檢查": "Pre-submission Check",
    // Table menu
    "圖表 Chart": "Chart", "互動圖表編輯器": "Interactive Chart Studio",
    "圖解編輯器（幾何示意圖）": "Diagram Studio (geometry)", "3D 圖編輯器": "3D Figure Editor",
    "這篇引用了哪些（references）": "Its references", "哪些論文引用這篇（citations）": "Cited by",
    "轉成 TikZ（插在下方）": "Convert to TikZ (insert below)",
    "表格 Table": "Table", "格式化表格": "Format Table",
    "下方插入列": "Insert Row Below", "右方插入欄": "Insert Column Right",
    "刪除目前列": "Delete Row", "刪除目前欄": "Delete Column", "切換欄對齊": "Cycle Column Alignment",
    // Literature library
    "搜尋標題 / 作者 / citekey…": "Search title / author / citekey…",
    "年份": "Year", "作者": "Author", "標題": "Title", "篇": "papers",
    "還沒有文獻筆記": "No literature notes yet",
    "用「找文獻 arXiv/ADS」匯入，或在 PDF 閱讀器按「建立文獻筆記」。": "Import via Find Papers (arXiv/ADS), or create one from the PDF reader.",
    // Search & replace
    "搜尋整個資料夾…": "Search the whole vault…",
    "取代為…（regex 可用 $1）": "Replace with… ($1 works in regex mode)",
    "沒有符合的結果": "No matches", "個符合": "matches",
    "取代前會自動存版本快照": "A history snapshot is saved before replacing",
    "取代勾選的": "Replace Checked", "已取代": "Replaced", "個檔案": "files",
    "可從版本歷史還原": "restorable from Version History",
    "結果太多，只顯示前 500 筆": "Too many results — showing the first 500",
    "正則表達式無效": "Invalid regular expression",
    "輸入關鍵字，按 Enter 搜尋。": "Type a query and press Enter.",
    // Toolbar tooltips / labels
    "快速開啟": "Quick Open", "搜尋": "Search", "問筆記": "Ask Notes", "讀 PDF": "Read PDF", "檢查": "Check",
    "轉 LaTeX": "To LaTeX", "回 Markdown": "Back to Markdown", "匯出 PDF": "Export PDF",
    "分割": "Split", "新視窗": "New Window", "新分頁": "New Tab",
    // Sheets
    "關閉": "Close", "重置": "Reset", "重建索引": "Rebuild Index",
    "語意搜尋": "Semantic Search", "問你的筆記": "Ask Your Notes",
    "表格": "Table", "看板": "Board", "分組": "Group by", "資料庫": "Database",
    // PDF reader
    "螢光標記": "Highlight", "存標註": "Save Annotations", "建立文獻筆記": "Create Literature Note",
    "論文 Paper": "Paper",
    // View modes (editor toolbar picker)
    "編輯": "Edit", "即時": "Live", "並排": "Split", "預覽": "Preview",
    // Smart-section group labels (counts are appended at runtime)
    "草稿 (.md)": "Drafts (.md)", "正式稿 (.tex)": "Formal (.tex)",
    // Common
    "就緒 Ready": "Ready", "未命名": "Untitled", "新文件 Untitled": "Untitled",
]
