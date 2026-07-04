/**
 * parser.ts — Markdown (Obsidian-flavored) -> unified mdast tree.
 *
 * Pipeline: remark-parse (CommonMark) + remark-gfm (tables, task lists,
 * strikethrough) + remark-frontmatter (YAML) + remark-math ($..$ / $$..$$),
 * followed by a local transformer that lifts Obsidian constructs which the
 * standard grammar leaves as plain text:
 *   - `[[wikilink]]` / `[[wikilink|alias]]`
 *   - `![[embed]]`
 *   - `[@citation]`, `[@a; @b]`, `[@key, p. 5]`
 *   - `> [!callout]` blockquotes
 *
 * The probe in development confirmed these survive remark as `text` nodes
 * (and callouts as a `blockquote` whose first text begins with `[!type]`),
 * so a post-parse transform is both sufficient and simpler than bespoke
 * micromark tokenizers.
 */
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkFrontmatter from "remark-frontmatter";
import { visit, SKIP } from "unist-util-visit";
import { parse as parseYaml } from "yaml";
import type { Root, Text, Blockquote, Paragraph, PhrasingContent } from "mdast";
import type {
  Frontmatter,
  WikiLink,
  Embed,
  Citation,
  CitationItem,
  Callout,
} from "./types.js";

const IMAGE_EXT = /\.(png|jpe?g|gif|svg|pdf|webp|bmp|tiff?)$/i;

/** Matches embeds, wikilinks, and citation groups (embed first, so `![[` wins). */
const INLINE_TOKEN =
  /(!\[\[[^\]\n]+\]\])|(\[\[[^\]\n]+\]\])|(\[[^\]\[\n]*@[^\]\n]*\])/g;

const CALLOUT_HEAD = /^\[!([^\]]+)\]([+-]?)[ \t]*(.*)$/;

/** Raw LaTeX block: a full `\begin{env}…\end{env}` or a `\[ … \]` display. */
export const LATEX_BLOCK_RE = /\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}|\\\[[\s\S]*?\\\]/g;
/** An extracted raw-LaTeX span: standalone block (display) vs inline command. */
export interface ExtractedBlock { raw: string; display: boolean; }
/** Whitelisted inline LaTeX commands passed through verbatim (require a brace
 * arg, so stray backslashes in prose / file paths aren't swept up). */
const LATEX_INLINE_RE =
  /\\(?:eq|c|C|auto|page|name|v|f)?ref\*?\{[^{}\n]*\}|\\(?:cite|citep|citet|citeauthor|citeyear|autocite|textcite|parencite|footcite|footnote|label|textbf|textit|texttt|textsc|emph|url|so)\*?(?:\[[^\]\n]*\])*\{[^{}\n]*\}(?:\{[^{}\n]*\})?/g;
/** Sentinel char bracketing extracted-block placeholders (private-use area). */
const LB = "\uE000";

/**
 * Pull raw LaTeX blocks out of the source BEFORE remark parses it, replacing
 * each with a standalone placeholder paragraph. This is essential for
 * environments containing `\\` (align, matrix, cases…), which remark would
 * otherwise shatter into hard-break nodes. Callers restore the blocks after
 * parsing (see restoreLatexBlocks).
 */
/** Inline `$…$` math — left for remark-math (single-line works fine). */
const INLINE_MATH = /\$(?:\\.|[^$\n])+?\$/g;
/** Display `$$…$$` math — we handle it ourselves (remark-math mishandles `$$`
 * spanning lines inside a paragraph; Obsidian/MathJax treat it as display
 * anywhere). Converted to `\[…\]` so it flows through the KaTeX/LaTeX path. */
