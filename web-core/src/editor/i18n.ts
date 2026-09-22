/**
 * i18n.ts — tiny UI-string localization for the web editor. The native shell
 * pushes the language via `window.notepro.setLang`. Strings are written in their
 * Chinese form (the key); `t()` returns English when the language is English.
 */
let english = false;

export function setLang(lang: string): void {
  english = lang === "en";
}

export function t(zh: string): string {
  return english ? (EN[zh] ?? zh) : zh;
}

const EN: Record<string, string> = {
  // AI overlay
  "AI 協助 — ⌘K": "AI Assist — ⌘K",
  "AI 生成（游標處插入）— ⌘K": "AI Generate (at cursor) — ⌘K",
  "或輸入自訂指示，按 Enter…": "Or type a custom instruction, then Enter…",
  "要生成什麼？按 Enter…": "What should I generate? Press Enter…",
  "套用 Apply": "Apply",
  "插入 Insert": "Insert",
  "取消 Cancel": "Cancel",
  "思考中… (模型運算中)": "Thinking… (model running)",
  "AI 未提出變更。": "AI proposed no changes.",
  "檢視修改（綠＝新增、紅＝刪除）：": "Review changes (green = added, red = removed):",
  "AI 沒有產生內容。": "AI produced no content.",
  "預覽（將插入游標處）：": "Preview (inserts at the cursor):",
  "失敗：": "Failed: ",
  "（請確認 Ollama 正在執行）": " (make sure Ollama is running)",
  // Cite popup
  "插入引用 — 搜尋 Zotero (⌘⇧K)": "Insert Citation — Search Zotero (⌘⇧K)",
  "輸入作者 / 標題 / 關鍵字…": "Type author / title / keyword…",
  "搜尋中…": "Searching…",
  "筆結果": "results",
  "插圖": "Figure",
  "從這篇論文挑一張圖插入": "Pick a figure from this paper",
  "編譯失敗（檢查語法或缺少套件）": "compile failed (check syntax / missing package)",
  // Chat panel
  "切換帳號": "Switch account",
  "可改筆記": "Can edit notes", "唯讀": "Read-only", "Claude 能做的事": "What it may do",
  "新對話": "New chat", "模型": "Model", "預設": "Default",
  "＋ 目前筆記": "＋ Current note", "＋ 選取內容": "＋ Selection",
  "問問題、請它改筆記…（Enter 送出，Shift+Enter 換行）": "Ask anything, or have it edit your notes… (Enter to send, Shift+Enter for a new line)",
  "送出": "Send", "停止": "Stop",
  "在「": "In “", "」裡對話 — 可以問問題、整理筆記、改寫段落。": "” — ask questions, tidy notes, rewrite passages.",
  "預設會附上目前開啟的筆記。": "The note you have open is attached by default.",
  "你的 vault": "your vault",
  "＋ 新增 Claude 帳號": "＋ Add Claude account", "＋ 新增 ChatGPT 帳號": "＋ Add ChatGPT account",
  "（需先安裝 Codex CLI）": " (install the Codex CLI first)",
  "↻ 重新整理登入狀態": "↻ Refresh sign-in status",
  "每個帳號是獨立的登入；切換帳號會開始新對話。": "Each account is a separate sign-in; switching starts a new chat.",
  "登入": "Sign in", "移除": "Remove", "未登入": "Not signed in", "登入已過期": "Sign-in expired",
  "⚠︎ 登入已過期 — 點上方帳號名稱 → 登入": "⚠︎ Sign-in expired — click the account above → Sign in",
  "⚠︎ 這個帳號尚未登入 — 點上方帳號名稱 → 登入": "⚠︎ This account is not signed in — click the account above → Sign in",
  "已套用": "applied", "已還原": "reverted", "失敗": "failed", "進行中…": "running…",
  "修改": "edit", "寫入": "write", "開啟": "Open", "還原": "Revert",
  "新 Claude 帳號的名稱（例如：研究室 Max）": "Name for the new Claude account (e.g. Lab Max)",
  "新 ChatGPT 帳號的名稱": "Name for the new ChatGPT account",
  "找不到結果": "No results",
  // Slash menu
  "/ 標題 H1": "/ Heading 1",
  "/ 標題 H2": "/ Heading 2",
  "/ 標題 H3": "/ Heading 3",
  "/ 清單": "/ Bullet list",
  "/ 待辦": "/ To-do",
  "/ 編號清單": "/ Numbered list",
  "/ 引用": "/ Quote",
  "/ 提示框 Callout": "/ Callout",
  "/ 程式碼": "/ Code block",
  "/ 數學公式": "/ Math block",
  "/ 圖表": "/ Chart",
  "/ TikZ 圖": "/ TikZ figure",
  "/ 表格": "/ Table",
  "/ 分隔線": "/ Divider",
  // Preview
  "LaTeX 原始檔 — 用「匯出 PDF」直接編譯。": "LaTeX source — compile directly with “Export PDF”.",
};
