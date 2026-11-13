/**
 * syntaxColors.ts — richer colouring of the editor SOURCE, so the parts of a
 * paper you edit most read apart at a glance:
 *
 *   heading   `# …` lines (Markdown) / `\section{…}` (LaTeX)        amber
 *   math      `$…$`, `$$…$$`, `\[…\]`, `\(…\)`, equation/align …   cyan
 *   cmd       LaTeX commands (`\frac`, `\alpha`, `\textbf` …)       purple
 *   cite      `[@key]`, `[@a; @b, p. 3]`, `\citep{…}` …             green
 *   link      `[[wikilinks]]`, `![[embeds]]`, `\ref{…}` / `\eqref` blue
 *   fence     ``` code fences (marker lines dimmed, body gets an accent bar)
 *
 * Display only: this module never changes the document — it is a ViewPlugin
 * that adds mark/line decorations, nothing more. Text inside code spans,
 * fences, front matter and comments is never coloured.
 *
 * The cite/link rules deliberately mirror the converter (`latex/parser.ts`'s
 * INLINE_TOKEN + parseCitation), so what shows green is exactly what the
 * Markdown→LaTeX export turns into `\cite`. A test keeps the two in step.
 */
import {
  EditorView, ViewPlugin, Decoration, type DecorationSet, type ViewUpdate,
} from "@codemirror/view";
import type { Extension, Range } from "@codemirror/state";

export type SynMode = "markdown" | "latex";
export type SynKind =
  | "heading" | "headingMark"
  | "math" | "mathDelim"
  | "cmd" | "cite" | "link"
  | "fence" | "fenceBody";

export interface SynSpan { from: number; to: number; kind: SynKind }

/** Environments whose body is math (coloured like `$…$`). */
const MATH_ENV = /^(?:equation|align|alignat|gather|multline|flalign|eqnarray|displaymath|math|split|aligned|gathered|cases)\*?$/;
/** Environments whose body is verbatim (never coloured). */
const VERBATIM_ENV = /^(?:verbatim|lstlisting|minted|comment|Verbatim)\*?$/;

/** Same shape as the converter's INLINE_TOKEN: embed, wikilink, citation group. */
const MD_INLINE = /(!\[\[[^\]\n]+\]\])|(\[\[[^\]\n]+\]\])|(\[[^\]\[\n]*@[^\]\n]*\])/g;
/** A citation group needs at least one `@key` (see parser.ts parseCitation). */
const CITE_ITEM = /@[^\s,\]]/;
const TEX_CITE = /\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]\n]*\])*\{[^{}\n]*\}/g;
const TEX_REF = /\\(?:eq|c|C|auto|page|name|v|f)?ref\*?\{[^{}\n]*\}/g;
const TEX_HEADING =
  /\\(?:part|chapter|section|subsection|subsubsection|paragraph|subparagraph)\*?(?:\[[^\]\n]*\])?\{[^{}\n]*(?:\{[^{}\n]*\}[^{}\n]*)*\}/g;
const TEX_CMD = /\\(?:[a-zA-Z@]+\*?|[^a-zA-Z\s])/g;

/**
 * Classify the source into coloured spans. Pure (no DOM), so it is unit-tested
 * directly. Spans may nest (a `\frac` cmd inside a math span, a cite inside a
 * heading); they never cross code/comment regions.
 */