const DISPLAY_MATH = /\$\$((?:(?!\n[ \t]*#{1,6} )[\s\S])+?)\$\$/g;

/** Math environments where a blank line is illegal (causes a TeX error). */
const MATH_ENV_RE =
  /^\\begin\{(equation\*?|align\*?|aligned|gather\*?|gathered|multline\*?|split|cases|dcases|alignat\*?|flalign\*?|eqnarray\*?|array|[pbvBV]?matrix|smallmatrix)\}/;

/** Collapse blank lines (2+ newlines) to one — blank lines are illegal inside
 * LaTeX math mode (`$$`, `\[…\]`, align/matrix/…), even though MathJax tolerates
 * them. Without this a `$$ … =\n\n1 … $$` compiles to a broken `\[ … \]`. */
function stripMathBlankLines(s: string): string {
  return s.replace(/\n[ \t]*(?:\n[ \t]*)+/g, "\n");
}

/** A fenced code block (``` … ```). Extraction must NEVER reach inside one —
 * a ```tikz block legitimately contains \begin{axis}/\begin{tikzpicture}, and
 * ripping those out to placeholders mangles the code block on export. */
const CODE_FENCE_RE = /^[ \t]*```[^\n]*\n[\s\S]*?^[ \t]*```[ \t]*$/gm;

export function extractLatexBlocks(src: string): { text: string; blocks: ExtractedBlock[] } {
  const blocks: ExtractedBlock[] = [];
  // Placeholder that PRESERVES the match's line count, so downstream source
  // line numbers (used for preview↔editor jump) stay correct.
  const ph = (raw: string, match: string, display: boolean): string => {
    blocks.push({ raw, display });
    const nl = (match.match(/\n/g) || []).length;
    return `${LB}${blocks.length - 1}${LB}` + "\n".repeat(nl);
  };

  /** The original extraction pipeline, applied to one NON-code segment. */
  const processSegment = (seg: string): string => {
    // 1. Pull every $$…$$ out as a display block (→ \[ … \]).
    const pre = seg.replace(DISPLAY_MATH, (m: string, inner: string) =>
      ph(`\\[\n${stripMathBlankLines(inner.trim())}\n\\]`, m, true),
    );
    // 2. Extract raw LaTeX (\begin{…}, \[ \], whitelisted \cmd) OUTSIDE inline $…$.
    // Strip blank lines from math blocks (\[…\] + math envs), not text envs.
    const extract = (chunk: string): string => {
      LATEX_BLOCK_RE.lastIndex = 0;
      chunk = chunk.replace(LATEX_BLOCK_RE, (m) => {
        const isMath = m.startsWith("\\[") || MATH_ENV_RE.test(m);
        return ph(isMath ? stripMathBlankLines(m) : m, m, true);
      });
      LATEX_INLINE_RE.lastIndex = 0;
      chunk = chunk.replace(LATEX_INLINE_RE, (m) => ph(m, m, false));
      return chunk;
    };
    let out = "";
    let last = 0;
    let m: RegExpExecArray | null;
    INLINE_MATH.lastIndex = 0;
    while ((m = INLINE_MATH.exec(pre))) {
      out += extract(pre.slice(last, m.index));
      out += m[0];
      last = m.index + m[0].length;
    }
    out += extract(pre.slice(last));
    return out;
  };

  // Walk fenced code blocks: process the text BETWEEN them, pass the code
  // through byte-for-byte.
  let out = "";
  let last = 0;
  let fm: RegExpExecArray | null;
  CODE_FENCE_RE.lastIndex = 0;
  while ((fm = CODE_FENCE_RE.exec(src))) {
    out += processSegment(src.slice(last, fm.index));
    out += fm[0];
    last = fm.index + fm[0].length;
  }
  out += processSegment(src.slice(last));
  return { text: out, blocks };
}

const PLACEHOLDER_RE = new RegExp(`${LB}(\\d+)${LB}`, "g");

/** Split a text value on block placeholders, mapping each to `make(raw)`. */
export function splitOnLatexPlaceholders<T>(
  value: string,
  blocks: ExtractedBlock[],
  make: (block: ExtractedBlock) => T,
): Array<Text | T> | null {
  PLACEHOLDER_RE.lastIndex = 0;
  if (!PLACEHOLDER_RE.test(value)) return null;
  PLACEHOLDER_RE.lastIndex = 0;
  const out: Array<Text | T> = [];
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = PLACEHOLDER_RE.exec(value))) {
    if (m.index > last) out.push({ type: "text", value: value.slice(last, m.index) } as Text);
    out.push(make(blocks[Number(m[1])] ?? { raw: "", display: false }));
    last = m.index + m[0].length;
  }
  if (last < value.length) out.push({ type: "text", value: value.slice(last) } as Text);
  return out;
}

/** Split a `[[target|alias]]` / `target#heading` inner string. */
function splitLink(inner: string): {
  target: string;
  alias?: string;
  heading?: string;
} {
  const pipe = inner.indexOf("|");
  let link = pipe >= 0 ? inner.slice(0, pipe) : inner;
  const alias = pipe >= 0 ? inner.slice(pipe + 1).trim() : undefined;
  let heading: string | undefined;
  const hash = link.indexOf("#");
  if (hash >= 0) {
    heading = link.slice(hash + 1).trim() || undefined;
    link = link.slice(0, hash);
  }
  return { target: link.trim(), alias, heading };
}

/** Parse the inside of a `[@...]` group into citation items. */
function parseCitation(raw: string): CitationItem[] {
  const inner = raw.slice(1, -1); // drop [ ]
  return inner
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      // `@key` optionally followed by ", locator" or " locator".
      const m = /@([^\s,\]]+)\s*(?:,\s*)?(.*)$/.exec(part);
      if (!m) return null;
      const item: CitationItem = { key: m[1]! };
      const suffix = m[2]?.trim();
      if (suffix) item.suffix = suffix;
      return item;
    })
    .filter((x): x is CitationItem => x !== null);
}

