/**
 * livePreview.ts — Obsidian-style inline "Live Preview" for CodeMirror 6.
 *
 * Renders formatting in place inside the editor, so a single window both edits
 * and shows the finished look (no separate preview pane). The raw markup is
 * revealed on the line(s) the cursor/selection touches, so you can still edit
 * it — exactly like Obsidian's Live Preview. Three stages of fidelity:
 *
 *   Stage 1  headings · bold/italic/strike/inline-code · hidden marks ·
 *            inline `$…$` and block `$$…$$` math (rendered to SVG)
 *   Stage 2  images (`![](url)` and `![[file]]`) · `[[wikilinks]]` as pills ·
 *            interactive task checkboxes · blockquotes & callouts
 *   Stage 3  GFM tables (rendered) · fenced code blocks (framed)
 *
 * Implementation: a StateField walks the Lezer markdown tree (plus a few regex
 * passes for syntax the tree doesn't model — math, wikilinks, `![[embeds]]`)
 * and produces a DecorationSet. It must be a StateField rather than a ViewPlugin
 * because block widgets that replace line breaks (display math, tables) are not
 * allowed from plugins. Rebuilds on doc change and selection change.
 */
import {
  EditorView,
  Decoration,
  WidgetType,
  type DecorationSet,
} from "@codemirror/view";
import { StateField, StateEffect, type EditorState, type Extension, type Range } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { tex2svg } from "./mathjax.js";
import { imgSrc } from "./preview.js";
import { noteExists } from "./notes.js";

/** Notes longer than this skip live decorations (fall back to raw) for speed. */
const MAX_LEN = 300_000;

const HEADING_LEVEL: Record<string, number> = {
  ATXHeading1: 1, ATXHeading2: 2, ATXHeading3: 3,
  ATXHeading4: 4, ATXHeading5: 5, ATXHeading6: 6,
};

/** Inline parent nodes whose content should be styled. */
const CONTENT_CLASS: Record<string, string> = {
  StrongEmphasis: "cm-lp-strong",
  Emphasis: "cm-lp-em",
  InlineCode: "cm-lp-code",
  Strikethrough: "cm-lp-strike",
};

/** Inline mark tokens hidden when off the active line. */
const HIDE_MARKS = new Set(["EmphasisMark", "CodeMark", "StrikethroughMark", "QuoteMark"]);

const hidden = Decoration.replace({});

// --- widgets -----------------------------------------------------------------

class MathWidget extends WidgetType {
  constructor(readonly tex: string, readonly display: boolean) { super(); }
  eq(o: MathWidget): boolean { return o.tex === this.tex && o.display === this.display; }
  toDOM(): HTMLElement {
    const el = document.createElement(this.display ? "div" : "span");
    el.className = this.display ? "cm-lp-mathblock" : "cm-lp-mathinline";
    el.innerHTML = tex2svg(this.tex, this.display);
    return el;
  }
  ignoreEvent(): boolean { return false; }
}

class ImageWidget extends WidgetType {
  readonly src: string;
  constructor(
    readonly ref: string,
    readonly width: number | undefined,
    readonly alt: string,
    readonly embed: boolean,   // ![[ref|W]] embeds carry data-ref → drag-resizable
  ) {
    super();
    this.src = imgSrc(ref);    // resolved here so it tracks base-path changes via eq()
  }
  eq(o: ImageWidget): boolean {
    return o.src === this.src && o.width === this.width && o.embed === this.embed;
  }
  toDOM(): HTMLElement {
    const img = document.createElement("img");
    img.className = "cm-lp-img";
    img.src = this.src;
    img.alt = this.alt;
    if (this.width) img.style.width = `${this.width}px`;
    if (this.embed) img.setAttribute("data-ref", this.ref); // enables drag-to-resize
    return img;
  }
}

