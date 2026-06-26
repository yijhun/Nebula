/**
 * editor/main.ts — CodeMirror editor for the web core, supporting two formats:
 *   - Markdown: GFM + inline live preview + split HTML preview + Markdown→LaTeX.
 *   - LaTeX (.tex): stex syntax highlighting; compiled directly to PDF.
 *
 * The language/preview extensions live in a Compartment so the native shell can
 * switch modes per file (by extension) without recreating the editor.
 */
import { EditorState, Compartment } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { search, searchKeymap, highlightSelectionMatches, openSearchPanel } from "@codemirror/search";
import { linter, lintGutter, type Diagnostic } from "@codemirror/lint";
import { markdown } from "@codemirror/lang-markdown";
import { GFM } from "@lezer/markdown";
import {
  syntaxHighlighting, defaultHighlightStyle, StreamLanguage,
  codeFolding, foldGutter, foldKeymap, bracketMatching,
} from "@codemirror/language";
import { stex } from "@codemirror/legacy-modes/mode/stex";
import { oneDark } from "@codemirror/theme-one-dark";
import { convert } from "../latex/index.js";
import { convertProject } from "../latex/project.js";
import { latexToMarkdown } from "../latex/to-markdown.js";
import { lintLatex } from "./lint.js";
import { skeletonFor } from "../latex/builtin-templates.js";
import { renderHtml, setCiteLabelResolver, getLastCiteKeys, setBasePaths } from "./preview.js";
import { livePreview, refreshLivePreview } from "./livePreview.js";
import { unmatchedBrackets } from "./unmatched.js";
import { openAI } from "./ai.js";
import { openCite } from "./cite.js";
import { latexAutocomplete } from "./complete.js";
import { parseStructure } from "./outline.js";
import { setNoteNames } from "./notes.js";
import { setLang, t } from "./i18n.js";
import { vim } from "@replit/codemirror-vim";
import { call, rpcResolve } from "./bridge.js";
import { getConfig, mergeConfig, type NoteproConfig } from "./config.js";

type ViewMode = "edit" | "live" | "split" | "preview" | "tex";
type Mode = "markdown" | "latex";

let view: EditorView;
let previewEl: HTMLElement | null = null;
let appEl: HTMLElement | null = null;
let renderTimer: number | undefined;
let mode: Mode = "markdown";
let viewMode: ViewMode = "split";

/** Live linter: flag unbalanced $/$$/{}/\begin by underlining the offending
 * line (gutter marker + hover message), updated as you type. */
const latexLinter = linter((view) => {
  const doc = view.state.doc;
  const out: Diagnostic[] = [];
  // Markdown: only flag math-delimiter ($/$$) issues; full brace/\[\] checks
  // (which would false-positive on prose/code braces) are for LaTeX docs.
  for (const issue of lintLatex(doc.toString(), { braces: mode === "latex" })) {
    if (issue.line < 1 || issue.line > doc.lines) continue;
    const line = doc.line(issue.line);
    out.push({ from: line.from, to: line.to, severity: "error", message: issue.message });
  }
  return out;
}, { delay: 500 });

const langCompartment = new Compartment();
const themeCompartment = new Compartment();
const vimCompartment = new Compartment();
const lpCompartment = new Compartment();   // inline Live Preview (on in "live" mode)

// lang-markdown already provides Obsidian-style folding (heading sections via its
// `headerIndent` foldService + block/code folding via foldNodeProp); codeFolding()
// activates the fold state and foldGutter() shows the click-to-fold arrows.
const markdownExtensions = [
  markdown({ extensions: GFM }),
  lpCompartment.of([]),
  codeFolding(), foldGutter(),
];
const latexExtensions = [StreamLanguage.define(stex)];

/** Inline Live Preview is on only in markdown "live" mode. */
function applyLivePreview(): void {
  const want = viewMode === "live" && mode === "markdown";
  view.dispatch({ effects: lpCompartment.reconfigure(want ? livePreview : []) });
}

// --- Citation labels (author-year), fetched from Zotero, cached ---------------
const citeLabels = new Map<string, string>();
const citePending = new Set<string>();

