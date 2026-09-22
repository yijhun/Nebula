/**
 * Chat panel UI (chat.html). Talks to the native ChatController through
 * `webkit.messageHandlers.nebulaChat`; receives raw CLI events via
 * `window.nebulaChat.onEvent(line)` and account/mode state via `setState`.
 * Assistant text is rendered with the same pipeline as the note preview, so
 * maths and charts in replies look exactly like they do in notes.
 */
import { renderHtml } from "../editor/preview.js";
import { setLang, t } from "../editor/i18n.js";
import {
  emptyState, reduce, addUser, editView, toolSummary, shortPath,
  type ChatState, type ToolBlock, type Block,
} from "./events.js";

interface Account {
  id: string; provider: "claude" | "codex"; label: string; subtitle: string;
  loggedIn: boolean; isDefault: boolean;
}
interface ModelOption { id: string; name: string }
interface Attachment { path: string; name: string; isDir?: boolean }
interface HostState {
  accounts: Account[]; activeID: string; mode: string; codexInstalled: boolean; vault: string;
  model: string; models: ModelOption[]; lang: string; attachments: Attachment[];
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const log = $<HTMLDivElement>("log");
const input = $<HTMLTextAreaElement>("input");
const sendBtn = $<HTMLButtonElement>("send");
const acctBtn = $<HTMLButtonElement>("acct");
const menu = $<HTMLDivElement>("menu");
const modeSel = $<HTMLSelectElement>("mode");
const modelSel = $<HTMLSelectElement>("model");
const hint = $<HTMLDivElement>("hint");

let chat: ChatState = emptyState();
let host: HostState = { accounts: [], activeID: "", mode: "acceptEdits", codexInstalled: false,
                        vault: "", model: "", models: [], lang: "zh", attachments: [] };
let attachNote = true;
let attachSel = false;

function post(msg: Record<string, unknown>): void {
  (window as unknown as { webkit?: { messageHandlers?: { nebulaChat?: { postMessage(m: unknown): void } } } })
    .webkit?.messageHandlers?.nebulaChat?.postMessage(msg);
}

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => (c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;"));

// ── Markdown rendering (cached: while streaming only the last block changes) ──
const mdCache = new Map<string, string>();
function md(text: string): string {
  const hit = mdCache.get(text);
  if (hit !== undefined) return hit;
  const html = renderHtml(text);
  if (mdCache.size > 400) mdCache.clear();
  mdCache.set(text, html);
  return html;
}

// ── Diff (line LCS; strings here are small) ──
function diffLines(a: string, b: string): Array<{ t: "ctx" | "add" | "del"; s: string }> {
  const x = a.split("\n"), y = b.split("\n");
  const n = x.length, m = y.length;
  if (n * m > 250_000) {             // pathological: just show both sides
    return [...x.map((s) => ({ t: "del" as const, s })), ...y.map((s) => ({ t: "add" as const, s }))];
  }
  const L: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
    L[i]![j] = x[i] === y[j] ? L[i + 1]![j + 1]! + 1 : Math.max(L[i + 1]![j]!, L[i]![j + 1]!);
  }
  const out: Array<{ t: "ctx" | "add" | "del"; s: string }> = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (x[i] === y[j]) { out.push({ t: "ctx", s: x[i]! }); i++; j++; }
    else if (L[i + 1]![j]! >= L[i]![j + 1]!) out.push({ t: "del", s: x[i++]! });
    else out.push({ t: "add", s: y[j++]! });
  }
  while (i < n) out.push({ t: "del", s: x[i++]! });
  while (j < m) out.push({ t: "add", s: y[j++]! });
  return out;
}

function renderDiff(pairs: Array<{ old: string; new: string }>): string {
  const rows: string[] = [];
  pairs.forEach((p, k) => {
    if (k > 0) rows.push(`<div class="ctx">⋯</div>`);
    for (const d of diffLines(p.old, p.new)) {
      const sign = d.t === "add" ? "+ " : d.t === "del" ? "− " : "  ";
      rows.push(`<div class="${d.t}">${esc(sign + d.s)}</div>`);
    }
  });
  return `<div class="diff">${rows.join("")}</div>`;
}