class WikiWidget extends WidgetType {
  constructor(readonly target: string, readonly label: string, readonly broken: boolean) { super(); }
  eq(o: WikiWidget): boolean {
    return o.target === this.target && o.label === this.label && o.broken === this.broken;
  }
  toDOM(): HTMLElement {
    const a = document.createElement("span");
    a.className = "cm-lp-wikilink" + (this.broken ? " cm-lp-wikilink-broken" : "");
    a.textContent = this.label;
    a.setAttribute("data-target", this.target);
    a.title = this.broken ? `找不到筆記：${this.target}` : this.target;
    return a;
  }
  ignoreEvent(): boolean { return true; }
}

class CheckboxWidget extends WidgetType {
  constructor(readonly checked: boolean) { super(); }
  eq(o: CheckboxWidget): boolean { return o.checked === this.checked; }
  toDOM(): HTMLElement {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.className = "cm-lp-task";
    box.checked = this.checked;
    return box;
  }
  ignoreEvent(): boolean { return false; }
}

class TableWidget extends WidgetType {
  constructor(readonly md: string) { super(); }
  eq(o: TableWidget): boolean { return o.md === this.md; }
  toDOM(): HTMLElement {
    const div = document.createElement("div");
    div.className = "cm-lp-table";
    div.innerHTML = renderTableHtml(this.md);
    return div;
  }
}

/** Minimal GFM table → HTML (header row, separator, body rows). */
function renderTableHtml(md: string): string {
  const lines = md.split("\n").filter((l) => l.trim().startsWith("|") || l.includes("|"));
  if (lines.length < 2) return escapeHtml(md);
  const cells = (l: string): string[] =>
    l.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim());
  const header = cells(lines[0]!);
  const body = lines.slice(2).map(cells);
  const th = header.map((c) => `<th>${inlineMd(c)}</th>`).join("");
  const rows = body
    .map((r) => `<tr>${header.map((_, i) => `<td>${inlineMd(r[i] ?? "")}</td>`).join("")}</tr>`)
    .join("");
  return `<table><thead><tr>${th}</tr></thead><tbody>${rows}</tbody></table>`;
}

