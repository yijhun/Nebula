/**
 * emitter.ts — augmented mdast tree -> LaTeX body string.
 *
 * This is the canonical Markdown -> LaTeX mapping for Notepro M1. The mapping
 * table is documented in MAPPING.md (the source of truth, since the referenced
 * DESIGN.md §4.5 was unavailable). Each `emit*` function corresponds to one row.
 *
 * The emitter is engine-targeted at XeLaTeX (what Tectonic runs), which is why
 * CJK and fontspec-friendly constructs are assumed available via the preamble.
 */
import type {
  RootContent,
  PhrasingContent,
  Root,
  Heading,
  List,
  ListItem,
  Table,
  FootnoteDefinition,
} from "mdast";
import type { Asset, Callout, Citation, Embed, WikiLink } from "./types.js";

/** Feature tokens the preamble uses to decide which packages to load. */
export type Feature =
  | "graphicx"
  | "hyperref"
  | "ulem"
  | "math"
  | "biblatex"
  | "natbib"
  | "footnote";

/** Citation/bibliography style: biblatex (\autocite/\printbibliography) or
 * natbib (\citep/\bibliography — required by AASTeX/ApJ). */
export type CiteStyle = "biblatex" | "natbib";

export interface EmitContext {
  citationKeys: string[];
  citeSeen: Set<string>;
  assets: Asset[];
  features: Set<Feature>;
  footnotes: Map<string, FootnoteDefinition>;
  citeStyle: CiteStyle;
}

export interface EmitResult {
  body: string;
  citationKeys: string[];
  assets: Asset[];
  features: Set<Feature>;
}

const HEADING_CMD = [
  "\\section",
  "\\subsection",
  "\\subsubsection",
  "\\paragraph",
  "\\subparagraph",
  "\\subparagraph",
];

const LATEX_SPECIAL: Record<string, string> = {
  "\\": "\\textbackslash{}",
  "&": "\\&",
  "%": "\\%",
  $: "\\$",
  "#": "\\#",
  _: "\\_",
  "{": "\\{",
  "}": "\\}",
  "~": "\\textasciitilde{}",
  "^": "\\textasciicircum{}",
};

/** Escape LaTeX-special characters in plain text. Single pass — replacement
 * strings are emitted verbatim and never re-scanned. */