/** Convert one text node's value into a sequence of phrasing nodes. */
function tokenizeText(value: string): PhrasingContent[] {
  const out: PhrasingContent[] = [];
  let last = 0;
  for (const m of value.matchAll(INLINE_TOKEN)) {
    const start = m.index!;
    if (start > last) {
      out.push({ type: "text", value: value.slice(last, start) } as Text);
    }
    const [full, embed, wiki, cite] = m;
    if (embed) {
      const { target, alias } = splitLink(embed.slice(3, -2));
      const node: Embed = {
        type: "embed",
        value: full,
        target,
        isImage: IMAGE_EXT.test(target),
      };
      if (alias) node.alias = alias;
      out.push(node);
    } else if (wiki) {
      const { target, alias, heading } = splitLink(wiki.slice(2, -2));
      const node: WikiLink = { type: "wikiLink", value: full, target };
      if (alias) node.alias = alias;
      if (heading) node.heading = heading;
      out.push(node);
    } else if (cite) {
      const items = parseCitation(cite);
      // Only treat as a citation if at least one valid @key was found,
      // otherwise leave the literal text untouched.
      if (items.length > 0) {
        out.push({ type: "citation", value: full, items } as Citation);
      } else {
        out.push({ type: "text", value: full } as Text);
      }
    }
    last = start + full.length;
  }
  if (last < value.length) {
    out.push({ type: "text", value: value.slice(last) } as Text);
  }
  return out;
}

/** Detect and convert an Obsidian callout blockquote in place. Returns the
 * replacement Callout node, or null if the blockquote isn't a callout. */
