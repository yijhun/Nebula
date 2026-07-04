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