/** Fallback label parsed from a BBT citekey, e.g. "chen…1997" → "Chen (1997)". */
function heuristicCiteLabel(key: string): string {
  const a = /^([A-Za-z][a-z]+)/.exec(key);
  const y = /(\d{4})/.exec(key);
  const author = a ? a[1]!.charAt(0).toUpperCase() + a[1]!.slice(1) : key;
  return y ? `${author} (${y[1]})` : key;
}
setCiteLabelResolver((k) =>
  getConfig().previewCiteStyle === "citekey" ? k : (citeLabels.get(k) ?? heuristicCiteLabel(k)),
);

/** Fetch real "Author et al. (year)" labels for any keys not yet cached. */
function ensureCiteLabels(keys: string[]): void {
  const missing = keys.filter((k) => !citeLabels.has(k) && !citePending.has(k));
  if (!missing.length) return;
  missing.forEach((k) => citePending.add(k));
  call("zotero.meta", { keys: missing })
    .then((res) => {
      const map = (res ?? {}) as Record<string, string>;
      for (const k of missing) {
        citePending.delete(k);
        if (map[k]) citeLabels.set(k, map[k]);
      }
      scheduleRender(); // re-render with the real labels
    })
    .catch(() => missing.forEach((k) => citePending.delete(k)));
}

/** Apply font size / family / line-height from config via CSS variables. */
function applyAppearance(): void {
  const c = getConfig();
  const root = document.documentElement.style;
  root.setProperty("--np-font-size", `${c.fontSize}px`);
  root.setProperty("--np-font-family", c.fontFamily);
  root.setProperty("--np-line-height", String(c.lineHeight));
}

function postToHost(msg: unknown): void {
  const handlers = (window as unknown as {
    webkit?: { messageHandlers?: { notepro?: { postMessage(m: unknown): void } } };
  }).webkit;
  handlers?.messageHandlers?.notepro?.postMessage(msg);
}

let outlineTimer: number | undefined;
/** Compute the document structure + word count and push to the native side. */
function pushOutline(): void {
  window.clearTimeout(outlineTimer);
  outlineTimer = window.setTimeout(() => {
    const text = view.state.doc.toString();
    postToHost({ type: "outline", items: parseStructure(text, mode) });
    const body = text.replace(/^---\n[\s\S]*?\n---/, "");        // drop frontmatter
    postToHost({ type: "stats", words: (body.match(/\S+/g) ?? []).length });
  }, 300);
}

/** Write a resized image's width back into the source as `![[ref|W]]`. */
function setImageWidth(ref: string, width: number): void {
  const doc = view.state.doc.toString();
  const esc = ref.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp("!\\[\\[" + esc + "(?:\\|\\d+)?\\]\\]");
  const m = re.exec(doc);
  if (!m) return;
  const replacement = `![[${ref}|${width}]]`;
  view.dispatch({ changes: { from: m.index, to: m.index + m[0].length, insert: replacement } });
}

/** Scroll the editor to (and place the cursor on) a 1-based source line. */
function jumpEditorToLine(line: number): void {
  if (!Number.isFinite(line) || line < 1) return;
  const l = Math.min(line, view.state.doc.lines);
  const pos = view.state.doc.line(l).from;
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: "center" }),
  });
  view.focus();
}

/** Align the preview to the editor's current line (scroll the matching block
 * into view) without stealing focus. */
function syncPreviewToLine(line: number): void {
  if (!previewEl) return;
  let best: HTMLElement | null = null;
  let bestLine = -1;
  for (const el of Array.from(previewEl.querySelectorAll<HTMLElement>("[data-line]"))) {
    const dl = Number(el.getAttribute("data-line"));
    if (dl <= line && dl > bestLine) { bestLine = dl; best = el; }
  }
  if (best) best.scrollIntoView({ block: "center" });
}

/** Patch the preview in place: replace only top-level blocks whose HTML
 * changed, and keep the scroll position. Avoids the full-innerHTML wipe that
 * flickered, jumped to the top, and re-typeset every (unchanged) equation. */