export function escapeLatex(text: string): string {
  return text.replace(/[\\&%$#_{}~^]/g, (c) => LATEX_SPECIAL[c]!);
}

function newContext(citeStyle: CiteStyle): EmitContext {
  return {
    citationKeys: [],
    citeSeen: new Set(),
    assets: [],
    features: new Set(),
    footnotes: new Map(),
    citeStyle,
  };
}

// Wide-boxable math envs (overflow horizontally) vs numbered display envs
// (can't be wrapped in a box without breaking numbering).
const WIDE_ENV = /\\begin\{(?:[pbvVB]?matrix|smallmatrix|cases|dcases|array|aligned|split|gathered)\}/;
const NUMBERED_ENV = /\\begin\{(?:align|gather|multline|equation|eqnarray|flalign|alignat)\*?\}/;

/** Shrink a display `\[…\]` block to the line width IF it would overflow (wide
 * matrices / cases), otherwise leave it untouched (`\ifdim\width>\linewidth`).
 * Only applied to boxable envs, never to numbered display envs. */
function fitWideMath(value: string, ctx: EmitContext): string {
  const m = /^\\\[\s*([\s\S]*?)\s*\\\]$/.exec(value.trim());
  if (!m) return value;
  const inner = m[1]!;
  if (!WIDE_ENV.test(inner) || NUMBERED_ENV.test(inner)) return value;
  ctx.features.add("graphicx");
  return `\\[\n\\resizebox{\\ifdim\\width>\\linewidth \\linewidth\\else\\width\\fi}{!}{$\\displaystyle ${inner}$}\n\\]`;
}

function recordCite(ctx: EmitContext, key: string): void {
  if (!ctx.citeSeen.has(key)) {
    ctx.citeSeen.add(key);
    ctx.citationKeys.push(key);
  }
}

function addAsset(ctx: EmitContext, asset: Asset): void {
  ctx.assets.push(asset);
}

/** Emit an array of children, joined directly. */
function emitChildren(nodes: readonly RootContent[], ctx: EmitContext): string {
  return nodes.map((n) => emitNode(n, ctx)).join("");
}

/** Emit inline/phrasing children, joined directly. */
function emitInline(
  nodes: readonly PhrasingContent[],
  ctx: EmitContext,
): string {
  return nodes.map((n) => emitNode(n, ctx)).join("");
}

function emitHeading(node: Heading, ctx: EmitContext): string {
  const cmd = HEADING_CMD[node.depth - 1] ?? "\\paragraph";
  return `${cmd}{${emitInline(node.children, ctx)}}\n\n`;
}

function emitList(node: List, ctx: EmitContext): string {
  const env = node.ordered ? "enumerate" : "itemize";
  const start =
    node.ordered && node.start && node.start !== 1
      ? `\\setcounter{enumi}{${node.start - 1}}\n`
      : "";
  const items = node.children
    .map((item) => emitListItem(item as ListItem, ctx))
    .join("");
  return `\\begin{${env}}\n${start}${items}\\end{${env}}\n\n`;
}

function emitListItem(node: ListItem, ctx: EmitContext): string {
  let marker = "\\item ";
  if (node.checked === true) {
    marker = "\\item[$\\boxtimes$] ";
    ctx.features.add("math");
  } else if (node.checked === false) {
    marker = "\\item[$\\square$] ";
    ctx.features.add("math");
  }
  // For tight items, unwrap single paragraphs to avoid blank lines.
  const inner = node.children
    .map((child) =>
      child.type === "paragraph"
        ? emitInline(child.children, ctx)
        : emitNode(child, ctx),
    )
    .join("")
    .replace(/\n+$/, "");
  return `${marker}${inner}\n`;
}

function colSpec(table: Table): string {
  const align = table.align ?? [];
  const cols = table.children[0]?.children.length ?? 0;
  const spec: string[] = [];
  for (let i = 0; i < cols; i++) {
    const a = align[i];
    spec.push(a === "center" ? "c" : a === "right" ? "r" : "l");
  }
  return spec.join("");
}

function emitTable(node: Table, ctx: EmitContext): string {
  const rows = node.children.map((row) =>
    row.children
      .map((cell) => emitInline(cell.children, ctx))
      .join(" & "),
  );
  const head = rows[0] ?? "";
  const bodyRows = rows.slice(1);
  const lines = [
    `\\begin{tabular}{${colSpec(node)}}`,
    `\\hline`,
    `${head} \\\\`,
    `\\hline`,
    ...bodyRows.map((r) => `${r} \\\\`),
    `\\hline`,
    `\\end{tabular}`,
  ];
  return `\\begin{center}\n${lines.join("\n")}\n\\end{center}\n\n`;
}

function emitCitation(node: Citation, ctx: EmitContext): string {
  node.items.forEach((it) => recordCite(ctx, it.key));
  const items = node.items;

  // natbib (AASTeX/ApJ): \citep, which rejects biblatex.
  if (ctx.citeStyle === "natbib") {
    ctx.features.add("natbib");
    const keys = items.map((it) => it.key).join(",");
    const single = items.length === 1 ? items[0]! : undefined;
    return single?.suffix
      ? `\\citep[${escapeLatex(single.suffix)}]{${single.key}}`
      : `\\citep{${keys}}`;
  }

  ctx.features.add("biblatex");
  if (items.length === 1) {
    const it = items[0]!;
    return it.suffix
      ? `\\autocite[${escapeLatex(it.suffix)}]{${it.key}}`
      : `\\autocite{${it.key}}`;
  }
  const anySuffix = items.some((it) => it.suffix);
  if (!anySuffix) {
    return `\\autocite{${items.map((it) => it.key).join(",")}}`;
  }
  return `\\autocites${items
    .map((it) => `[${escapeLatex(it.suffix ?? "")}]{${it.key}}`)
    .join("")}`;
}

function emitEmbed(node: Embed, ctx: EmitContext): string {
  if (node.isImage) {
    ctx.features.add("graphicx");
    addAsset(ctx, { kind: "image", ref: node.target, resolved: true });
    return `\n\\begin{center}\n\\includegraphics[width=\\linewidth]{${node.target}}\n\\end{center}\n`;
  }
  // Non-image embed (e.g. another note): leave a visible placeholder.
  addAsset(ctx, { kind: "embed", ref: node.target, resolved: false });
  return `\\texttt{[[${escapeLatex(node.target)}]]}`;
}

function emitWikiLink(node: WikiLink): string {
  // Internal links have no PDF target; render the display text inline.
  const display = node.alias ?? node.target;
  return escapeLatex(display);
}

function emitCallout(node: Callout, ctx: EmitContext): string {
  const label = node.calloutType
    ? node.calloutType.charAt(0).toUpperCase() + node.calloutType.slice(1)
    : "Note";
  const titlePart = node.title ? `: ${escapeLatex(node.title)}` : "";
  const inner = emitChildren(node.children, ctx).replace(/\n+$/, "");
  return `\\begin{quote}\n\\textbf{[${escapeLatex(label)}${titlePart}]}\\par\n${inner}\n\\end{quote}\n\n`;
}

function emitNode(node: RootContent | Root, ctx: EmitContext): string {
  switch (node.type) {
    case "root":
      return emitChildren(node.children, ctx);
    case "paragraph":
      return `${emitInline(node.children, ctx)}\n\n`;
    case "text":
      return escapeLatex(node.value);
    case "emphasis":
      return `\\emph{${emitInline(node.children, ctx)}}`;
    case "strong":
      return `\\textbf{${emitInline(node.children, ctx)}}`;
    case "delete":
      ctx.features.add("ulem");
      return `\\sout{${emitInline(node.children, ctx)}}`;
    case "inlineCode":
      return `\\texttt{${escapeLatex(node.value)}}`;
    case "code": {
      // verbatim needs no escaping; preserve content as-is.
      const lang = node.lang ? `% language: ${node.lang}\n` : "";
      return `${lang}\\begin{verbatim}\n${node.value}\n\\end{verbatim}\n\n`;
    }
    case "break":
      return "\\\\\n";
    case "thematicBreak":
      return "\\begin{center}\\rule{0.5\\linewidth}{0.4pt}\\end{center}\n\n";
    case "heading":
      return emitHeading(node, ctx);
    case "blockquote":
      return `\\begin{quote}\n${emitChildren(node.children, ctx).replace(/\n+$/, "")}\n\\end{quote}\n\n`;
    case "list":
      return emitList(node, ctx);
    case "listItem":
      return emitListItem(node, ctx);
    case "table":
      return emitTable(node, ctx);
    case "link":
      ctx.features.add("hyperref");
      return `\\href{${node.url}}{${emitInline(node.children, ctx)}}`;
    case "image":
      ctx.features.add("graphicx");
      addAsset(ctx, { kind: "image", ref: node.url, resolved: true });
      return `\\includegraphics[width=\\linewidth]{${node.url}}`;
    case "math":
      ctx.features.add("math");
      return `${fitWideMath(`\\[\n${node.value}\n\\]`, ctx)}\n\n`;
    case "inlineMath":
      ctx.features.add("math");
      return `$${node.value}$`;
    case "latexBlock":
      // Raw LaTeX written in the Markdown — pass through untouched. Block
      // environments get a paragraph break; inline commands stay inline.
      ctx.features.add("math");
      return node.display === false ? node.value : `${fitWideMath(node.value, ctx)}\n\n`;
    case "wikiLink":
      return emitWikiLink(node);
    case "embed":
      return emitEmbed(node, ctx);
    case "citation":
      return emitCitation(node, ctx);
    case "callout":
      return emitCallout(node, ctx);
    case "footnoteReference": {
      ctx.features.add("footnote");
      const def = ctx.footnotes.get(node.identifier);
      const content = def
        ? emitChildren(def.children, ctx).replace(/\n+$/, "")
        : "";
      return `\\footnote{${content}}`;
    }
    case "footnoteDefinition":
      return ""; // emitted inline at the reference
    case "html":
      return `% [html omitted]\n`;
    case "yaml":
      return "";
    default:
      return "";
  }
}

/** Convert an augmented mdast tree into a LaTeX body string. */
export function emit(tree: Root, opts: { citeStyle?: CiteStyle } = {}): EmitResult {
  const ctx = newContext(opts.citeStyle ?? "biblatex");
  // Pre-index footnote definitions so references can inline them.
  for (const child of tree.children) {
    if (child.type === "footnoteDefinition") {
      ctx.footnotes.set(child.identifier, child);
    }
  }
  const body = emitNode(tree, ctx).replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
  return {
    body,
    citationKeys: ctx.citationKeys,
    assets: ctx.assets,
    features: ctx.features,
  };
}