function toCallout(node: Blockquote): Callout | null {
  const first = node.children[0];
  if (!first || first.type !== "paragraph") return null;
  const firstText = first.children[0];
  if (!firstText || firstText.type !== "text") return null;

  // The marker line may share a text node with body text (split on \n).
  const nl = firstText.value.indexOf("\n");
  const headLine = nl >= 0 ? firstText.value.slice(0, nl) : firstText.value;
  const m = CALLOUT_HEAD.exec(headLine);
  if (!m) return null;

  const calloutType = m[1]!.trim().toLowerCase();
  const fold = m[2];
  const title = m[3]?.trim() || undefined;

  // Rebuild the first paragraph's children minus the consumed marker line.
  const remainder = nl >= 0 ? firstText.value.slice(nl + 1) : "";
  const newFirstChildren: PhrasingContent[] = [];
  if (remainder) newFirstChildren.push({ type: "text", value: remainder });
  newFirstChildren.push(...first.children.slice(1));

  const restBlocks = node.children.slice(1);
  const calloutChildren: Callout["children"] = [];
  if (newFirstChildren.length > 0) {
    calloutChildren.push({
      type: "paragraph",
      children: newFirstChildren,
    } as Paragraph);
  }
  calloutChildren.push(...restBlocks);

  const callout: Callout = {
    type: "callout",
    calloutType,
    children: calloutChildren,
  };
  if (title) callout.title = title;
  if (fold === "+" || fold === "-") callout.folded = fold === "-";
  return callout;
}

/** unified plugin: lift Obsidian constructs into custom nodes. */
function remarkObsidian(blocks: ExtractedBlock[]) {
  return (tree: Root) => {
    // Restore extracted raw-LaTeX blocks (placeholders) as verbatim nodes.
    visit(tree, "text", (node, index, parent) => {
      if (!parent || index === undefined) return;
      const parts = splitOnLatexPlaceholders((node as Text).value, blocks, (b) => ({
        type: "latexBlock",
        value: b.raw,
        display: b.display,
      }) as PhrasingContent);
      if (!parts) return;
      parent.children.splice(index, 1, ...parts);
      return [SKIP, index + parts.length];
    });

    // Callouts (operates on blockquotes / parents).
    visit(tree, "blockquote", (node, index, parent) => {
      if (!parent || index === undefined) return;
      const callout = toCallout(node as Blockquote);
      if (callout) {
        parent.children.splice(index, 1, callout);
        return [SKIP, index]; // re-visit the replacement's subtree
      }
      return;
    });

    // Then inline tokens within text nodes.
    visit(tree, "text", (node, index, parent) => {
      if (!parent || index === undefined) return;
      const replacement = tokenizeText((node as Text).value);
      // No structural change (single text node identical to input) -> skip.
      if (replacement.length === 1 && replacement[0]!.type === "text") return;
      parent.children.splice(index, 1, ...replacement);
      return [SKIP, index + replacement.length];
    });
  };
}

export interface ParseResult {
  tree: Root;
  frontmatter: Frontmatter;
}

/** Parse markdown source into an augmented mdast tree + frontmatter. */
export function parseMarkdown(source: string): ParseResult {
  const { text, blocks } = extractLatexBlocks(source);
  const processor = unified()
    .use(remarkParse)
    .use(remarkFrontmatter, ["yaml"])
    .use(remarkGfm)
    .use(remarkMath)
    .use(remarkObsidian, blocks);

  // parse() builds the tree; runSync() applies transformers (remarkObsidian).
  const tree = processor.runSync(processor.parse(text)) as Root;

  const frontmatter = extractFrontmatter(tree);
  return { tree, frontmatter };
}

/** Pull the leading YAML node (if any) and parse it. */
function extractFrontmatter(tree: Root): Frontmatter {
  const fm: Frontmatter = { raw: {} };
  const first = tree.children[0];
  if (first && first.type === "yaml") {
    let data: unknown;
    try {
      data = parseYaml(first.value);
    } catch {
      data = undefined;
    }
    if (data && typeof data === "object") {
      const obj = data as Record<string, unknown>;
      fm.raw = obj;
      if (typeof obj.title === "string") fm.title = obj.title;
      if (typeof obj.author === "string" || Array.isArray(obj.author))
        fm.author = obj.author as string | string[];
      if (obj.date != null) fm.date = String(obj.date);
      if (typeof obj.template === "string") fm.template = obj.template;
      if (typeof obj.bibliography === "string")
        fm.bibliography = obj.bibliography;
    }
    // Remove the yaml node so the emitter never sees it.
    tree.children.shift();
  }
  return fm;
}