function morphPreview(html: string): void {
  if (!previewEl) return;
  const scroll = previewEl.scrollTop;
  const tmp = document.createElement("div");
  tmp.innerHTML = html;
  const next = Array.from(tmp.childNodes);
  const cur = Array.from(previewEl.childNodes);
  const n = Math.max(next.length, cur.length);
  for (let i = 0; i < n; i++) {
    const o = cur[i];
    const w = next[i];
    if (!w) { if (o) previewEl.removeChild(o); continue; }
    if (!o) { previewEl.appendChild(w); continue; }
    const oh = o instanceof Element ? o.outerHTML : o.textContent;
    const wh = w instanceof Element ? w.outerHTML : w.textContent;
    if (oh !== wh) previewEl.replaceChild(w, o);
  }
  previewEl.scrollTop = scroll;
}

function scheduleRender(): void {
  if (!previewEl) return;
  // Perf: in edit/live mode the #preview pane is hidden — skip rendering it
  // entirely (the live decorations handle the in-editor view). Big win on long
  // documents where the full remark/MathJax render is the bottleneck.
  if (mode === "markdown" && (viewMode === "edit" || viewMode === "live")) return;
  window.clearTimeout(renderTimer);
  // Adaptive debounce: snappy for normal notes, calmer for very large ones so
  // huge files don't re-render the whole preview on every keystroke.
  const len = view.state.doc.length;
  const delay = len > 60000 ? 500 : len > 20000 ? 320 : 200;
  renderTimer = window.setTimeout(() => {
    if (!previewEl) return;
    if (mode === "latex") {
      previewEl.innerHTML =
        `<p style="color:#888">${t("LaTeX 原始檔 — 用「匯出 PDF」直接編譯。")}</p>`;
    } else if (viewMode === "tex") {
      renderTexSource();
    } else {
      const html = renderHtml(view.state.doc.toString());
      ensureCiteLabels(getLastCiteKeys());
      morphPreview(html);
    }
  }, delay);
}

/** Render the live Markdown→LaTeX source into the preview pane (in-place "to
 * LaTeX" — no files, no compile). Updates only when the source changes. */
function renderTexSource(): void {
  if (!previewEl) return;
  let tex: string;
  try {
    tex = convert(view.state.doc.toString(), {
      bibBackend: "bibtex",
      defaultTemplate: getConfig().defaultTemplate,
    }).tex;
  } catch (e) {
    previewEl.innerHTML = `<pre class="np-preview-error">${e instanceof Error ? e.message : String(e)}</pre>`;
    return;
  }
  const cur = previewEl.firstElementChild;
  if (cur instanceof HTMLPreElement && cur.textContent === tex) return; // unchanged
  const pre = document.createElement("pre");
  pre.className = "np-tex-source";
  pre.textContent = tex;
  previewEl.replaceChildren(pre);
}

