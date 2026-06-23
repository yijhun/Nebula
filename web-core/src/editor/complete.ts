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
  // Greek (lowercase + uppercase variants)
  "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta",
  "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi",
  "pi", "varpi", "rho", "varrho", "sigma", "varsigma", "tau", "upsilon",
  "phi", "varphi", "chi", "psi", "omega",
  "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon",
  "Phi", "Psi", "Omega",
  // Big operators
  "sum", "prod", "coprod", "int", "iint", "iiint", "oint", "oiint",
  "bigcup", "bigcap", "bigsqcup", "biguplus", "bigvee", "bigwedge",
  "bigoplus", "bigotimes", "bigodot",
  // Calculus / analysis
  "partial", "nabla", "infty", "Re", "Im", "hbar", "ell", "imath", "jmath",
  // Binary operators
  "cdot", "times", "div", "pm", "mp", "ast", "star", "circ", "bullet",
  "oplus", "ominus", "otimes", "oslash", "odot", "dagger", "ddagger",
  "wedge", "vee", "cap", "cup", "setminus", "amalg", "uplus",
  // Relations
  "approx", "neq", "leq", "geq", "ll", "gg", "equiv", "propto",
  "sim", "simeq", "cong", "asymp", "perp", "parallel", "mid",
  "doteq", "succ", "prec", "succeq", "preceq", "models",
  // Arrows
  "rightarrow", "Rightarrow", "leftarrow", "Leftarrow", "leftrightarrow",
  "Leftrightarrow", "longrightarrow", "Longrightarrow", "longleftarrow",
  "Longleftarrow", "mapsto", "longmapsto", "hookrightarrow", "hookleftarrow",
  "rightharpoonup", "leftharpoonup", "rightleftharpoons",
  "uparrow", "downarrow", "updownarrow", "Uparrow", "Downarrow", "Updownarrow",
  "nearrow", "nwarrow", "searrow", "swarrow", "to", "gets",
  // Logic / sets
  "forall", "exists", "nexists", "land", "lor", "lnot", "neg",
  "in", "notin", "ni", "subset", "subseteq", "supset", "supseteq",
  "emptyset", "varnothing", "complement", "implies", "impliedby", "iff",
  // Delimiters
  "langle", "rangle", "lfloor", "rfloor", "lceil", "rceil", "backslash",
  // Astronomy / physics shortcuts (siunitx/aastex commonly available)
  "odot",  // also Sun symbol
  // Spacing helpers
  "quad", "qquad",
  // Functions (use snippet form below; these are constants without args)
  "ldots", "cdots", "vdots", "ddots", "dots",
];

/** Math operators that should NOT have a `\` prefix in label but otherwise
 * behave like SYMBOLS. */
const OPERATORS = [
  "sin", "cos", "tan", "csc", "sec", "cot",
  "arcsin", "arccos", "arctan",
  "sinh", "cosh", "tanh", "coth",
  "log", "ln", "lg", "exp",
  "lim", "limsup", "liminf",
  "min", "max", "sup", "inf", "arg",
  "det", "deg", "dim", "ker", "hom",
  "gcd", "Pr",
  "bmod", "pmod",
];

