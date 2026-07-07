/**
 * preview.ts — Markdown -> HTML for the live preview pane.
 *
 * A separate, HTML-targeted pipeline (the LaTeX emitter is for export). Reuses
 * the same remark stack: GFM + math (KaTeX) + frontmatter (stripped from view).
 * Obsidian-specific syntax (wikilinks/callouts/embeds) renders as plain text in
 * v1 — full preview fidelity is a later increment.
 */
import { unified, type Processor } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkFrontmatter from "remark-frontmatter";
import remarkRehype from "remark-rehype";
import rehypeStringify from "rehype-stringify";
import { visit, SKIP } from "unist-util-visit";
import { fromHtml } from "hast-util-from-html";
import type { Root, Text } from "mdast";
import { extractLatexBlocks, splitOnLatexPlaceholders, type ExtractedBlock } from "../latex/parser.js";
import { noteExists } from "./notes.js";
import { tex2svg } from "./mathjax.js";
import { renderChart } from "./chart.js";
import { parseDiagramModel, diagramToSvg } from "./diagramStudio.js";
import { parseDiagram3dModel, diagram3dToSvg } from "./diagram3d.js";

/** Matches a `[@key]`, `[@a; @b]`, `[@key, p. 5]` citation group. */
const CITE_RE = /\[([^\]\[\n]*@[^\]\n]*)\]/g;

/** Maps a citekey to a display label, e.g. "Chen et al. (1997)". Set by the
 * host (it fetches real author/year from Zotero); defaults to the raw key. */
let resolveLabel: (key: string) => string = (k) => k;
export function setCiteLabelResolver(fn: (key: string) => string): void {
  resolveLabel = fn;
}

/** Citekeys seen in the last render (so the host can fetch missing labels). */
let lastCiteKeys: string[] = [];
export function getLastCiteKeys(): string[] {
  return lastCiteKeys;
}

/** Blocks extracted from the current render (set by renderHtml, read by plugin). */
let currentBlocks: ExtractedBlock[] = [];

// Base paths (pushed from native) for resolving images in the vault.
let noteDir = "";
let vaultDir = "";
export function setBasePaths(note: string, vault: string): void {
  noteDir = note;
  vaultDir = vault;
}

const IMAGE_EXT = /\.(png|jpe?g|gif|svg|webp|bmp|tiff?)$/i;

/** Map an image reference (relative path or vault filename) to the npimg:// URL
 * the native scheme handler serves. Leaves http/data/npimg URLs untouched. */
export function imgSrc(ref: string): string {
  if (/^(https?:|data:|npimg:)/i.test(ref)) return ref;
  return `npimg://load?ref=${encodeURIComponent(ref)}&base=${encodeURIComponent(noteDir)}&vault=${encodeURIComponent(vaultDir)}`;
}

/** `![[image.png]]` / `![[image.png|300]]` Obsidian embeds → image nodes
 * (image ext only). `|<width>` sets the display width (drag-to-resize writes it). */
const EMBED_RE = /!\[\[([^\]\n|]+?)(?:\|([^\]\n]*))?\]\]/g;
function remarkEmbedImages() {
  return (tree: Root) => {
    visit(tree, "text", (node: Text, index, parent) => {
      if (!parent || index == null || !node.value.includes("![[")) return;
      const value = node.value;
      const parts: Array<Text | Record<string, unknown>> = [];
      let last = 0;
      let m: RegExpExecArray | null;
      EMBED_RE.lastIndex = 0;
      while ((m = EMBED_RE.exec(value))) {
        const ref = m[1]!.trim();
        if (!IMAGE_EXT.test(ref)) continue; // non-image embeds left as-is
        if (m.index > last) parts.push({ type: "text", value: value.slice(last, m.index) } as Text);
        const w = /^\d+/.exec((m[2] ?? "").trim())?.[0];
        const hProps: Record<string, unknown> = { "data-ref": ref };
        if (w) hProps.style = `width:${w}px`;
        parts.push({ type: "image", url: ref, alt: ref, data: { hProperties: hProps } } as unknown as Record<string, unknown>);
        last = m.index + m[0].length;
      }
      if (!parts.length) return;
      if (last < value.length) parts.push({ type: "text", value: value.slice(last) } as Text);
      parent.children.splice(index, 1, ...(parts as Text[]));
      return [SKIP, index + parts.length];
    });
  };
}

/** Render `.math-inline`/`.math-display` elements to SVG via the cached MathJax
 * (replaces rehype-mathjax; unchanged equations are not re-typeset). */
