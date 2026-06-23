/**
 * complete.ts — LaTeX command/snippet autocompletion (Tab to accept).
 *
 * Type a backslash command (e.g. `\beg`, `\frac`, `\al`) → a popup suggests
 * commands, environments (which expand to a full `\begin{…}…\end{…}` block via
 * linked `${env}` fields), and math symbols. Tab accepts; Enter/arrows also
 * work via the default completion keymap.
 */
import {
  autocompletion,
  snippetCompletion,
  acceptCompletion,
  type Completion,
  type CompletionContext,
  type CompletionResult,
} from "@codemirror/autocomplete";
import { keymap } from "@codemirror/view";
import { insertTab } from "@codemirror/commands";
import { call } from "./bridge.js";
import { getConfig } from "./config.js";
import { getNoteNames } from "./notes.js";
import { t } from "./i18n.js";

function snip(template: string, label: string, detail: string): Completion {
  return snippetCompletion(template, { label, type: "keyword", detail });
}

const ENVIRONMENTS = [
  "equation", "align", "gather", "multline", "cases",
  "matrix", "bmatrix", "pmatrix", "figure", "table", "tabular",
  "itemize", "enumerate", "description", "theorem", "lemma", "proof",
  "definition", "abstract", "center", "quote", "verbatim", "frame",
];

const SYMBOLS = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
  "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
  "tau", "phi", "chi", "psi", "omega",
  "Gamma", "Delta", "Theta", "Lambda", "Pi", "Sigma", "Phi", "Psi", "Omega",
  "sum", "prod", "int", "iint", "oint", "partial", "nabla", "infty",
  "cdot", "times", "div", "pm", "mp", "approx", "neq", "leq", "geq",
  "ll", "gg", "equiv", "propto", "rightarrow", "Rightarrow", "leftarrow",
  "Leftarrow", "leftrightarrow", "mapsto", "forall", "exists", "nexists",
  "in", "notin", "subset", "subseteq", "supset", "cup", "cap", "emptyset",
  "langle", "rangle", "hbar", "ell", "Re", "Im",
];

const OPTIONS: Completion[] = [
  ...ENVIRONMENTS.map((env) =>
    snip(`\\begin{${env}}\n\t\${}\n\\end{${env}}`, `\\begin{${env}}`, "environment"),
  ),
  snip("\\begin{${env}}\n\t${}\n\\end{${env}}", "\\begin{…}", "custom environment"),
  snip("\\section{${}}", "\\section", "section"),
  snip("\\subsection{${}}", "\\subsection", "subsection"),
  snip("\\subsubsection{${}}", "\\subsubsection", "subsubsection"),
  snip("\\textbf{${}}", "\\textbf", "bold"),
  snip("\\textit{${}}", "\\textit", "italic"),
  snip("\\emph{${}}", "\\emph", "emphasis"),
  snip("\\cite{${}}", "\\cite", "citation"),
  snip("\\autocite{${}}", "\\autocite", "citation"),
  snip("\\ref{${}}", "\\ref", "reference"),
  snip("\\eqref{${}}", "\\eqref", "equation ref"),
  snip("\\label{${}}", "\\label", "label"),
  snip("\\footnote{${}}", "\\footnote", "footnote"),
  snip("\\frac{${num}}{${den}}", "\\frac", "fraction"),
  snip("\\sqrt{${}}", "\\sqrt", "square root"),
  snip("\\hat{${}}", "\\hat", "hat"),
  snip("\\vec{${}}", "\\vec", "vector"),
  snip("\\includegraphics[width=\\linewidth]{${}}", "\\includegraphics", "image"),
  snip("\\item ", "\\item", "list item"),
  ...SYMBOLS.map((s) => ({ label: `\\${s}`, type: "constant", apply: `\\${s}` }) as Completion),
];

interface ZItem { citekey: string; title: string; authors: string; year: string; }

/** Inside `\cite{…}` / `\autocite{…}` (or markdown `[@…`), complete citekeys
 * from the Zotero library (via the native bridge). Async. */
const CITE_ARG = /\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{([^}]*)$/;
const MD_CITE = /[@]([^\]\s;,]*)$/;

async function citeKeyComplete(context: CompletionContext): Promise<CompletionResult | null> {
  let from: number;
  let query: string;
  const tex = context.matchBefore(CITE_ARG);
  if (tex) {
    const inner = tex.text.slice(tex.text.lastIndexOf("{") + 1);
    const partial = inner.slice(inner.lastIndexOf(",") + 1).trim();
    query = partial;
    from = context.pos - partial.length;
  } else {
    const md = context.matchBefore(MD_CITE);
    if (!md) return null;
    query = MD_CITE.exec(md.text)?.[1] ?? "";
    from = context.pos - query.length;
  }
  if (!query && !context.explicit) return null;
  // Parse the habitual "firstauthor year" form: leading letters = author,
  // trailing digits = year. Search Zotero by author, then filter by year.
  const m = /^([\p{L}.\-]*)\s*(\d{0,4})/u.exec(query);
  const authorPart = (m?.[1] ?? "").toLowerCase();
  const yearPart = m?.[2] ?? "";
  const searchQuery = authorPart || query;
  if (!searchQuery) return null;
  let items: ZItem[] = [];
  try {
    items = ((await call("zotero.search", { query: searchQuery })) as ZItem[]) ?? [];
  } catch {
    return null;
  }
  if (yearPart) {
    items = items.filter((it) => it.year.includes(yearPart) || it.citekey.includes(yearPart));
  }
  if (!items.length) return null;
  return {
    // We've already filtered by author+year — show our list as-is.
    filter: false,
    from,
    options: items.slice(0, 50).map((it) => ({
      label: it.citekey,
      detail: [it.authors, it.year].filter(Boolean).join(" "),
      info: it.title,
      type: "variable",
      apply: it.citekey,
    })),
  };
}