export function scanSyntax(doc: string, mode: SynMode): SynSpan[] {
  const len = doc.length;
  const out: SynSpan[] = [];
  /** 1 = code / comment / front matter: nothing inside is coloured. */
  const skip = new Uint8Array(len);
  /** 1 = math body, 2 = math delimiter. */
  const math = new Uint8Array(len);
  /** Already claimed by a cite/link/heading command (no separate cmd colour). */
  const taken = new Uint8Array(len);

  const push = (from: number, to: number, kind: SynKind): void => {
    if (to > from || kind === "fenceBody") out.push({ from, to, kind });
  };
  const anySkip = (a: number, b: number): boolean => {
    for (let k = a; k < b; k++) if (skip[k]) return true;
    return false;
  };
  const anyMath = (a: number, b: number): boolean => {
    for (let k = a; k < b; k++) if (math[k]) return true;
    return false;
  };

  if (mode === "markdown") markdownBlocks(doc, out, skip, push);
  else latexSkips(doc, skip);

  // --- math -----------------------------------------------------------------
  /** Next unescaped, unskipped occurrence of `pat` at/after `from`, or -1.
   * `sameLine` stops at the first newline. */
  const findClose = (from: number, pat: string, sameLine: boolean): number => {
    for (let j = from; j < len; j++) {
      if (sameLine && doc[j] === "\n") return -1;
      if (skip[j]) continue;
      if (doc[j] === "\\" && pat[0] !== "\\") { j++; continue; }
      if (doc.startsWith(pat, j)) return j;
    }
    return -1;
  };
  const region = (open: number, bodyFrom: number, bodyTo: number, closeTo: number): void => {
    push(open, bodyFrom, "mathDelim");
    push(bodyFrom, bodyTo, "math");
    push(bodyTo, closeTo, "mathDelim");
    math.fill(2, open, bodyFrom);
    math.fill(1, bodyFrom, bodyTo);
    math.fill(2, bodyTo, closeTo);
  };

  for (let i = 0; i < len; i++) {
    if (skip[i]) continue;
    const c = doc[i];
    if (c === "\\") {
      const nx = doc[i + 1];
      // `\[ … \]` (both modes — the converter passes it through as display
      // math), `\( … \)` (LaTeX only: in Markdown `\(` is just an escape).
      if (nx === "[" || (nx === "(" && mode === "latex")) {
        const closer = nx === "[" ? "\\]" : "\\)";
        const j = findClose(i + 2, closer, false);
        if (j !== -1) { region(i, i + 2, j, j + 2); i = j + 1; continue; }
      }
      if (doc.startsWith("\\begin{", i)) {
        const m = /^\\begin\{([a-zA-Z*]+)\}/.exec(doc.slice(i, i + 40));
        if (m && MATH_ENV.test(m[1]!)) {
          const end = `\\end{${m[1]}}`;
          const bodyFrom = i + m[0].length;
          const j = doc.indexOf(end, bodyFrom);
          if (j !== -1 && !anySkip(bodyFrom, j)) {
            region(i, bodyFrom, j, j + end.length);
            i = j + end.length - 1;
            continue;
          }
        }
      }
      i++;                                   // escape: skip the next char
      continue;
    }
    if (c === "$") {
      if (doc[i + 1] === "$") {
        const j = findClose(i + 2, "$$", false);
        if (j !== -1 && j > i + 2) { region(i, i + 2, j, j + 2); i = j + 1; continue; }
        i++;
        continue;
      }
      const j = findClose(i + 1, "$", true);
      if (j !== -1 && j > i + 1) { region(i, i + 1, j, j + 1); i = j; continue; }
    }
  }

  // --- cites / links / LaTeX headings ---------------------------------------
  const claim = (from: number, to: number, kind: SynKind): void => {
    push(from, to, kind);
    taken.fill(1, from, to);
  };

  if (mode === "markdown") {
    for (const m of doc.matchAll(MD_INLINE)) {
      const s = m.index!, e = s + m[0].length;
      if (anySkip(s, e) || anyMath(s, e)) continue;
      if (m[3] !== undefined) {
        if (CITE_ITEM.test(m[3].slice(1, -1))) claim(s, e, "cite");
      } else {
        claim(s, e, "link");
      }
    }
  } else {
    for (const m of doc.matchAll(TEX_HEADING)) {
      const s = m.index!, e = s + m[0].length;
      if (!skip[s]) claim(s, e, "heading");
    }
  }
  for (const m of doc.matchAll(TEX_CITE)) {
    const s = m.index!, e = s + m[0].length;
    if (!anySkip(s, e) && !taken[s]) claim(s, e, "cite");
  }
  for (const m of doc.matchAll(TEX_REF)) {
    const s = m.index!, e = s + m[0].length;
    if (!anySkip(s, e) && !taken[s]) claim(s, e, "link");
  }

  // --- LaTeX commands -------------------------------------------------------
  // In Markdown: every `\name` (they are LaTeX passthrough), plus symbol
  // commands like `\,` `\{` inside math only (outside math they're Markdown
  // escapes). In LaTeX the stex grammar already colours commands, so only
  // math bodies get ours — for one consistent look inside equations.
  for (const m of doc.matchAll(TEX_CMD)) {
    const s = m.index!, e = s + m[0].length;
    if (skip[s] || taken[s] || math[s] === 2) continue;
    const inMath = math[s] === 1;
    const symbol = !/[a-zA-Z]/.test(m[0][1] ?? "");
    if (!inMath && (mode === "latex" || symbol)) continue;
    push(s, e, "cmd");
  }

  out.sort((a, b) => a.from - b.from || b.to - a.to);
  return out;
}