function rehypeCachedMathjax() {
  return (tree: unknown) => {
    visit(tree as Root, "element", (node: Record<string, unknown>) => {
      const cls = (node.properties as { className?: unknown })?.className;
      const list = Array.isArray(cls) ? (cls as string[]) : [];
      const display = list.includes("math-display");
      if (!display && !list.includes("math-inline")) return;
      const tex = (node.children as Array<{ value?: string }> | undefined)
        ?.map((c) => c.value ?? "").join("") ?? "";
      const frag = fromHtml(tex2svg(tex, display), { fragment: true });
      node.children = frag.children as unknown[];
    });
  };
}

/** Render ```chart code blocks into inline SVG charts (see chart.ts). */
function rehypeCharts() {
  return (tree: unknown) => {
    visit(tree as Root, "element", (node: Record<string, unknown>, index, parent) => {
      const par = parent as unknown as { children: unknown[] } | null;
      if (node.tagName !== "pre" || !par || index == null) return;
      const children = node.children as Array<Record<string, unknown>> | undefined;
      const code = children?.find((c) => c.tagName === "code");
      const cls = (code?.properties as { className?: unknown })?.className;
      const list = Array.isArray(cls) ? (cls as string[]) : [];
      const isChart = list.includes("language-chart");
      const isTikz = list.includes("language-tikz");
      if (!isChart && !isTikz) return;
      const src = ((code?.children as Array<{ value?: string }>) ?? [])
        .map((c) => c.value ?? "").join("");
      // ```chart → inline SVG sketch. ```tikz with a studio model → render the
      // model as SVG right here in the markdown preview (no compile needed).
      // Hand-written tikz → placeholder card (real render in the PDF preview).
      let html: string;
      if (isChart) {
        html = renderChart(src) +
          `<button class="np-chart-edit" title="互動編輯（滑桿調參數）">✎ 編輯</button>`;
      } else {
        const model = parseDiagramModel(src);
        const model3 = model ? null : parseDiagram3dModel(src);
        html = model && model.length
          ? diagramToSvg(model) +
            `<button class="np-chart-edit np-diagram-edit" title="用圖解編輯器打開">✎ 編輯</button>`
          : model3
          ? diagram3dToSvg(model3.objs, model3.cam) +
            `<button class="np-chart-edit np-diagram3d-edit" title="用 3D 編輯器打開">✎ 編輯</button>`
          : `<div class="np-tikz-placeholder">📐 TikZ 圖（LaTeX 原生）— 開「即時 PDF 預覽」或編譯後可見</div>`;
      }
      const frag = fromHtml(html, { fragment: true });
      const props = node.properties as Record<string, unknown> | undefined;
      par.children[index] = {
        type: "element",
        tagName: "div",
        properties: { className: ["np-chart-wrap"], dataLine: props?.["dataLine"] },
        children: frag.children,
      };
      return SKIP;
    });
  };
}

/** Rewrite every <img src> to the npimg:// scheme so vault images load. */
function rehypeImgSrc() {
  return (tree: unknown) => {
    visit(tree as Root, "element", (node: Record<string, unknown>) => {
      if (node.tagName !== "img") return;
      const props = (node.properties as Record<string, unknown>) ?? {};
      if (typeof props.src === "string") { props.src = imgSrc(props.src); node.properties = props; }
    });
  };
}

/** Build a KaTeX display-math hast node from a raw LaTeX block. */
function mathNode(raw: string): Record<string, unknown> {
  let tex = raw;
  // \[ … \] and the equation env (KaTeX numbers nothing) → bare display math.
  const eq = /^\\begin\{(equation\*?)\}([\s\S]*)\\end\{\1\}$/.exec(raw.trim());
  if (eq) tex = eq[2]!.trim();
  else if (tex.trim().startsWith("\\[")) tex = tex.trim().slice(2, -2).trim();
  return {
    type: "latexMath",
    data: {
      hName: "div",
      hProperties: { className: ["math", "math-display"] },
      hChildren: [{ type: "text", value: tex }],
    },
  };
}

/** Restore extracted raw-LaTeX placeholders: display blocks → KaTeX math;
 * inline commands → shown literally (no LaTeX engine to resolve refs/cites). */
function remarkLatexEnvironments() {
  return (tree: Root) => {
    visit(tree, "text", (node: Text, index, parent) => {
      if (!parent || index == null) return;
      // Inherit the parent text node's source position so `rehypeSourceLines`
      // can assign `data-line` and the preview's dblclick-to-jump finds it.
      // Without this, `$$…$$` blocks come in via placeholder substitution
      // and end up with no position → no data-line → dblclick is silent.
      const pos = node.position;
      const parts = splitOnLatexPlaceholders(node.value, currentBlocks, (b) =>
        b.display
          ? { ...mathNode(b.raw), position: pos }
          : ({ type: "inlineCode", value: b.raw, position: pos } as unknown as Record<string, unknown>),
      );
      if (!parts) return;
      parent.children.splice(index, 1, ...(parts as Text[]));
      return [SKIP, index + parts.length];
    });
  };
}