/** Inside `\ref{…}` / `\eqref{…}` / `\cref{…}` etc., complete from every
 * `\label{…}` defined in the current document. */
const REF_ARG = /\\(?:eq|c|C|auto|page|name|v|f)?ref\*?\{([^}]*)$/;

function refComplete(context: CompletionContext): CompletionResult | null {
  const m = context.matchBefore(REF_ARG);
  if (!m) return null;
  const inner = m.text.slice(m.text.lastIndexOf("{") + 1);
  const from = context.pos - inner.length;
  const doc = context.state.doc.toString();
  const labels = new Map<string, string>(); // label → inferred kind (eq/fig/…)
  const re = /\\label\{([^}]*)\}/g;
  let mm: RegExpExecArray | null;
  while ((mm = re.exec(doc))) {
    const lbl = mm[1];
    if (lbl) labels.set(lbl, /^([a-zA-Z]+):/.exec(lbl)?.[1] ?? "label");
  }
  if (!labels.size) return null;
  return {
    from,
    options: [...labels].map(([lbl, kind]) => ({
      label: lbl, detail: kind, type: "variable", apply: lbl,
    })),
    validFor: /^[^}]*$/,
  };
}

/** Notion-style `/` block menu at the start of a line: insert markdown blocks.
 * Built per-call so labels reflect the current UI language. */
function slashOptions(): Completion[] {
  return [
    snip("# ${}", t("/ 標題 H1"), "heading"),
    snip("## ${}", t("/ 標題 H2"), "heading"),
    snip("### ${}", t("/ 標題 H3"), "heading"),
    snip("- ${}", t("/ 清單"), "bullet list"),
    snip("- [ ] ${}", t("/ 待辦"), "task"),
    snip("1. ${}", t("/ 編號清單"), "numbered list"),
    snip("> ${}", t("/ 引用"), "quote"),
    snip("> [!note] ${}", t("/ 提示框 Callout"), "callout"),
    snip("```\n${}\n```", t("/ 程式碼"), "code block"),
    snip("$$\n${}\n$$", t("/ 數學公式"), "math block"),
    snip("| ${欄1} | ${欄2} |\n| --- | --- |\n| ${} |  |", t("/ 表格"), "table"),
    snip("\n---\n", t("/ 分隔線"), "divider"),
  ];
}

function slashComplete(context: CompletionContext): CompletionResult | null {
  const m = context.matchBefore(/\/\w*$/);
  if (!m) return null;
  // Only at the start of a line (slash is the first non-space char).
  const lineStart = context.state.doc.lineAt(context.pos).from;
  const before = context.state.sliceDoc(lineStart, m.from).trim();
  if (before.length) return null;
  return { from: m.from, options: slashOptions(), validFor: /^\/\w*$/ };
}

/** Inside `[[…]]`, complete from the vault's note names. */
const WIKI_ARG = /\[\[([^\]\n|]*)$/;

function wikiLinkComplete(context: CompletionContext): CompletionResult | null {
  const m = context.matchBefore(WIKI_ARG);
  if (!m) return null;
  const partial = WIKI_ARG.exec(m.text)?.[1] ?? "";
  const names = getNoteNames();
  if (!names.length) return null;
  return {
    from: context.pos - partial.length,
    options: names.map((n) => ({ label: n, type: "class", apply: n })),
    validFor: /^[^\]\n|]*$/,
  };
}

function latexComplete(context: CompletionContext): CompletionResult | null {
  const before = context.matchBefore(/\\[a-zA-Z@]*/);
  if (!before) return null;
  if (before.from === before.to && !context.explicit) return null;
  // Built-in options + the user's custom snippets ("\n" → newline).
  const custom = getConfig().snippets.map((s) =>
    snip(s.template.replace(/\\n/g, "\n"), s.label, "custom"),
  );
  return { from: before.from, options: [...custom, ...OPTIONS], validFor: /^\\[a-zA-Z@]*$/ };
}

/** Autocomplete extension + Tab-to-accept (falls back to inserting a tab). */
export const latexAutocomplete = [
  autocompletion({ override: [citeKeyComplete, refComplete, wikiLinkComplete, slashComplete, latexComplete], icons: false, activateOnTyping: true }),
  keymap.of([{ key: "Tab", run: (v) => acceptCompletion(v) || insertTab(v) }]),
];