const OPTIONS: Completion[] = [
  // ────── environments ──────
  ...ENVIRONMENTS.map((env) =>
    snip(`\\begin{${env}}\n\t\${}\n\\end{${env}}`, `\\begin{${env}}`, "environment"),
  ),
  snip("\\begin{${env}}\n\t${}\n\\end{${env}}", "\\begin{…}", "custom environment"),
  // ────── sectioning ──────
  snip("\\part{${}}", "\\part", "part"),
  snip("\\chapter{${}}", "\\chapter", "chapter"),
  snip("\\section{${}}", "\\section", "section"),
  snip("\\subsection{${}}", "\\subsection", "subsection"),
  snip("\\subsubsection{${}}", "\\subsubsection", "subsubsection"),
  snip("\\paragraph{${}}", "\\paragraph", "paragraph"),
  snip("\\subparagraph{${}}", "\\subparagraph", "subparagraph"),
  // ────── document meta ──────
  snip("\\title{${}}", "\\title", "title"),
  snip("\\author{${}}", "\\author", "author"),
  snip("\\date{${}}", "\\date", "date"),
  { label: "\\maketitle", type: "keyword", apply: "\\maketitle" },
  { label: "\\tableofcontents", type: "keyword", apply: "\\tableofcontents" },
  // ────── text styling ──────
  snip("\\textbf{${}}", "\\textbf", "bold"),
  snip("\\textit{${}}", "\\textit", "italic"),
  snip("\\textsc{${}}", "\\textsc", "small caps"),
  snip("\\texttt{${}}", "\\texttt", "monospace"),
  snip("\\textsf{${}}", "\\textsf", "sans-serif"),
  snip("\\underline{${}}", "\\underline", "underline"),
  snip("\\emph{${}}", "\\emph", "emphasis"),
  snip("\\text{${}}", "\\text", "text in math"),
  // ────── math fonts ──────
  snip("\\mathrm{${}}", "\\mathrm", "roman"),
  snip("\\mathbf{${}}", "\\mathbf", "bold"),
  snip("\\mathbb{${}}", "\\mathbb", "blackboard bold"),
  snip("\\mathcal{${}}", "\\mathcal", "calligraphic"),
  snip("\\mathscr{${}}", "\\mathscr", "script"),
  snip("\\mathfrak{${}}", "\\mathfrak", "fraktur"),
  snip("\\mathit{${}}", "\\mathit", "italic"),
  snip("\\mathsf{${}}", "\\mathsf", "sans-serif"),
  snip("\\mathtt{${}}", "\\mathtt", "monospace"),
  snip("\\boldsymbol{${}}", "\\boldsymbol", "bold symbol"),
  snip("\\operatorname{${}}", "\\operatorname", "custom operator"),
  // ────── fractions / roots / structure ──────
  snip("\\frac{${num}}{${den}}", "\\frac", "fraction"),
  snip("\\dfrac{${num}}{${den}}", "\\dfrac", "display fraction"),
  snip("\\tfrac{${num}}{${den}}", "\\tfrac", "text fraction"),
  snip("\\binom{${n}}{${k}}", "\\binom", "binomial"),
  snip("\\dbinom{${n}}{${k}}", "\\dbinom", "display binomial"),
  snip("\\sqrt{${}}", "\\sqrt", "square root"),
  snip("\\sqrt[${n}]{${}}", "\\sqrt[n]", "nth root"),
  snip("\\stackrel{${top}}{${bot}}", "\\stackrel", "stack"),
  // ────── accents / decorations ──────
  snip("\\hat{${}}", "\\hat", "hat"),
  snip("\\widehat{${}}", "\\widehat", "wide hat"),
  snip("\\tilde{${}}", "\\tilde", "tilde"),
  snip("\\widetilde{${}}", "\\widetilde", "wide tilde"),
  snip("\\bar{${}}", "\\bar", "bar"),
  snip("\\overline{${}}", "\\overline", "overline"),
  snip("\\vec{${}}", "\\vec", "vector"),
  snip("\\dot{${}}", "\\dot", "dot"),
  snip("\\ddot{${}}", "\\ddot", "double dot"),
  snip("\\acute{${}}", "\\acute", "acute"),
  snip("\\grave{${}}", "\\grave", "grave"),
  snip("\\check{${}}", "\\check", "check"),
  snip("\\breve{${}}", "\\breve", "breve"),
  snip("\\overbrace{${}}^{${label}}", "\\overbrace", "overbrace"),
  snip("\\underbrace{${}}_{${label}}", "\\underbrace", "underbrace"),
  snip("\\overrightarrow{${}}", "\\overrightarrow", "right arrow over"),
  snip("\\overleftarrow{${}}", "\\overleftarrow", "left arrow over"),
  snip("\\overset{${top}}{${base}}", "\\overset", "set over"),
  snip("\\underset{${bot}}{${base}}", "\\underset", "set under"),
  // ────── delimiters ──────
  snip("\\left(${}\\right)", "\\left( … \\right)", "auto-size ()"),
  snip("\\left[${}\\right]", "\\left[ … \\right]", "auto-size []"),
  snip("\\left\\{${}\\right\\}", "\\left\\{ … \\right\\}", "auto-size {}"),
  snip("\\left|${}\\right|", "\\left| … \\right|", "auto-size ||"),
  snip("\\left\\|${}\\right\\|", "\\left\\| … \\right\\|", "auto-size ‖‖"),
  { label: "\\big", type: "keyword", apply: "\\big" },
  { label: "\\Big", type: "keyword", apply: "\\Big" },
  { label: "\\bigg", type: "keyword", apply: "\\bigg" },
  { label: "\\Bigg", type: "keyword", apply: "\\Bigg" },
  // ────── citations / references ──────
  snip("\\cite{${}}", "\\cite", "citation"),
  snip("\\citep{${}}", "\\citep", "paren citation (natbib)"),
  snip("\\citet{${}}", "\\citet", "textual citation (natbib)"),
  snip("\\citeauthor{${}}", "\\citeauthor", "author only"),
  snip("\\citeyear{${}}", "\\citeyear", "year only"),
  snip("\\autocite{${}}", "\\autocite", "citation (biblatex)"),
  snip("\\textcite{${}}", "\\textcite", "textual cite (biblatex)"),
  snip("\\ref{${}}", "\\ref", "reference"),
  snip("\\eqref{${}}", "\\eqref", "equation ref"),
  snip("\\pageref{${}}", "\\pageref", "page ref"),
  snip("\\cref{${}}", "\\cref", "cleveref"),
  snip("\\Cref{${}}", "\\Cref", "cleveref capitalized"),
  snip("\\label{${}}", "\\label", "label"),
  snip("\\footnote{${}}", "\\footnote", "footnote"),
  snip("\\bibliography{${references}}", "\\bibliography", "bib file"),
  snip("\\bibliographystyle{${style}}", "\\bibliographystyle", "bib style"),
  // ────── figures / tables ──────
  snip("\\includegraphics[width=\\linewidth]{${}}", "\\includegraphics", "image"),
  snip("\\caption{${}}", "\\caption", "caption"),
  { label: "\\centering", type: "keyword", apply: "\\centering" },
  { label: "\\hline", type: "keyword", apply: "\\hline" },
  { label: "\\toprule", type: "keyword", apply: "\\toprule" },
  { label: "\\midrule", type: "keyword", apply: "\\midrule" },
  { label: "\\bottomrule", type: "keyword", apply: "\\bottomrule" },
  snip("\\multicolumn{${n}}{${align}}{${}}", "\\multicolumn", "multi-column cell"),
  snip("\\multirow{${n}}{${width}}{${}}", "\\multirow", "multi-row cell"),
  // ────── spacing ──────
  { label: "\\quad", type: "keyword", apply: "\\quad" },
  { label: "\\qquad", type: "keyword", apply: "\\qquad" },
  { label: "\\,", type: "keyword", apply: "\\," , detail: "thin space" },
  { label: "\\;", type: "keyword", apply: "\\;", detail: "thick space" },
  { label: "\\:", type: "keyword", apply: "\\:", detail: "medium space" },
  { label: "\\!", type: "keyword", apply: "\\!", detail: "negative thin space" },
  { label: "\\\\", type: "keyword", apply: "\\\\", detail: "line break" },
  // ────── list ──────
  snip("\\item ${}", "\\item", "list item"),
  // ────── math operators (auto-prefix \) ──────
  ...OPERATORS.map((s) => ({ label: `\\${s}`, type: "function", apply: `\\${s}`, detail: "math operator" }) as Completion),
  // ────── symbols / arrows / Greek (auto-prefix \) ──────
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

// ─── Same-document recall (IDE-style "variable" autocomplete) ─────────────
//
// Scans the active document for "interesting tokens" — LaTeX commands and
// subscripted/superscripted identifiers like `n_{HI}`, `r_{disk}`, `\sigma_T`,
// `M^{14}C`. Builds a frequency table, then completes the user's prefix from
// it (ranked by how often the token appears). Caches the table per-doc so
// every keystroke doesn't re-scan a long document.

interface DocToken { text: string; count: number }
let cachedDoc = "";
let cachedTokens: DocToken[] = [];
const TOKEN_RE = new RegExp(
  // \command + optional {arg} + optional _/^(brace|command|char):
  // captures e.g. `\overline{n}_\gamma`, `\sigma_T`, `\dot{n}`, `\frac{a}`,
  // `\underbrace{stuff}_{label}` (flat-brace contents only — nested braces
  // give a truncated match that gets filtered by the balance check below).
  String.raw`\\[a-zA-Z@]+(?:\{[^{}]*\})?(?:[_^](?:\\[a-zA-Z@]+|\{[^{}]*\}|[A-Za-z0-9]))?` + "|" +
  // identifier_{subscript} / identifier^{superscript}: `n_{HI}`, `M^{14}`
  String.raw`[A-Za-z][A-Za-z0-9]*[_^]\{[^{}]+\}` + "|" +
  // identifier_letter / identifier^letter (short): `n_e`, `M^2`
  String.raw`[A-Za-z][A-Za-z0-9]*[_^][A-Za-z0-9]`,
  "g",
);

/** Are all `{` `}` in this token balanced and free of stray escapes? Filters
 * out truncated matches from nested-brace expressions like
 * `\underbrace{\overline{...}}_{...}` (the regex stops at the first `}`). */
function isWellFormed(tok: string): boolean {
  let depth = 0;
  for (let i = 0; i < tok.length; i++) {
    if (tok[i] === "\\") { i++; continue; }
    if (tok[i] === "{") depth++;
    else if (tok[i] === "}") { depth--; if (depth < 0) return false; }
  }
  return depth === 0;
}

/** Map of tokens that the built-in OPTIONS list already covers — don't
 * re-show them via doc recall (would create duplicate completions). */
const BUILT_IN_LABELS = new Set<string>();

function tokensIn(doc: string): DocToken[] {
  if (doc === cachedDoc) return cachedTokens;
  const freq = new Map<string, number>();
  let m: RegExpExecArray | null;
  TOKEN_RE.lastIndex = 0;
  while ((m = TOKEN_RE.exec(doc))) {
    const tok = m[0];
    // Skip plain `\command` already covered by the built-in list — only the
    // composite forms (`\sigma_T`, `n_{HI}`) are unique enough to be useful.
    if (tok.startsWith("\\") && BUILT_IN_LABELS.has(tok)) continue;
    // Discard truncated matches from nested-brace expressions (the regex
    // bails at the first `}`, which produces a malformed half-token).
    if (!isWellFormed(tok)) continue;
    freq.set(tok, (freq.get(tok) ?? 0) + 1);
  }
  cachedDoc = doc;
  cachedTokens = [...freq.entries()].map(([text, count]) => ({ text, count }));
  return cachedTokens;
}

/** Inline IDE-style recall: prefix-match the cursor's word against the
 * document's previously-seen tokens. Triggers on `\` (LaTeX) and on plain
 * identifiers — but only with at least 2 chars (or explicit ⌃Space). */
function docTokenComplete(context: CompletionContext): CompletionResult | null {
  // Match the current word: a backslash command OR a plain ident chain
  // (letter then letters/digits/_/^/{}). The trailing `{…}` lets us match
  // mid-subscript like `n_{H`.
  const before = context.matchBefore(/(?:\\[a-zA-Z@]*|[A-Za-z][A-Za-z0-9]*(?:[_^](?:\{[^}]*}?)?)?)/);
  if (!before) return null;
  const partial = before.text;
  if (partial.length < 2 && !context.explicit) return null;
  const doc = context.state.doc.toString();
  const tokens = tokensIn(doc);
  const matches = tokens
    .filter((t) => t.text !== partial && t.text.startsWith(partial))
    .sort((a, b) => b.count - a.count || a.text.localeCompare(b.text))
    .slice(0, 20);
  if (!matches.length) return null;
  return {
    from: before.from,
    options: matches.map((t) => ({
      label: t.text,
      detail: `${t.count}× in note`,
      type: "variable",
      apply: t.text,
      boost: Math.min(t.count, 50),     // higher count → ranked higher
    })),
    validFor: /^[\\A-Za-z][A-Za-z0-9_^{}]*$/,
  };
}

// Populate the built-in-label set once (after OPTIONS is defined).
for (const c of OPTIONS) if (typeof c.label === "string") BUILT_IN_LABELS.add(c.label);

/** Autocomplete extension + Tab-to-accept (falls back to inserting a tab). */
export const latexAutocomplete = [
  autocompletion({ override: [citeKeyComplete, refComplete, wikiLinkComplete, slashComplete, docTokenComplete, latexComplete], icons: false, activateOnTyping: true }),
  keymap.of([{ key: "Tab", run: (v) => acceptCompletion(v) || insertTab(v) }]),
];