/** Markdown block structure: front matter, fenced code, ATX headings, inline
 * code spans and comments (`<!-- -->`, Obsidian `%% %%`). */
function markdownBlocks(
  doc: string, out: SynSpan[], skip: Uint8Array,
  push: (from: number, to: number, kind: SynKind) => void,
): void {
  const len = doc.length;
  let pos = 0;
  let lineNo = 0;
  let fence: { ch: string; n: number } | null = null;
  let front = false;
  const lines: Array<[number, number]> = [];       // non-skipped lines → inline code pass
  while (pos <= len) {
    let eol = doc.indexOf("\n", pos);
    if (eol === -1) eol = len;
    const line = doc.slice(pos, eol);
    if (lineNo === 0 && /^---[ \t]*$/.test(line)) {
      front = true;
      skip.fill(1, pos, eol);
    } else if (front) {
      skip.fill(1, pos, eol);
      if (/^(?:---|\.\.\.)[ \t]*$/.test(line)) front = false;
    } else if (fence) {
      const m = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line);
      if (m && m[1]![0] === fence.ch && m[1]!.length >= fence.n) {
        push(pos + line.length - line.trimStart().length, eol, "fence");
        fence = null;
      } else {
        push(pos, eol, "fenceBody");
      }
      skip.fill(1, pos, eol);
    } else {
      const f = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
      if (f && !(f[2]![0] === "`" && f[3]!.includes("`"))) {
        fence = { ch: f[2]![0]!, n: f[2]!.length };
        push(pos + f[1]!.length, eol, "fence");
        skip.fill(1, pos, eol);
      } else {
        const h = /^( {0,3})(#{1,6})(?=[ \t]|$)/.exec(line);
        if (h) {
          const s = pos + h[1]!.length;
          push(s, s + h[2]!.length, "headingMark");
          push(s + h[2]!.length, pos + line.trimEnd().length, "heading");
        }
        lines.push([pos, eol]);
      }
    }
    if (eol === len) break;
    pos = eol + 1;
    lineNo++;
  }

  // Inline code: a run of N backticks closes at the next run of exactly N.
  for (const [start, end] of lines) {
    let j = start;
    while (j < end) {
      if (doc[j] === "\\") { j += 2; continue; }
      if (doc[j] !== "`") { j++; continue; }
      let k = j;
      while (k < end && doc[k] === "`") k++;
      const n = k - j;
      let c = k, found = -1;
      while (c < end) {
        if (doc[c] !== "`") { c++; continue; }
        let d = c;
        while (d < end && doc[d] === "`") d++;
        if (d - c === n) { found = c; break; }
        c = d;
      }
      if (found === -1) { j = k; continue; }
      skip.fill(1, j, found + n);
      j = found + n;
    }
  }

  // Comments (may span lines).
  for (const re of [/<!--[\s\S]*?-->/g, /%%[\s\S]*?%%/g]) {
    for (const m of doc.matchAll(re)) {
      if (!skip[m.index!]) skip.fill(1, m.index!, m.index! + m[0].length);
    }
  }
}