/** Tiny inline-markdown renderer for table cells (bold/italic/code only). */
function inlineMd(s: string): string {
  return escapeHtml(s)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/`([^`]+)`/g, "<code>$1</code>");
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// --- decoration building -----------------------------------------------------

/** 1-based line numbers the selection touches — revealed as raw source. */
function activeLineSet(state: EditorState): Set<number> {
  const set = new Set<number>();
  const doc = state.doc;
  for (const r of state.selection.ranges) {
    const first = doc.lineAt(r.from).number;
    const last = doc.lineAt(r.to).number;
    for (let n = first; n <= last; n++) set.add(n);
  }
  return set;
}

interface ReplaceCand { from: number; to: number; deco: Decoration; prio: number; }

function buildDecorations(state: EditorState): DecorationSet {
  if (state.doc.length > MAX_LEN) return Decoration.none;

  const doc = state.doc;
  const active = activeLineSet(state);
  const tree = syntaxTree(state);

  const marks: Range<Decoration>[] = [];      // line + mark decos (never overlap-filtered)
  const replaces: ReplaceCand[] = [];          // replace decos (overlap-filtered)
  const skip: Array<[number, number]> = [];    // code/table ranges → regex passes skip these
  const lineActive = (from: number, to: number): boolean => {
    const a = doc.lineAt(from).number, b = doc.lineAt(to).number;
    for (let n = a; n <= b; n++) if (active.has(n)) return true;
    return false;
  };

  tree.iterate({
    enter: (node) => {
      const name = node.name;

      const level = HEADING_LEVEL[name];
      if (level) {
        marks.push(Decoration.line({ attributes: { class: `cm-lp-h cm-lp-h${level}` } })
          .range(doc.lineAt(node.from).from));
        return;
      }

      const cc = CONTENT_CLASS[name];
      if (cc && node.to > node.from) {
        marks.push(Decoration.mark({ class: cc }).range(node.from, node.to));
        // InlineCode also counts as a skip range for the regex passes.
        if (name === "InlineCode") skip.push([node.from, node.to]);
        return;
      }

      if (name === "HeaderMark" || HIDE_MARKS.has(name)) {
        if (lineActive(node.from, node.to)) return;
        let end = node.to;
        if (name === "HeaderMark" && doc.sliceString(end, end + 1) === " ") end += 1;
        if (end > node.from) replaces.push({ from: node.from, to: end, deco: hidden, prio: 1 });
        return;
      }

      if (name === "TaskMarker") {
        if (lineActive(node.from, node.to)) return;
        const checked = /x/i.test(doc.sliceString(node.from, node.to));
        replaces.push({
          from: node.from, to: node.to,
          deco: Decoration.replace({ widget: new CheckboxWidget(checked) }), prio: 2,
        });
        return;
      }

      if (name === "FencedCode" || name === "CodeBlock") {
        skip.push([node.from, node.to]);
        const a = doc.lineAt(node.from).number, b = doc.lineAt(node.to).number;
        for (let n = a; n <= b; n++) {
          marks.push(Decoration.line({ attributes: { class: "cm-lp-codeblock" } }).range(doc.line(n).from));
        }
        return;
      }

      if (name === "Blockquote") {
        const a = doc.lineAt(node.from).number, b = doc.lineAt(node.to).number;
        const firstText = doc.line(a).text;
        const callout = /^\s*>+\s*\[!(\w+)\]/.exec(firstText);
        for (let n = a; n <= b; n++) {
          const klass = callout ? "cm-lp-quote cm-lp-callout" : "cm-lp-quote";
          marks.push(Decoration.line({ attributes: { class: klass } }).range(doc.line(n).from));
        }
        return; // descend manually below by not returning? we still want inner marks
      }

      if (name === "Table") {
        skip.push([node.from, node.to]);
        const first = doc.lineAt(node.from), last = doc.lineAt(node.to);
        if (!lineActive(node.from, node.to)) {
          replaces.push({
            from: first.from, to: last.to,
            deco: Decoration.replace({ widget: new TableWidget(doc.sliceString(first.from, last.to)), block: true }),
            prio: 5,
          });
        }
        return;
      }
    },
  });

  // --- regex passes for syntax the markdown tree doesn't model ---------------
  const text = doc.toString();
  const inSkip = (i: number): boolean => skip.some(([s, e]) => i >= s && i < e);

  // Block math $$ … $$ (may span lines).
  const blockMath: Array<[number, number]> = [];
  for (const m of text.matchAll(/\$\$([\s\S]+?)\$\$/g)) {
    const s = m.index!, e = s + m[0].length;
    if (inSkip(s)) continue;
    blockMath.push([s, e]);
    if (lineActive(s, e)) continue;
    const tex = m[1]!.trim();
    const first = doc.lineAt(s), last = doc.lineAt(e);
    const multiline = last.number > first.number;
    const standalone = first.text.trim() === m[0].trim();
    if (multiline || standalone) {
      replaces.push({
        from: first.from, to: last.to,
        deco: Decoration.replace({ widget: new MathWidget(tex, true), block: true }), prio: 5,
      });
    } else {
      replaces.push({ from: s, to: e, deco: Decoration.replace({ widget: new MathWidget(tex, true) }), prio: 4 });
    }
  }
  const inBlockMath = (i: number): boolean => blockMath.some(([s, e]) => i >= s && i < e);

  // Inline math $ … $ (single line, not $$).
  for (const m of text.matchAll(/(?<![\\$])\$([^$\n]+?)\$(?!\$)/g)) {
    const s = m.index!, e = s + m[0].length;
    if (inSkip(s) || inBlockMath(s) || lineActive(s, e)) continue;
    replaces.push({ from: s, to: e, deco: Decoration.replace({ widget: new MathWidget(m[1]!.trim(), false) }), prio: 4 });
  }

  // Embedded images ![[file|width]] (image extensions only).
  const IMG_EXT = /\.(png|jpe?g|gif|svg|webp|bmp|tiff?)$/i;
  for (const m of text.matchAll(/!\[\[([^\]\n|]+?)(?:\|(\d+))?\]\]/g)) {
    const s = m.index!, e = s + m[0].length;
    const ref = m[1]!.trim();
    if (inSkip(s) || !IMG_EXT.test(ref) || lineActive(s, e)) continue;
    const w = m[2] ? Number(m[2]) : undefined;
    const standalone = doc.lineAt(s).text.trim() === m[0].trim();
    replaces.push({
      from: s, to: e,
      deco: Decoration.replace({ widget: new ImageWidget(ref, w, ref, true), ...(standalone ? { block: true } : {}) }),
      prio: standalone ? 5 : 4,
    });
  }

  // Standard images ![alt](url).
  for (const m of text.matchAll(/!\[([^\]\n]*)\]\(([^)\n]+)\)/g)) {
    const s = m.index!, e = s + m[0].length;
    if (inSkip(s) || lineActive(s, e)) continue;
    const standalone = doc.lineAt(s).text.trim() === m[0].trim();
    replaces.push({
      from: s, to: e,
      deco: Decoration.replace({ widget: new ImageWidget(m[2]!.trim(), undefined, m[1] ?? "", false), ...(standalone ? { block: true } : {}) }),
      prio: standalone ? 5 : 4,
    });
  }

  // Wikilinks [[target|alias]] (not preceded by '!', which is an embed).
  for (const m of text.matchAll(/(?<!!)\[\[([^\]\n|]+?)(?:\|([^\]\n]+?))?\]\]/g)) {
    const s = m.index!, e = s + m[0].length;
    if (inSkip(s) || lineActive(s, e)) continue;
    const target = m[1]!.trim();
    const label = (m[2] ?? m[1])!.trim();
    replaces.push({
      from: s, to: e,
      deco: Decoration.replace({ widget: new WikiWidget(target, label, !noteExists(target)) }), prio: 3,
    });
  }

  // --- resolve overlaps among replace decorations ---------------------------
  replaces.sort((a, b) => a.from - b.from || b.to - a.to || b.prio - a.prio);
  const all: Range<Decoration>[] = [...marks];
  let lastEnd = -1;
  for (const r of replaces) {
    if (r.from < lastEnd) continue;          // overlaps a kept replace → drop
    all.push(r.deco.range(r.from, r.to));
    lastEnd = r.to;
  }
  return Decoration.set(all, true);
}

// --- state field + interaction -----------------------------------------------

/** Dispatch this effect to force a rebuild (e.g. after vault base paths change,
 * so image widgets re-resolve their npimg:// src). */
export const refreshLivePreview = StateEffect.define<void>();

function activeKey(state: EditorState): string {
  return [...activeLineSet(state)].sort((a, b) => a - b).join(",");
}

/** Field value carries the active-line key its decorations were built for, so
 * a selection-only transaction that stays on the same line(s) — the most
 * common cursor movement — skips the whole-doc rebuild. (Stored in the field
 * value, not module state: each editor instance has its own field.) */
interface LP { deco: DecorationSet; key: string }

const livePreviewField = StateField.define<LP>({
  create: (state) => ({ deco: buildDecorations(state), key: activeKey(state) }),
  update(value, tr) {
    const forced = tr.effects.some((e) => e.is(refreshLivePreview));
    if (tr.docChanged || forced) {
      return { deco: buildDecorations(tr.state), key: activeKey(tr.state) };
    }
    if (tr.selection) {
      const key = activeKey(tr.state);
      if (key === value.key) return value;   // same lines touched → reuse
      return { deco: buildDecorations(tr.state), key };
    }
    return value;
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.deco),
});

function postToHost(msg: unknown): void {
  (window as unknown as {
    webkit?: { messageHandlers?: { notepro?: { postMessage(m: unknown): void } } };
  }).webkit?.messageHandlers?.notepro?.postMessage(msg);
}

/** Clicks on rendered wikilink pills open the note; checkbox toggles the source. */
const livePreviewEvents = EditorView.domEventHandlers({
  mousedown(e, view) {
    const t = e.target as HTMLElement;
    const wiki = t.closest(".cm-lp-wikilink") as HTMLElement | null;
    if (wiki) {
      const target = wiki.getAttribute("data-target");
      if (target) { e.preventDefault(); postToHost({ type: "openLink", target }); }
      return true;
    }
    if (t instanceof HTMLInputElement && t.classList.contains("cm-lp-task")) {
      const pos = view.posAtDOM(t);
      const cur = view.state.doc.sliceString(pos, pos + 3);
      const m = /^\[( |x|X)\]$/.exec(cur);
      if (m) {
        e.preventDefault();
        const next = m[1] === " " ? "[x]" : "[ ]";
        view.dispatch({ changes: { from: pos, to: pos + 3, insert: next } });
      }
      return true;
    }
    return false;
  },
});

const livePreviewTheme = EditorView.theme({
  ".cm-lp-strong": { fontWeight: "700" },
  ".cm-lp-em": { fontStyle: "italic" },
  ".cm-lp-strike": { textDecoration: "line-through", opacity: "0.7" },
  ".cm-lp-code": {
    fontFamily: "ui-monospace, Menlo, monospace",
    backgroundColor: "rgba(135,150,180,0.18)",
    borderRadius: "3px",
    padding: "0 3px",
  },
  ".cm-lp-h": { lineHeight: "1.35" },
  ".cm-lp-h1": { fontSize: "1.9em", fontWeight: "700" },
  ".cm-lp-h2": { fontSize: "1.55em", fontWeight: "700" },
  ".cm-lp-h3": { fontSize: "1.3em", fontWeight: "700" },
  ".cm-lp-h4": { fontSize: "1.15em", fontWeight: "700" },
  ".cm-lp-h5": { fontSize: "1.05em", fontWeight: "700" },
  ".cm-lp-h6": { fontSize: "1.0em", fontWeight: "700", opacity: "0.85" },

  ".cm-lp-mathinline": { display: "inline-block", verticalAlign: "middle" },
  ".cm-lp-mathblock": { display: "block", textAlign: "center", margin: "0.4em 0" },

  ".cm-lp-img": { maxWidth: "100%", borderRadius: "4px", verticalAlign: "middle" },

  ".cm-lp-wikilink": {
    color: "#a78bfa", cursor: "pointer", borderBottom: "1px solid rgba(167,139,250,0.5)",
  },
  ".cm-lp-wikilink-broken": { color: "#f08", borderBottom: "1px dashed rgba(255,0,136,0.5)" },

  ".cm-lp-task": { marginRight: "4px", verticalAlign: "middle", cursor: "pointer" },

  ".cm-lp-quote": {
    borderLeft: "3px solid rgba(135,150,180,0.5)",
    paddingLeft: "12px",
    color: "rgba(180,190,205,0.95)",
  },
  ".cm-lp-callout": {
    borderLeftColor: "#5b9bff",
    backgroundColor: "rgba(91,155,255,0.08)",
  },

  ".cm-lp-codeblock": { backgroundColor: "rgba(135,150,180,0.10)" },

  ".cm-lp-table": { margin: "0.4em 0", overflowX: "auto" },
  ".cm-lp-table table": { borderCollapse: "collapse" },
  ".cm-lp-table th, .cm-lp-table td": {
    border: "1px solid rgba(135,150,180,0.4)", padding: "4px 9px",
  },
  ".cm-lp-table th": { backgroundColor: "rgba(135,150,180,0.15)" },
});

/** The inline live-preview extension (decorations + interaction + theme). */
export const livePreview: Extension = [livePreviewField, livePreviewEvents, livePreviewTheme];
