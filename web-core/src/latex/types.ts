/**
 * Shared types for the Markdown -> LaTeX converter (M1).
 *
 * The parser produces a standard mdast tree (via remark) that we augment with
 * a small set of Obsidian-flavored custom nodes. These node types are declared
 * here and registered onto mdast's content model so the emitter can switch on
 * them with full type safety.
 */
import type { Parent, Literal } from "mdast";

/** `[[target]]` or `[[target|alias]]` — an internal note link. */
export interface WikiLink extends Literal {
  type: "wikiLink";
  /** The link target (note name / path), without brackets or alias. */
  target: string;
  /** Optional display alias (the part after `|`). */
  alias?: string;
  /** Optional `#heading` fragment, if the target was `target#heading`. */
  heading?: string;
}

/** `![[target]]` or `![[target|alias]]` — an embedded note/asset. */
export interface Embed extends Literal {
  type: "embed";
  target: string;
  alias?: string;
  /** True when `target` looks like an image we can `\includegraphics`. */
  isImage: boolean;
}

/** A single Pandoc-style citation reference inside a `[@...]` group. */
export interface CitationItem {
  key: string;
  /** Locator / suffix text, e.g. "p. 5" from `[@key, p. 5]`. */
  suffix?: string;
}

/** `[@key]`, `[@key, p. 5]`, or `[@a; @b]` — one or more citations. */
export interface Citation extends Literal {
  type: "citation";
  items: CitationItem[];
}

/** Raw LaTeX written directly in Markdown (e.g. `\begin{equation}…\end{equation}`
 * or `\[ … \]`). Passed through verbatim to the LaTeX emitter; rendered by
 * KaTeX in the preview. */
export interface LatexBlock extends Literal {
  type: "latexBlock";
  /** Standalone block (environment / `\[..\]`) vs inline command in prose. */
  display?: boolean;
}

/** Obsidian callout: a `> [!type] Title` blockquote. */
export interface Callout extends Parent {
  type: "callout";
  /** Lowercased callout type, e.g. "warning", "note", "info". */
  calloutType: string;
  /** Optional title text following the `[!type]` marker. */
  title?: string;
  /** Whether the callout was marked foldable (`[!type]+` / `[!type]-`). */
  folded?: boolean;
}

// Register the custom nodes on mdast's maps so unist-util-visit and the
// emitter see them as first-class members of the content model.
declare module "mdast" {
  interface RootContentMap {
    wikiLink: WikiLink;
    embed: Embed;
    citation: Citation;
    callout: Callout;
    latexBlock: LatexBlock;
  }
  interface PhrasingContentMap {
    wikiLink: WikiLink;
    embed: Embed;
    citation: Citation;
    latexBlock: LatexBlock;
  }
  interface BlockContentMap {
    callout: Callout;
    latexBlock: LatexBlock;
  }
}

/** Frontmatter we understand; unknown keys are preserved in `raw`. */
export interface Frontmatter {
  title?: string;
  author?: string | string[];
  date?: string;
  /** Template id to render with, e.g. "article" | "academic" | "beamer". */
  template?: string;
  /** Bibliography database file (path), if the note cites sources. */
  bibliography?: string;
  /** Arbitrary additional keys from the YAML block. */
  raw: Record<string, unknown>;
}

/** An external resource referenced by the document (image, embed, bib). */
export interface Asset {
  kind: "image" | "embed" | "bibliography";
  /** The reference as written in the source. */
  ref: string;
  /** Whether we could resolve it to something includable. */
  resolved: boolean;
}

export interface ConvertOptions {
  /** Explicit template id (highest priority). */
  template?: string;
  /** Fallback template when neither `template` nor frontmatter `template` is set
   * (the user's "default LaTeX template" setting). */
  defaultTemplate?: string;
  /** Force CJK preamble even if no CJK detected. Default: auto-detect. */
  cjk?: boolean;
  /** Override document title (else frontmatter `title`). */
  title?: string;
  /** Override author (else frontmatter `author`). */
  author?: string;
  /** Override date; pass "" to omit, undefined for `\today`. */
  date?: string;
  /** Map of template id -> raw .tex template string. */
  templates?: Record<string, string>;
  /** Bibliography database: either raw .bib text or structured references. */
  bib?: BibSource;
  /** biblatex backend. Default "biber" (plan's choice). Use "bibtex" when the
   * local biber is incompatible with the TeX bundle's biblatex (e.g. compiling
   * with Tectonic against a very new system biber). */
  bibBackend?: "biber" | "bibtex";
}

/** A structured reference (Zotero-like) usable to synthesize a .bib entry. */
export interface Reference {
  key: string;
  /** biblatex entry type, e.g. "article", "book". Default "misc". */
  entryType?: string;
  title?: string;
  authors?: string[];
  year?: number | string;
  journal?: string;
  url?: string;
  /** Any extra biblatex fields. */
  fields?: Record<string, string | number>;
}

export type BibSource =
  | { kind: "bibtex"; text: string }
  | { kind: "references"; entries: Reference[] };

/** The full result of converting a markdown document. */
export interface ConvertResult {
  /** Final, template-filled LaTeX document. */
  tex: string;
  /** Just the converted body (no template/preamble), for debugging/tests. */
  body: string;
  /** Filtered .bib containing only cited entries, or "" if no citations. */
  bib: string;
  /** Citation keys encountered, in first-seen order. */
  citationKeys: string[];
  /** External assets referenced by the document. */
  assets: Asset[];
  /** Parsed frontmatter. */
  frontmatter: Frontmatter;
  /** Whether CJK content was detected/enabled. */
  cjk: boolean;
}
