/**
 * cite.ts — Zotero citation picker (⌘⇧K).
 *
 * Searches the local Zotero library (via the native bridge → Better BibTeX),
 * and inserts the chosen item's citekey at the cursor (format decided by the
 * caller: `[@key]` for Markdown, `\autocite{key}` for LaTeX).
 */
import { call } from "./bridge.js";
import { t } from "./i18n.js";

interface ZoteroItem { citekey: string; title: string; authors: string; year: string; }

let overlay: HTMLElement | null = null;
let searchTimer: number | undefined;

export function closeCite(): void {
  overlay?.remove();
  overlay = null;
}

export function openCite(onInsert: (citekey: string) => void): void {
  closeCite();

  const panel = document.createElement("div");
  panel.className = "np-cite";
  panel.style.cssText =
    "position:fixed;top:60px;left:50%;transform:translateX(-50%);width:min(680px,92vw);" +
    "background:#21252b;color:#e6e6e6;border:1px solid #3a3f4b;border-radius:10px;" +
    "box-shadow:0 12px 40px rgba(0,0,0,.5);z-index:9998;padding:14px;font-family:-apple-system,sans-serif";

  const title = document.createElement("div");
  title.textContent = t("插入引用 — 搜尋 Zotero (⌘⇧K)");
  title.style.cssText = "font-weight:600;font-size:13px;margin-bottom:10px;opacity:.8";
  panel.appendChild(title);

  const input = document.createElement("input");
  input.type = "text";
  input.placeholder = t("輸入作者 / 標題 / 關鍵字…");
  input.style.cssText =
    "width:100%;box-sizing:border-box;background:#1b1e24;color:#e6e6e6;border:1px solid #3a3f4b;" +
    "border-radius:6px;padding:8px 10px;font-size:13px";
  panel.appendChild(input);

  const status = document.createElement("div");
  status.style.cssText = "font-size:12px;opacity:.7;margin-top:8px;min-height:16px";
  panel.appendChild(status);

  const list = document.createElement("div");
  list.style.cssText = "margin-top:8px;max-height:320px;overflow:auto";
  panel.appendChild(list);

  let results: ZoteroItem[] = [];

  function insert(item: ZoteroItem): void {
    onInsert(item.citekey);
    closeCite();
  }

  function render(): void {
    list.innerHTML = "";
    results.forEach((it, i) => {
      const row = document.createElement("div");
      row.style.cssText =
        "padding:8px 10px;border-radius:6px;cursor:pointer;" +
        (i === 0 ? "background:#2c313a;" : "");
      const meta = [it.authors, it.year].filter(Boolean).join(" · ");
      row.innerHTML =
        `<div style="font-size:13px">${escapeHtml(it.title)}</div>` +
        `<div style="font-size:11px;opacity:.6">${escapeHtml(meta)} — <code>@${escapeHtml(it.citekey)}</code></div>`;
      row.onclick = () => insert(it);
      list.appendChild(row);
    });
  }

  function search(): void {
    const q = input.value.trim();
    window.clearTimeout(searchTimer);
    if (!q) { results = []; render(); status.textContent = ""; return; }
    status.textContent = t("搜尋中…");
    searchTimer = window.setTimeout(() => {
      call("zotero.search", { query: q })
        .then((res) => {
          results = (res as ZoteroItem[]) ?? [];
          status.textContent = results.length ? `${results.length} ${t("筆結果")}` : t("找不到結果");
          render();
        })
        .catch((err: Error) => {
          status.textContent = t("失敗：") + err.message;
        });
    }, 250);
  }

  input.oninput = search;
  input.onkeydown = (e) => {
    if (e.key === "Enter" && results[0]) insert(results[0]);
    else if (e.key === "Escape") closeCite();
  };

  overlay = panel;
  document.body.appendChild(panel);
  input.focus();
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c] ?? c,
  );
}