const api = {
  setContent(text: string): void {
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
    scheduleRender();
    pushOutline();
    postToHost({ type: "loaded" });
  },
  getContent(): string {
    return view.state.doc.toString();
  },
  /** Jump the editor's cursor to a 1-indexed line and scroll it into view —
   * used by SyncTeX reverse (PDF click → editor) from the native shell. */
  jumpToLine(line: number): void { jumpEditorToLine(line); },
  /** The citekey at/around the cursor — from `[@key]`, `[@key; @key2]`, or
   * `\cite{key}` / `\citep{...}` etc. Returns "" if the cursor isn't on one.
   * Used by "open in Zotero". */
  citeAtCursor(): string {
    const pos = view.state.selection.main.head;
    const line = view.state.doc.lineAt(pos);
    const col = pos - line.from;
    const text = line.text;
    // Markdown `[@key]` (possibly multiple, `;`-separated): find one whose
    // span contains the cursor, then pick the key nearest the cursor.
    const md = /\[([^\]\[\n]*@[^\]\n]*)\]/g;
    let m: RegExpExecArray | null;
    while ((m = md.exec(text))) {
      if (col >= m.index && col <= m.index + m[0].length) {
        const inner = m[1]!;
        const keys = [...inner.matchAll(/@([\w:.\-]+)/g)];
        if (!keys.length) continue;
        // nearest key to the cursor
        let best = keys[0]!; let bestDist = Infinity;
        for (const k of keys) {
          const kStart = m.index + 1 + (k.index ?? 0);
          const d = Math.abs(kStart - col);
          if (d < bestDist) { bestDist = d; best = k; }
        }
        return best[1]!;
      }
    }
    // LaTeX `\cite{key}` / `\citep{a,b}` etc.
    const tex = /\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{([^}]*)\}/g;
    while ((m = tex.exec(text))) {
      if (col >= m.index && col <= m.index + m[0].length) {
        const inner = m[1]!;
        const keys = inner.split(",").map((s) => s.trim()).filter(Boolean);
        return keys[0] ?? "";
      }
    }
    return "";
  },
  /** Currently selected text (empty if there's no selection). */
  getSelection(): string {
    const { from, to } = view.state.selection.main;
    return from === to ? "" : view.state.sliceDoc(from, to);
  },
  /** Heading-bounded section the cursor is in (h1/h2/h3 — whichever's
   * closest), or "" if no preceding heading. Useful for Cowork-with-Claude. */
  getCurrentSection(): string {
    const doc = view.state.doc;
    const headPos = view.state.selection.main.head;
    const headLine = doc.lineAt(headPos).number;
    let startLine = 1;
    for (let i = headLine; i >= 1; i--) {
      if (/^#{1,6}\s/.test(doc.line(i).text)) { startLine = i; break; }
    }
    let endLine = doc.lines;
    for (let i = headLine + 1; i <= doc.lines; i++) {
      if (/^#{1,6}\s/.test(doc.line(i).text)) { endLine = i - 1; break; }
    }
    return doc.sliceString(doc.line(startLine).from, doc.line(endLine).to);
  },
  /** Switch editor language: "markdown" or "latex". */
  setMode(next: Mode): void {
    mode = next;
    view.dispatch({
      effects: langCompartment.reconfigure(
        next === "latex" ? latexExtensions : markdownExtensions,
      ),
    });
    if (next === "latex") api.setViewMode("edit");
    else applyLivePreview();
    pushOutline();
    scheduleRender();
  },
  /** Convert the current Markdown doc to LaTeX (optionally with a template). */
  toLatex(templateId?: string): string {
    const r = convert(view.state.doc.toString(), {
      bibBackend: "bibtex",
      defaultTemplate: getConfig().defaultTemplate,
      ...(templateId ? { template: templateId } : {}),
    });
    return JSON.stringify({ tex: r.tex, bib: r.bib, keys: r.citationKeys });
  },
  /** Convert the current LaTeX doc back to Obsidian-flavored Markdown. */
  fromLatex(): string {
    return latexToMarkdown(view.state.doc.toString());
  },
  /** Check the doc for unbalanced $/$$/\begin — returns JSON [{line,message}].
   * `full` (default true) also checks {}/\[\]; pass false for Markdown. */
  lintLatex(full = true): string {
    return JSON.stringify(lintLatex(view.state.doc.toString(), { braces: full }));
  },
  /** Read the YAML frontmatter as ordered [key, value] pairs (JSON). */
  getFrontmatter(): string {
    const m = /^---\n([\s\S]*?)\n---/.exec(view.state.doc.toString());
    const fields: Array<[string, string]> = [];
    if (m) {
      for (const line of m[1]!.split("\n")) {
        const mm = /^([^:\n]+):\s?(.*)$/.exec(line);
        if (mm) fields.push([mm[1]!.trim(), mm[2]!]);
      }
    }
    return JSON.stringify(fields);
  },
  /** Set (or add) a frontmatter key, creating the `---` block if absent. */
  setFrontmatterField(key: string, value: string): void {
    const doc = view.state.doc.toString();
    const m = /^---\n([\s\S]*?)\n---/.exec(doc);
    if (m) {
      const lines = m[1]!.split("\n");
      let found = false;
      for (let i = 0; i < lines.length; i++) {
        const mm = /^([^:\n]+):/.exec(lines[i]!);
        if (mm && mm[1]!.trim() === key) { lines[i] = `${key}: ${value}`; found = true; break; }
      }
      if (!found) lines.push(`${key}: ${value}`);
      view.dispatch({ changes: { from: 0, to: m[0].length, insert: `---\n${lines.join("\n")}\n---` } });
    } else {
      view.dispatch({ changes: { from: 0, insert: `---\n${key}: ${value}\n---\n\n` } });
    }
    scheduleRender();
  },
  /** Remove a frontmatter key (drops the whole block if it becomes empty). */
  removeFrontmatterField(key: string): void {
    const doc = view.state.doc.toString();
    const m = /^---\n([\s\S]*?)\n---/.exec(doc);
    if (!m) return;
    const kept = m[1]!.split("\n").filter((l) => {
      const mm = /^([^:\n]+):/.exec(l);
      return !(mm && mm[1]!.trim() === key);
    });
    const insert = kept.length ? `---\n${kept.join("\n")}\n---` : "";
    let to = m[0].length;
    if (!kept.length && doc[to] === "\n") to += 1; // also drop the trailing newline
    view.dispatch({ changes: { from: 0, to, insert } });
    scheduleRender();
  },
  /** Assemble a multi-file project paper from chapter md strings. `json` is
   * `{chapters:[{name,md}], template?, title?, author?, date?, bibBackend?}`.
   * Returns `{master, flat, chapters:[{name,body}], citationKeys}` as JSON. */
  buildProject(json: string): string {
    try {
      const p = JSON.parse(json) as {
        chapters: { name: string; md: string }[];
        template?: string; title?: string; author?: string;
        date?: string; bibBackend?: "biber" | "bibtex";
      };
      const r = convertProject(p.chapters ?? [], {
        bibBackend: "bibtex",
        ...(p.template ? { template: p.template } : {}),
        ...(p.title ? { title: p.title } : {}),
        ...(p.author ? { author: p.author } : {}),
        ...(p.date !== undefined ? { date: p.date } : {}),
        ...(p.bibBackend ? { bibBackend: p.bibBackend } : {}),
      });
      return JSON.stringify(r);
    } catch (e) {
      return JSON.stringify({ error: e instanceof Error ? e.message : String(e) });
    }
  },
  /** Apply user config pushed from the native settings (JSON string). */
  configure(json: string): void {
    try {
      mergeConfig(JSON.parse(json) as Partial<NoteproConfig>);
    } catch {
      return;
    }
    applyAppearance();
    scheduleRender();
  },
  /** Insert a citation at the cursor (format depends on the document mode). */
  insertCitation(key: string): void {
    const cmd = getConfig().citeLatexCommand || "autocite";
    const text = mode === "latex" ? `\\${cmd}{${key}}` : `[@${key}]`;
    const pos = view.state.selection.main.head;
    view.dispatch({
      changes: { from: pos, insert: text },
      selection: { anchor: pos + text.length },
    });
    view.focus();
  },
  /** Return a standalone .tex skeleton for "New from template". */
  newFromTemplate(id: string): string {
    return skeletonFor(id);
  },
  setViewMode(m: ViewMode): void {
    if (!appEl) return;
    viewMode = m;
    appEl.classList.remove("mode-edit", "mode-live", "mode-split", "mode-preview", "mode-tex");
    appEl.classList.add(`mode-${m}`);
    applyLivePreview();
    if (m === "split" || m === "preview" || m === "tex") scheduleRender();
  },
  /** Called by the native side to settle a bridge RPC (e.g. ai.edit). */
  _rpcResolve(id: number, ok: boolean, payload: unknown): void {
    rpcResolve(id, ok, payload);
  },
  /** Enable/disable Vim modal editing (nvim-style, no-mouse). */
  setVim(on: boolean): void {
    view.dispatch({ effects: vimCompartment.reconfigure(on ? vim() : []) });
  },
  /** Switch the editor + page appearance: "dark" or "light". */
  setTheme(name: "dark" | "light"): void {
    view.dispatch({ effects: themeCompartment.reconfigure(name === "dark" ? oneDark : []) });
    document.body.classList.toggle("np-light", name === "light");
    document.body.classList.toggle("np-dark", name !== "light");
  },
  /** Trigger the AI overlay programmatically (also bound to ⌘K). */
  ai(): void {
    openAI(view);
  },
  /** Trigger the Zotero cite picker programmatically (also bound to ⌘⇧K). */
  cite(): void {
    openCite((k) => api.insertCitation(k));
  },
  /** Open the in-document search panel (⌘F; also callable from the native menu). */
  find(): void {
    view.focus();
    openSearchPanel(view);
  },
  /** Base paths for resolving vault images in the preview. */
  setBasePaths(noteDir: string, vaultDir: string): void {
    setBasePaths(noteDir, vaultDir);
    // Force inline Live Preview to re-resolve image widgets' npimg:// src.
    view.dispatch({ effects: refreshLivePreview.of() });
    scheduleRender();
  },
  /** Insert text at the cursor (used by drag-and-drop image insertion). */
  insertText(text: string): void {
    const pos = view.state.selection.main.head;
    view.dispatch({ changes: { from: pos, insert: text }, selection: { anchor: pos + text.length } });
    view.focus();
  },
  /** Set the editor UI language ("en" | "zh"), pushed from the native shell. */
  setLang(lang: string): void {
    setLang(lang);
    scheduleRender();
  },
  /** Receive the vault's note names (for `[[` completion + broken-link flags). */
  setNoteList(json: string): void {
    try {
      setNoteNames(JSON.parse(json) as string[]);
      scheduleRender(); // re-evaluate broken-link styling
    } catch {
      /* ignore */
    }
  },
  /** Scroll/place the cursor on a 1-based line (from a compile-error jump). */
  scrollToLine(line: number): void {
    jumpEditorToLine(line);
  },
  /** Scroll the editor to a character position (from the native outline). */
  scrollToPos(pos: number): void {
    const p = Math.max(0, Math.min(pos, view.state.doc.length));
    view.dispatch({
      selection: { anchor: p },
      effects: EditorView.scrollIntoView(p, { y: "start", yMargin: 40 }),
    });
    view.focus();
  },
};
(window as unknown as { notepro: typeof api }).notepro = api;

/** Wire the editor|preview divider so split mode is resizable. Sets the
 * editor's flex-basis as a % of the app width (responsive to window resize),
 * persisted in localStorage. A full-window overlay during the drag stops
 * CodeMirror / the preview from swallowing pointermove events. */
function setupSplitDivider(app: HTMLElement | null, editor: HTMLElement): void {
  const divider = document.getElementById("np-divider");
  if (!app || !divider) return;

  const KEY = "np.splitRatio";
  const clampRatio = (r: number) => Math.max(0.2, Math.min(0.8, r));
  const saved = parseFloat(localStorage.getItem(KEY) ?? "");
  let ratio = Number.isFinite(saved) ? clampRatio(saved) : 0.5;
  // Drive the editor width via a CSS var consumed ONLY by the split-mode rule,
  // so edit/live/preview keep their own flex-basis (100% editor, etc.).
  const apply = () => { app.style.setProperty("--split-ratio", `${ratio * 100}%`); };
  apply();

  divider.addEventListener("pointerdown", (e: PointerEvent) => {
    e.preventDefault();
    divider.classList.add("np-dragging");
    // Block CodeMirror/preview from grabbing the move + show the resize cursor
    // everywhere during the drag.
    const overlay = document.createElement("div");
    overlay.style.cssText =
      "position:fixed;inset:0;z-index:9999;cursor:col-resize;";
    document.body.appendChild(overlay);

    const onMove = (ev: PointerEvent) => {
      const rect = app.getBoundingClientRect();
      if (rect.width <= 0) return;
      ratio = clampRatio((ev.clientX - rect.left) / rect.width);
      apply();
    };
    const onUp = () => {
      divider.classList.remove("np-dragging");
      overlay.remove();
      localStorage.setItem(KEY, String(ratio));
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", onUp);
    };
    document.addEventListener("pointermove", onMove);
    document.addEventListener("pointerup", onUp);
  });
}

function boot(): void {
  appEl = document.getElementById("app");
  const parent = document.getElementById("editor");
  previewEl = document.getElementById("preview");
  if (!parent) return;

  setupSplitDivider(appEl, parent);

  // Pop-out button on the preview corner → detach the live preview window.
  document.getElementById("np-preview-popout")?.addEventListener("click", () => {
    postToHost({ type: "popoutPreview" });
  });

  // Drag an image file onto the editor/preview → send bytes to native, which
  // saves it into the vault and inserts `![[name]]`. (Done in JS because the
  // WKWebView swallows native drops in a private subview.)
  document.addEventListener("dragover", (e) => {
    if (e.dataTransfer?.types.includes("Files")) e.preventDefault();
  });
  document.addEventListener("drop", (e) => {
    const files = e.dataTransfer?.files;
    if (!files || !files.length) return;
    e.preventDefault();
    for (const f of Array.from(files)) {
      if (!f.type.startsWith("image/")) continue;
      const reader = new FileReader();
      reader.onload = () => postToHost({ type: "dropImage", name: f.name, data: String(reader.result) });
      reader.readAsDataURL(f);
    }
  });

  // Drag an embedded image's right edge to resize it; on release, write the
  // width back as `![[ref|W]]` so it persists. Works on images in BOTH the
  // split preview pane and inline in Live Preview (hence document-level).
  let resizing: { img: HTMLImageElement; startX: number; startW: number } | null = null;
  const EDGE = 14;
  document.addEventListener("pointermove", (e) => {
    if (resizing) return;
    const img = (e.target as HTMLElement)?.closest("img[data-ref]") as HTMLImageElement | null;
    if (img) {
      const r = img.getBoundingClientRect();
      img.style.cursor = e.clientX > r.right - EDGE ? "ew-resize" : "";
    }
  });
  document.addEventListener("pointerdown", (e) => {
    const img = (e.target as HTMLElement)?.closest("img[data-ref]") as HTMLImageElement | null;
    if (!img) return;
    const r = img.getBoundingClientRect();
    if (e.clientX > r.right - EDGE) {
      resizing = { img, startX: e.clientX, startW: r.width };
      e.preventDefault();
    }
  }, true);   // capture: claim the edge-drag before CodeMirror handles the press
  window.addEventListener("pointermove", (e) => {
    if (!resizing) return;
    const w = Math.max(40, Math.round(resizing.startW + (e.clientX - resizing.startX)));
    resizing.img.style.width = `${w}px`;
    resizing.img.style.maxWidth = "none";
  });
  window.addEventListener("pointerup", () => {
    if (!resizing) return;
    const ref = resizing.img.getAttribute("data-ref");
    const w = Math.round(resizing.img.getBoundingClientRect().width);
    resizing = null;
    if (ref) setImageWidth(ref, w);
  });

  // Single click: open a [[wikilink]] (links stay one-click).
  previewEl?.addEventListener("click", (e) => {
    const target = e.target as HTMLElement | null;
    const a = target?.closest(".np-wikilink") as HTMLElement | null;
    if (a) {
      e.preventDefault();
      const t = a.getAttribute("data-target");
      if (t) postToHost({ type: "openLink", target: t });
      return;
    }
    // Click a citation pill → open that item in Zotero (Better BibTeX URI).
    const cite = target?.closest(".np-cite") as HTMLElement | null;
    if (cite) {
      e.preventDefault();
      const key = cite.getAttribute("data-cite");
      if (key) postToHost({ type: "openCite", key });
    }
  });
  // Double click: jump the editor to that block's source line.
  // MathJax replaces `.math-display`'s children with an SVG inside `<mjx-container>`;
  // `Element.closest()` on an SVG element doesn't reliably traverse out of the
  // SVG subtree into the HTML ancestors in WebKit, so a dblclick on a rendered
  // equation never finds the `data-line` carried by the wrapping HTML div.
  // composedPath() gives the real bubble path including the HTML ancestors.
  previewEl?.addEventListener("dblclick", (e) => {
    for (const node of e.composedPath()) {
      if (node instanceof HTMLElement && node.hasAttribute("data-line")) {
        const line = Number(node.getAttribute("data-line"));
        jumpEditorToLine(line);   // local jump (no-op visually in a mirror)
        // Also tell the host: in a popped-out preview window this routes the
        // jump to the SOURCE editor in the main window.
        postToHost({ type: "previewJump", line });
        return;
      }
    }
  });

  // Smart $ — closeBrackets-style pairing but math-aware:
  //   • cursor adjacent to a closing $   → overtype it (skip past), no insert
  //   • inside an unclosed `$…` (odd # of unescaped $ before cursor) → single $
  //   • otherwise                         → pair `$|$` (insert "$$", cursor mid)
  // Beats the default symmetric pair, which would otherwise leave a stray $.
  const smartDollar = EditorView.inputHandler.of((v, from, to, text) => {
    if (text !== "$") return false;
    const doc = v.state.doc;
    const charAfter = to < doc.length ? doc.sliceString(to, to + 1) : "";
    if (charAfter === "$") {                                     // overtype
      v.dispatch({ selection: { anchor: to + 1 } });
      return true;
    }
    const before = doc.sliceString(0, from);
    let count = 0;
    for (let i = 0; i < before.length; i++) {
      if (before[i] === "$" && (i === 0 || before[i - 1] !== "\\")) count++;
    }
    if (count % 2 === 1) {                                       // close open math
      v.dispatch({
        changes: { from, to, insert: "$" },
        selection: { anchor: from + 1 },
      });
      return true;
    }
    v.dispatch({                                                 // pair $|$
      changes: { from, to, insert: "$$" },
      selection: { anchor: from + 1 },
    });
    return true;
  });

  const onChange = EditorView.updateListener.of((u) => {
    if (u.docChanged) {
      postToHost({ type: "dirty" });
      scheduleRender();
      pushOutline();
    } else if (u.selectionSet) {
      const line = u.state.doc.lineAt(u.state.selection.main.head).number;
      if (mode === "markdown") syncPreviewToLine(line);
      // SyncTeX forward — the native shell calls `synctex view` to find the
      // PDF page+coord for this line and scrolls the live PDF preview.
      postToHost({ type: "cursorLine", line });
    }
  });

  view = new EditorView({
    parent,
    state: EditorState.create({
      doc: "# 歡迎使用 Nebula\n\n左邊輸入 **Markdown**，右邊即時預覽。⌘E 匯出 PDF。\n\n- [ ] 待辦\n- [x] 完成\n\n行內公式 $E = mc^2$。\n",
      extensions: [
        vimCompartment.of([]),           // Vim mode (toggled via settings) — highest precedence
        lineNumbers(), highlightActiveLine(), drawSelection(),
        history(),
        search({ top: true }), highlightSelectionMatches(),
        lintGutter(), latexLinter,
        latexAutocomplete,
        // Auto-close pairs: built-in handles () [] {} "" '' `` (skip/delete
        // smartly via closeBracketsKeymap). $ is handled by the smart math
        // handler below — pair on empty, but if there's an odd number of
        // unescaped $ before the cursor (i.e. we're inside open `$…`), the
        // next $ closes it (single insert), and if the closing $ is right
        // next to the cursor, just overtype (don't double-insert).
        closeBrackets(),
        EditorState.languageData.of(() => [{
          closeBrackets: { brackets: ["(", "[", "{", "\"", "'", "`"] },
        }]),
        smartDollar,
        // IDE-style bracket matching: highlights the partner of () [] {}
        // adjacent to the cursor (.cm-matchingBracket / cm-nonmatchingBracket).
        bracketMatching(),
        // Always-on red highlight on UNMATCHED brackets and dollar signs.
        // (`mode` here is the closure-captured top-level var that changes as
        // the user switches md ⇄ tex.)
        unmatchedBrackets({ get: () => mode }),
        keymap.of([
          { key: "Mod-k", run: (v) => { openAI(v); return true; } },
          { key: "Mod-Shift-k", run: () => { openCite((k) => api.insertCitation(k)); return true; } },
          ...closeBracketsKeymap,
          ...searchKeymap, ...foldKeymap, ...defaultKeymap, ...historyKeymap,
        ]),
        langCompartment.of(markdownExtensions),
        syntaxHighlighting(defaultHighlightStyle),
        themeCompartment.of(oneDark), EditorView.lineWrapping, onChange,
      ],
    }),
  });

  // Debug affordance (harmless): lets tooling drive the editor.
  (window as unknown as { __editorView: EditorView }).__editorView = view;

  applyAppearance();
  api.setViewMode("split");
  scheduleRender();
  pushOutline();
  postToHost({ type: "ready" });
}

if (document.readyState === "loading") window.addEventListener("DOMContentLoaded", boot);
else boot();