// ── Blocks ──
function renderTool(tool: ToolBlock, streaming: boolean): string {
  const ev = editView(tool);
  const pending = tool.result === undefined && streaming;
  if (ev) {
    const status = tool.reverted ? t("已還原")
      : tool.isError ? t("失敗")
      : tool.result !== undefined ? t("已套用") : t("進行中…");
    const canRevert = ev.kind === "edit" && tool.result !== undefined && !tool.isError && !tool.reverted;
    const body = ev.kind === "edit"
      ? renderDiff(ev.pairs)
      : `<div class="diff">${(ev.content ?? "").split("\n").slice(0, 40).map((l) => `<div class="add">${esc("+ " + l)}</div>`).join("")}` +
        ((ev.content ?? "").split("\n").length > 40 ? `<div class="ctx">⋯</div>` : "") + `</div>`;
    return `<div class="tool edit${tool.reverted ? " reverted" : ""}">
      <div class="hd"><span>✏️</span><span class="path" title="${esc(ev.path)}">${esc(shortPath(ev.path))}</span>
        <span class="badge">${ev.kind === "write" ? t("寫入") : t("修改")}</span><span class="sp"></span>
        <span class="badge">${status}</span>
        <button class="mini" data-open="${esc(ev.path)}">${t("開啟")}</button>
        ${canRevert ? `<button class="mini" data-revert="${esc(tool.id)}">${t("還原")}</button>` : ""}
      </div>${body}</div>`;
  }
  const status = pending ? "…" : tool.isError ? "⚠︎" : "✓";
  const out = tool.result ? `<pre class="out">${esc(tool.result.slice(0, 4000))}</pre>` : "";
  return `<details class="tool"><summary><span>▸</span>${esc(toolSummary(tool))}<span class="st">${status}</span></summary>${out}</details>`;
}

function renderBlocks(blocks: Block[], streaming: boolean): string {
  let html = "";
  blocks.forEach((b, i) => {
    if (b.type === "text") {
      if (!b.text) return;
      const last = streaming && i === blocks.length - 1;
      html += `<div class="md${last ? " cursor" : ""}">${md(b.text)}</div>`;
    } else {
      html += renderTool(b, streaming);
    }
  });
  if (streaming && !html) html = `<div class="md cursor"></div>`;
  return html;
}

/** Hand the transcript to the shell so it survives pane switches and quits. */
let persistTimer: number | undefined;
function persist(): void {
  window.clearTimeout(persistTimer);
  persistTimer = window.setTimeout(() => {
    post({ type: "persist", items: chat.items });
  }, 700);
}

// ── Transcript ──
let scheduled = false;
function render(): void {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 80;
    // Keep open/closed state of tool <details> across re-renders.
    const open = new Set<number>();
    log.querySelectorAll("details").forEach((d, i) => { if (d.open) open.add(i); });

    if (!chat.items.length) {
      const a = activeAccount();
      log.innerHTML = `<div class="empty"><b>${a ? esc(a.label) : "Claude"}</b><br>
        ${t("在「")}${esc(host.vault || t("你的 vault"))}${t("」裡對話 — 可以問問題、整理筆記、改寫段落。")}<br>
        ${t("預設會附上目前開啟的筆記。")}</div>`;
    } else {
      log.innerHTML = chat.items.map((it) => {
        switch (it.kind) {
          case "user": return `<div class="msg user">${esc(it.text)}</div>`;
          case "assistant": return `<div class="msg asst">${renderBlocks(it.blocks, it.streaming)}</div>`;
          case "notice": return `<div class="msg notice ${it.level}">${esc(it.text)}</div>`;
          case "done": return it.seconds > 0 ? `<div class="done">${it.seconds.toFixed(1)}s</div>` : "";
        }
      }).join("");
    }
    log.querySelectorAll("details").forEach((d, i) => { if (open.has(i)) d.open = true; });
    if (nearBottom) log.scrollTop = log.scrollHeight;
    updateComposer();
    renderAttachments();
    if (!chat.busy) persist();
  });
}

log.addEventListener("click", (e) => {
  const el = e.target as HTMLElement;
  const openPath = el.getAttribute("data-open");
  if (openPath) { post({ type: "openFile", path: openPath }); return; }
  const rid = el.getAttribute("data-revert");
  if (rid) {
    const t = findTool(rid);
    const ev = t && editView(t);
    if (!ev) return;
    // Undo in reverse order so earlier edits line up again.
    [...ev.pairs].reverse().forEach((p) =>
      post({ type: "revertEdit", path: ev.path, oldString: p.old, newString: p.new, editID: rid }));
  }
});