/** LaTeX regions never coloured: verbatim environments, `\verb|…|`, `%` comments. */
function latexSkips(doc: string, skip: Uint8Array): void {
  const len = doc.length;
  for (const m of doc.matchAll(/\\begin\{([a-zA-Z*]+)\}/g)) {
    if (!VERBATIM_ENV.test(m[1]!) || skip[m.index!]) continue;
    const end = `\\end{${m[1]}}`;
    const j = doc.indexOf(end, m.index! + m[0].length);
    skip.fill(1, m.index!, j === -1 ? len : j + end.length);
  }
  for (const m of doc.matchAll(/\\verb\*?([^a-zA-Z\s*])/g)) {
    if (skip[m.index!]) continue;
    const close = doc.indexOf(m[1]!, m.index! + m[0].length);
    const eol = doc.indexOf("\n", m.index!);
    const stop = close === -1 || (eol !== -1 && close > eol) ? (eol === -1 ? len : eol) : close + 1;
    skip.fill(1, m.index!, stop);
  }
  for (let i = 0; i < len; i++) {
    if (skip[i] || doc[i] !== "%") continue;
    let bs = 0;
    for (let k = i - 1; k >= 0 && doc[k] === "\\"; k--) bs++;
    if (bs % 2 === 1) continue;                     // `\%` is a literal percent
    let eol = doc.indexOf("\n", i);
    if (eol === -1) eol = len;
    skip.fill(1, i, eol);
    i = eol;
  }
}

// --- CodeMirror extension ------------------------------------------------------

/** Docs bigger than this skip colouring (the scan runs on every edit). */
const MAX_LEN = 2_000_000;

const MARK: Record<Exclude<SynKind, "fenceBody">, Decoration> = {
  heading: Decoration.mark({ class: "np-syn-heading" }),
  headingMark: Decoration.mark({ class: "np-syn-heading np-syn-headingMark" }),
  math: Decoration.mark({ class: "np-syn-math" }),
  mathDelim: Decoration.mark({ class: "np-syn-math np-syn-mathDelim" }),
  cmd: Decoration.mark({ class: "np-syn-cmd" }),
  cite: Decoration.mark({ class: "np-syn-cite" }),
  link: Decoration.mark({ class: "np-syn-link" }),
  fence: Decoration.mark({ class: "np-syn-fence" }),
};
const FENCE_LINE = Decoration.line({ class: "np-syn-fenceLine" });

interface ModeRef { get(): SynMode }

function syntaxPlugin(modeRef: ModeRef) {
  return ViewPlugin.fromClass(class {
    spans: SynSpan[];
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.spans = this.scan(view);
      this.decorations = this.build(view);
    }
    update(u: ViewUpdate): void {
      // `reconfigured` covers the md ⇄ tex switch (language compartment swap).
      const rescan = u.docChanged || u.transactions.some((tr) => tr.reconfigured);
      if (rescan) this.spans = this.scan(u.view);
      if (rescan || u.viewportChanged) this.decorations = this.build(u.view);
    }
    scan(view: EditorView): SynSpan[] {
      if (view.state.doc.length > MAX_LEN) return [];
      return scanSyntax(view.state.doc.toString(), modeRef.get());
    }
    /** Only decorate what's on screen — a long paper has thousands of spans. */
    build(view: EditorView): DecorationSet {
      const out: Range<Decoration>[] = [];
      const doc = view.state.doc;
      for (const { from, to } of view.visibleRanges) {
        for (const s of this.spans) {
          if (s.kind === "fenceBody") {
            // Line decoration: empty body lines (from === to) count too.
            if (s.from >= from && s.from <= to) out.push(FENCE_LINE.range(doc.lineAt(s.from).from));
            continue;
          }
          // Clip to the visible range; a span merely touching its edge would
          // clip to an empty mark, which CodeMirror rejects (crashes the plugin).
          const a = Math.max(s.from, from), b = Math.min(s.to, to);
          if (a < b) out.push(MARK[s.kind].range(a, b));
        }
      }
      return Decoration.set(out, true);
    }
  }, { decorations: (v) => v.decorations });
}