/** `[[target]]` / `[[target|alias]]` → a clickable wikilink span; flagged
 * broken (red) when the target isn't a known note. Click handled in main.ts. */
const WIKI_RE = /\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]/g;

function remarkWikiLinks() {
  return (tree: Root) => {
    visit(tree, "text", (node: Text, index, parent) => {
      if (!parent || index == null || !node.value.includes("[[")) return;
      const value = node.value;
      const parts: Array<Text | Record<string, unknown>> = [];
      let last = 0;
      let m: RegExpExecArray | null;
      WIKI_RE.lastIndex = 0;
      while ((m = WIKI_RE.exec(value))) {
        const target = m[1]!.trim();
        const label = (m[2] ?? m[1])!.trim();
        if (m.index > last) parts.push({ type: "text", value: value.slice(last, m.index) } as Text);
        const broken = !noteExists(target);
        parts.push({
          type: "wikilink",
          data: {
            hName: "a",
            hProperties: {
              className: broken ? ["np-wikilink", "np-wikilink-broken"] : ["np-wikilink"],
              "data-target": target,
              title: broken ? `找不到筆記：${target}` : target,
            },
            hChildren: [{ type: "text", value: label }],
          },
        });
        last = m.index + m[0].length;
      }
      if (!parts.length) return;
      if (last < value.length) parts.push({ type: "text", value: value.slice(last) } as Text);
      parent.children.splice(index, 1, ...(parts as Text[]));
      return [SKIP, index + parts.length];
    });
  };
}

/** Tag each rendered block with its source line (`data-line`) so the host can
 * jump the editor to it and keep the two panes aligned. Operates on hast. */
function rehypeSourceLines() {
  return (tree: unknown) => {
    visit(tree as Root, "element", (node: Record<string, unknown>) => {
      const pos = node.position as { start?: { line?: number } } | undefined;
      const line = pos?.start?.line;
      if (line) {
        const props = (node.properties as Record<string, unknown>) ?? {};
        props["dataLine"] = line;
        node.properties = props;
      }
    });
  };
}

/** Render Pandoc-style citations as styled inline spans (author-year format). */
function remarkCitations() {
  return (tree: Root) => {
    visit(tree, "text", (node: Text, index, parent) => {
      if (!parent || index == null || !node.value.includes("@")) return;
      const value = node.value;
      const parts: Array<Text | Record<string, unknown>> = [];
      let last = 0;
      let m: RegExpExecArray | null;
      CITE_RE.lastIndex = 0;
      while ((m = CITE_RE.exec(value))) {
        const keys = m[1]!
          .split(";")
          .map((s) => /@([^\s,\]]+)/.exec(s.trim())?.[1])
          .filter((k): k is string => !!k);
        if (!keys.length) continue;
        if (m.index > last) parts.push({ type: "text", value: value.slice(last, m.index) } as Text);
        keys.forEach((k) => lastCiteKeys.push(k));
        const display = keys.map((k) => resolveLabel(k)).join("; ");
        parts.push({
          type: "cite",
          data: {
            hName: "span",
            hProperties: { className: ["np-cite"], title: keys.join(", "), dataCite: keys[0] },
            hChildren: [{ type: "text", value: display }],
          },
        });
        last = m.index + m[0].length;
      }
      if (!parts.length) return;
      if (last < value.length) parts.push({ type: "text", value: value.slice(last) } as Text);
      parent.children.splice(index, 1, ...(parts as Text[]));
      return [SKIP, index + parts.length];
    });
  };
}

const processor: Processor = unified()
  .use(remarkParse)
  .use(remarkFrontmatter, ["yaml"])
  .use(remarkGfm)
  .use(remarkMath)
  .use(remarkLatexEnvironments)
  .use(remarkEmbedImages)
  .use(remarkWikiLinks)
  .use(remarkCitations)
  .use(remarkRehype)
  .use(rehypeSourceLines)
  .use(rehypeCharts)
  .use(rehypeImgSrc)
  .use(rehypeCachedMathjax)
  .use(rehypeStringify) as unknown as Processor;

/** Render Markdown to an HTML string (synchronously). Never throws. */
export function renderHtml(md: string): string {
  lastCiteKeys = [];
  try {
    const { text, blocks } = extractLatexBlocks(md);
    currentBlocks = blocks;
    return String(processor.processSync(text));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return `<pre class="np-preview-error">預覽錯誤 Preview error:\n${msg}</pre>`;
  }
}
