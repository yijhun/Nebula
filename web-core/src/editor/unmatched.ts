/**
 * unmatched.ts — paint a red background on every bracket character that has
 * no partner. Updates on every doc change, so feedback is instant (unlike
 * the lint pipeline, which is debounced 500ms).
 *
 * Scope:
 *   • `$` is checked in BOTH Markdown and LaTeX modes (unclosed inline math
 *     is the single most common cause of "Missing $ inserted" at compile).
 *   • `{}`, `()`, `[]` are checked only in LaTeX mode — in prose Markdown,
 *     stray `{` in text or code spans would false-positive.
 *
 * Skips:
 *   • Backslash escapes (`\{`, `\$`, `\\` …).
 *   • Markdown fenced code blocks (``` … ```).
 *   • Inline backticks on the same line (`{not flagged}`).
 *   • LaTeX `\verb|…|` runs.
 */
import { EditorView, ViewPlugin, Decoration, DecorationSet, ViewUpdate } from "@codemirror/view";
import { RangeSetBuilder } from "@codemirror/state";

const UNMATCHED = Decoration.mark({ class: "np-unmatched-bracket" });

type Mode = "markdown" | "latex";

interface ModeRef { get(): Mode }

function scanUnmatched(doc: string, mode: Mode): number[] {
  const out: number[] = [];
  const len = doc.length;

  // Pass 1: figure out which character offsets to ignore (code fences,
  // inline-code spans, \verb|...|, escaped chars).
  const skip = new Uint8Array(len);
  let inFence = false;
  let lineStart = 0;
  for (let i = 0; i <= len; i++) {
    if (i === len || doc[i] === "\n") {
      // detect ``` fences on the line we just finished
      const line = doc.slice(lineStart, i);
      if (/^\s*```/.test(line)) inFence = !inFence;
      // if we ENTERED a fence on this line, the line's content is already in,
      // we want to skip subsequent lines until the closing fence
      if (inFence) for (let k = lineStart; k < i; k++) skip[k] = 1;
      lineStart = i + 1;
      continue;
    }
  }
  // close out fence-pending region (unterminated fence): the trailing
  // skipped region was already set above as we iterated.

  // inline-code: per-line, toggle on each unescaped backtick
  for (let i = 0; i < len; ) {
    const eol = doc.indexOf("\n", i);
    const end = eol === -1 ? len : eol;
    if (!skip[i]) {
      let inCode = false, codeStart = -1;
      for (let j = i; j < end; j++) {
        if (doc[j] === "\\" && j + 1 < end) { skip[j] = 1; skip[j + 1] = 1; j++; continue; }
        if (doc[j] === "`") {
          if (inCode) { for (let k = codeStart; k <= j; k++) skip[k] = 1; inCode = false; }
          else { inCode = true; codeStart = j; }
        }
      }
    }
    i = end + 1;
  }

  // LaTeX \verb|...|
  if (mode === "latex") {
    const verbRe = /\\verb([^a-zA-Z\s])/g;
    let m: RegExpExecArray | null;
    while ((m = verbRe.exec(doc))) {
      const delim = m[1]!;
      const start = m.index;
      const close = doc.indexOf(delim, m.index + m[0].length);
      const stop = close === -1 ? doc.length : close + 1;
      for (let k = start; k < stop; k++) skip[k] = 1;
    }
  }

  // Pass 2: $ balance (line-scoped for single $; document-scoped for $$)
  let inInline = -1;       // -1 = not in, else = open-$ offset
  let inDisplay = -1;
  for (let i = 0; i < len; i++) {
    if (skip[i]) continue;
    const c = doc[i];
    if (c === "\\") { i++; continue; }
    if (c === "\n") {
      // unclosed inline math doesn't cross lines
      if (inInline !== -1 && inDisplay === -1) { out.push(inInline); inInline = -1; }
      continue;
    }
    if (c === "$") {
      const dbl = doc[i + 1] === "$";
      if (inDisplay !== -1) {
        if (dbl) { inDisplay = -1; i++; }
      } else if (inInline !== -1) {
        if (!dbl) inInline = -1;
      } else if (dbl) {
        inDisplay = i; i++;
      } else {
        inInline = i;
      }
    }
  }
  if (inInline !== -1) out.push(inInline);
  if (inDisplay !== -1) { out.push(inDisplay); out.push(inDisplay + 1); }

  // Pass 3: paired brackets (LaTeX mode only — Markdown prose has too many
  // legitimate stray braces in non-code contexts to flag safely).
  if (mode === "latex") {
    for (const [op, cl] of [["{", "}"], ["(", ")"], ["[", "]"]] as const) {
      const stack: number[] = [];
      for (let i = 0; i < len; i++) {
        if (skip[i]) continue;
        const c = doc[i];
        if (c === "\\") { i++; continue; }
        if (c === op) stack.push(i);
        else if (c === cl) {
          if (stack.length) stack.pop();
          else out.push(i);
        }
      }
      for (const p of stack) out.push(p);
    }
  }
  return out;
}

export function unmatchedBrackets(modeRef: ModeRef) {
  return ViewPlugin.fromClass(class {
    decorations: DecorationSet;
    constructor(view: EditorView) { this.decorations = this.build(view); }
    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged) this.decorations = this.build(u.view);
    }
    build(view: EditorView): DecorationSet {
      const doc = view.state.doc.toString();
      const positions = scanUnmatched(doc, modeRef.get());
      const sorted = [...new Set(positions)].sort((a, b) => a - b);
      const builder = new RangeSetBuilder<Decoration>();
      for (const pos of sorted) {
        if (pos < 0 || pos >= doc.length) continue;
        builder.add(pos, pos + 1, UNMATCHED);
      }
      return builder.finish();
    }
  }, { decorations: v => v.decorations });
}