function findTool(id: string): ToolBlock | undefined {
  for (const it of chat.items) {
    if (it.kind !== "assistant") continue;
    for (const b of it.blocks) if (b.type === "tool" && b.id === id) return b;
  }
  return undefined;
}

// ── Composer ──
/** Signed in as far as we can tell: `auth status` says so AND the last turn
 * didn't bounce on authentication (an expired token still reports loggedIn). */
function signedIn(a: Account | undefined): boolean {
  return !!a && a.loggedIn && !chat.authFailed;
}

function updateComposer(): void {
  const a = activeAccount();
  sendBtn.textContent = chat.busy ? t("停止") : t("送出");
  sendBtn.classList.toggle("stop", chat.busy);
  sendBtn.disabled = !chat.busy && !input.value.trim();
  hint.textContent = a && !signedIn(a)
    ? (chat.authFailed ? t("⚠︎ 登入已過期 — 點上方帳號名稱 → 登入") : t("⚠︎ 這個帳號尚未登入 — 點上方帳號名稱 → 登入"))
    : chat.model ? `模型：${chat.model.replace(/\[.*\]$/, "")}` : "";
  renderAccountButton();
}

function autoGrow(): void {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 180) + "px";
}

function submit(): void {
  if (chat.busy) { post({ type: "stop" }); return; }
  const text = input.value.trim();
  if (!text) return;
  addUser(chat, text);
  post({ type: "send", text, attachNote, attachSelection: attachSel });
  input.value = "";
  attachSel = false;
  syncChips();
  autoGrow();
  render();
}

input.addEventListener("input", () => { autoGrow(); updateComposer(); });
input.addEventListener("keydown", (e) => {
  // Never send while an IME (注音/倉頡…) is still composing a character.
  if (e.isComposing || e.keyCode === 229) return;
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
});
sendBtn.addEventListener("click", submit);

function renderAttachments(): void {
  const box = $("files");
  box.innerHTML = host.attachments.map((f) =>
    `<span class="chip file" title="${esc(f.path)}">${f.isDir ? "📁" : "📎"} ${esc(f.name)}` +
    `<button class="x" data-unattach="${esc(f.path)}">✕</button></span>`).join("");
  box.style.display = host.attachments.length ? "flex" : "none";
}
$("files").addEventListener("click", (e) => {
  const p = (e.target as HTMLElement).getAttribute("data-unattach");
  if (p) post({ type: "removeAttachment", path: p });
});
$("attFile").addEventListener("click", () => post({ type: "addFiles" }));

function syncChips(): void {
  $("attNote").classList.toggle("on", attachNote);
  $("attSel").classList.toggle("on", attachSel);
}
$("attNote").addEventListener("click", () => { attachNote = !attachNote; syncChips(); });
$("attSel").addEventListener("click", () => { attachSel = !attachSel; syncChips(); });

$("new").addEventListener("click", () => { post({ type: "newChat" }); });
modeSel.addEventListener("change", () => post({ type: "setMode", mode: modeSel.value }));

// ── Accounts ──
function activeAccount(): Account | undefined {
  return host.accounts.find((a) => a.id === host.activeID) ?? host.accounts[0];
}

function renderAccountButton(): void {
  const a = activeAccount();
  const ok = signedIn(a);
  acctBtn.innerHTML = a
    ? `<span class="dot${ok ? " on" : ""}"></span>
       <span class="acct-text"><div class="acct-name">${esc(a.label)}</div>
       <div class="acct-sub">${esc(chat.authFailed ? t("登入已過期") : a.subtitle || (a.loggedIn ? "" : t("未登入")))}</div></span>
       <span class="badge">${a.provider === "claude" ? "Claude" : "ChatGPT"}</span><span>▾</span>`
    : "帳號";
}

