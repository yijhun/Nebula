import Foundation
import AppKit

/// Opens a Terminal window running Claude Code in the vault, with a vault
/// CLAUDE.md so the agent knows the note conventions. The vault is plain
/// files, so Claude Code needs no API glue — and the FSWatcher live-reloads
/// any note it edits into the open editors.
enum ClaudeCodeLauncher {

    /// Whether the `claude` CLI is installed (PATH + the usual install spots).
    static var claudePath: String? {
        let candidates = [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Launch Terminal at the vault root running `claude` (writing CLAUDE.md
    /// first if the vault doesn't have one). Returns a user-facing error, or nil.
    @discardableResult
    static func open(vault root: URL?) -> String? {
        guard let root else { return "請先開啟資料夾" }
        guard let claude = claudePath else {
            return "找不到 claude CLI（安裝：npm install -g @anthropic-ai/claude-code）"
        }
        ensureClaudeMD(vault: root)
        // A .command file opens in the user's default terminal app — no
        // AppleScript / Accessibility permission needed.
        let script = """
        #!/bin/zsh
        cd \(shellQuote(root.path))
        exec \(shellQuote(claude))
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cmd = dir.appendingPathComponent("claude-vault.command")
        do {
            try script.write(to: cmd, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmd.path)
        } catch { return "無法建立啟動檔：\(error.localizedDescription)" }
        NSWorkspace.shared.open(cmd)
        return nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Write a CLAUDE.md documenting the vault's conventions (only if absent —
    /// the user's own version always wins).
    static func ensureClaudeMD(vault root: URL) {
        let url = root.appendingPathComponent("CLAUDE.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let md = """
        # 這個 vault（Nebula 筆記庫）

        這是 Nebula（macOS 筆記 app，Obsidian 相容）的 vault。編輯這裡的 .md 檔時請遵守：

        ## 格式慣例
        - 筆記是 Markdown + YAML frontmatter。`type:` 分類筆記：
          - `type: literature` — 文獻筆記（欄位：title/authors/year/journal/cite/doi/arxiv/url/zotero/pdf/status/topics）
          - `type: meeting` — 會議筆記（欄位：date/kind/speaker/event/title；章節：`## 重點` `## 待辦` `## 逐字稿`）
        - 引用寫 `[@citekey]`（Pandoc 格式），citekey 對應 vault 根的 `references.bib` 或 Zotero。
        - 雙鏈用 `[[筆記名]]`，圖片嵌入用 `![[圖.png]]`（附件在 Assets/ 或 Images/）。
        - 數學：行內 `$…$`、區塊 `$$…$$`。
        - 特殊程式碼區塊：```chart（數據圖，會轉 TikZ）、```tikz（原生 TikZ）、```calc（會計算的算式）。
        - 待辦是標準 `- [ ]` checkbox。

        ## 請不要動
        - `.notepro/`（版本快照）、`references.bib` 只可追加不可重排、`PDFs/` 內的論文檔。

        ## 常見任務
        - 幫忙改寫/擴寫章節、整理會議筆記的重點、從逐字稿抽待辦、檢查 LaTeX 語法。
        - 修改筆記直接編輯檔案即可 — Nebula 開著的編輯器會自動重新載入。
        """
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }
}