/**
 * Colours (light / dark). `&light` / `&dark` follow the editor theme the
 * native shell sets via `notepro.setTheme`. The `*` selectors make our colour
 * win over the language highlighter's token spans nested inside a mark; a
 * nested `np-syn-cmd` inside math is declared later, so it wins over math.
 * Rendered Live Preview widgets inside a span (inline math SVG, wikilink
 * pills) keep their own look.
 */
const C = {
  light: {
    heading: "#b45309", math: "#0e7490", cmd: "#7e22ce", cite: "#15803d",
    citeBg: "rgba(21,128,61,0.09)", link: "#1d4ed8", fence: "#6b7280",
    fenceBar: "rgba(107,114,128,0.45)", fg: "#1d1f23",
  },
  dark: {
    heading: "#e5c07b", math: "#56b6c2", cmd: "#c678dd", cite: "#98c379",
    citeBg: "rgba(152,195,121,0.13)", link: "#61afef", fence: "#7f848e",
    fenceBar: "rgba(127,132,142,0.55)", fg: "#abb2bf",
  },
} as const;

function themeSpec(): Record<string, Record<string, string>> {
  const spec: Record<string, Record<string, string>> = {
    ".np-syn-heading": { fontWeight: "700" },
    ".np-syn-headingMark": { opacity: "0.55" },
    ".np-syn-mathDelim": { opacity: "0.65" },
    ".np-syn-cite": { borderRadius: "3px" },
    ".np-syn-link": { textDecoration: "underline dotted", textUnderlineOffset: "2px" },
    ".np-syn-fence": { opacity: "0.85" },
  };
  // Widget DOM (Live Preview pills, rendered math) is contenteditable=false —
  // the descendant rule skips it so widgets keep their own colours. Wrapped in
  // :where() so it adds no specificity — otherwise an outer span's `*` rule
  // would beat a nested span's own colour (math inside a heading, cmd in math).
  const NOT_WIDGET = `:where(:not([contenteditable="false"]):not([contenteditable="false"] *))`;
  for (const t of ["light", "dark"] as const) {
    const c = C[t];
    const sel = (cls: string): string => `&${t} .${cls}, &${t} .${cls} *${NOT_WIDGET}`;
    spec[sel("np-syn-heading")] = { color: c.heading };
    spec[sel("np-syn-math")] = { color: c.math };
    spec[sel("np-syn-cite")] = { color: c.cite };
    spec[`&${t} .np-syn-cite`] = { color: c.cite, backgroundColor: c.citeBg };
    spec[sel("np-syn-link")] = { color: c.link };
    spec[sel("np-syn-fence")] = { color: c.fence };
    spec[sel("np-syn-cmd")] = { color: c.cmd };          // after math → wins inside it
    spec[`&${t} .np-syn-fenceLine`] = { boxShadow: `inset 3px 0 0 ${c.fenceBar}` };
    // Live Preview widgets keep their normal look when they sit inside a span.
    spec[`&${t} .np-syn-math .cm-lp-mathinline`] = { color: c.fg };
  }
  return spec;
}

const syntaxTheme = EditorView.baseTheme(themeSpec());

/** The extension: colour spans + theme. `modeRef` reports md vs tex. */
export function syntaxColors(modeRef: ModeRef): Extension {
  return [syntaxPlugin(modeRef), syntaxTheme];
}