function renderMenu(): void {
  const rows = host.accounts.map((a) => `
    <div class="mrow pick${a.id === host.activeID ? " active" : ""}" data-pick="${a.id}">
      <span class="dot${a.loggedIn ? " on" : ""}"></span>
      <div class="grow"><div class="acct-name">${esc(a.label)}</div>
        <div class="acct-sub">${esc(a.subtitle || (a.loggedIn ? "" : t("未登入")))}</div></div>
      <span class="badge">${a.provider === "claude" ? "Claude" : "ChatGPT"}</span>
      <button class="mini" data-login="${a.id}">${t("登入")}</button>
      ${a.isDefault ? "" : `<button class="mini" data-remove="${a.id}">${t("移除")}</button>`}
    </div>`).join("");
  menu.innerHTML = rows + `<div class="msep"></div>
    <div class="mrow pick" data-add="claude">${t("＋ 新增 Claude 帳號")}</div>
    <div class="mrow pick" data-add="codex">${t("＋ 新增 ChatGPT 帳號")}${host.codexInstalled ? "" : t("（需先安裝 Codex CLI）")}</div>
    <div class="mrow pick" data-refresh="1">${t("↻ 重新整理登入狀態")}</div>
    <div class="mhint">${t("每個帳號是獨立的登入；切換帳號會開始新對話。")}</div>`;
}

acctBtn.addEventListener("click", (e) => {
  e.stopPropagation();
  renderMenu();
  menu.classList.toggle("open");
});
document.addEventListener("click", (e) => {
  if (!menu.contains(e.target as Node)) menu.classList.remove("open");
});
menu.addEventListener("click", (e) => {
  const el = (e.target as HTMLElement);
  const btn = el.closest("[data-login],[data-remove]") as HTMLElement | null;
  if (btn?.dataset.login) { post({ type: "login", id: btn.dataset.login }); e.stopPropagation(); return; }
  if (btn?.dataset.remove) {
    const a = host.accounts.find((x) => x.id === btn.dataset.remove);
    if (a && confirm(`移除帳號「${a.label}」？（會刪除這個帳號在 Nebula 裡的登入資料）`)) {
      post({ type: "removeAccount", id: a.id });
    }
    e.stopPropagation(); return;
  }
  const row = el.closest(".mrow") as HTMLElement | null;
  if (!row) return;
  if (row.dataset.pick) {
    if (row.dataset.pick !== host.activeID) post({ type: "switchAccount", id: row.dataset.pick });
    menu.classList.remove("open");
  } else if (row.dataset.add) {
    const name = prompt(row.dataset.add === "claude" ? t("新 Claude 帳號的名稱（例如：研究室 Max）") : t("新 ChatGPT 帳號的名稱"), "");
    if (name !== null) post({ type: "addAccount", provider: row.dataset.add, label: name.trim() });
    menu.classList.remove("open");
  } else if (row.dataset.refresh) {
    chat.authFailed = false;          // give a fresh login the benefit of the doubt
    post({ type: "refreshAccounts" });
    render();
  }
});

// ── Host bridge ──
(window as unknown as { nebulaChat: unknown }).nebulaChat = {
  onEvent(line: string): void {
    let ev: Record<string, unknown>;
    try { ev = JSON.parse(line) as Record<string, unknown>; } catch { return; }
    reduce(chat, ev);
    render();
  },
  setState(json: string): void {
    try { host = JSON.parse(json) as HostState; } catch { return; }
    setLang(host.lang === "en" ? "en" : "zh");
    applyLang();
    modeSel.value = host.mode;
    renderModels();
    renderAttachments();
    renderAccountButton();
    if (menu.classList.contains("open")) renderMenu();
    render();
  },
};

/** Re-label everything that isn't re-rendered from state. */
function applyLang(): void {
  acctBtn.title = t("切換帳號");
  modeSel.title = t("Claude 能做的事");
  modeSel.options[0]!.text = t("可改筆記");
  modeSel.options[1]!.text = t("唯讀");
  modelSel.title = t("模型");
  $("new").textContent = t("新對話");
  $("attNote").textContent = t("＋ 目前筆記");
  $("attSel").textContent = t("＋ 選取內容");
  $("attFile").textContent = t("＋ 檔案");
  $("drop").textContent = t("放開以附加檔案");
  input.placeholder = t("問問題、請它改筆記…（Enter 送出，Shift+Enter 換行）");
  updateComposer();
}

function renderModels(): void {
  const opts = host.models.length ? host.models : [{ id: "", name: "預設" }];
  modelSel.innerHTML = opts
    .map((m) => `<option value="${esc(m.id)}">${esc(m.id ? m.name : t("預設"))}</option>`).join("");
  modelSel.value = host.model;
}
modelSel.addEventListener("change", () => post({ type: "setModel", model: modelSel.value }));

syncChips();
renderAttachments();
applyLang();
renderModels();
renderAccountButton();
render();
post({ type: "ready" });
