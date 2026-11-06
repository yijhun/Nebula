/**
 * index.ts — public entry point for the Markdown -> LaTeX converter.
 *
 * `convert()` ties together parser -> emitter -> bib -> preamble -> template.
 */
import { parseMarkdown } from "./parser.js";
import { emit } from "./emitter.js";
import { buildPreamble } from "./preamble.js";
import { buildBib } from "./bib.js";
import {
  fillTemplate,
  resolveTemplate,
  type TemplateFields,
} from "./templates.js";
import { CONVERTER_TEMPLATES } from "./builtin-templates.js";
import { chartBlocksToTikz } from "../editor/chartTikz.js";

/** Templates cited with natbib, and their `.bst` style. */
export const NATBIB_TEMPLATES: Record<string, string> = {
  apj: "aasjournal",
  mnras: "mnras",
  aanda: "aa",
  // Not a journal class, but for astronomy papers: references the way ApJ
  // prints them — "(Sandell et al. 2020)" in the text, and
  // "Sandell, G., Wright, M., Güsten, R., et al. 2020, ApJ, 904, 139" in the
  // list — instead of biblatex's numeric style with ISSN/URL/"visited on".
  // (`article`, the plain fallback, keeps biblatex.)
  academic: "aasjournal",
};

/** Of those, the journal classes that bring natbib (and hyperref) themselves;
 * the others need the preamble to load them. */
const CLASS_PROVIDES_NATBIB = new Set(["apj", "mnras", "aanda"]);
import { escapeLatex } from "./emitter.js";
import type { Asset, ConvertOptions, ConvertResult } from "./types.js";

export * from "./types.js";
export { parseMarkdown } from "./parser.js";
export { emit, escapeLatex } from "./emitter.js";
export { buildBib, parseBibtex, filterBibtex, referencesToBibtex } from "./bib.js";

const CJK_RE =
  /[㐀-䶿一-鿿぀-ゟ゠-ヿ가-힯豈-﫿ｦ-ﾟ]/;

/** Heuristic: does the source contain CJK characters? */
export function containsCJK(text: string): boolean {
  return CJK_RE.test(text);
}

function authorField(author: string | string[] | undefined): string {
  if (!author) return "";
  if (Array.isArray(author)) {
    return author.map((a) => escapeLatex(a)).join(" \\and ");
  }
  return escapeLatex(author);
}

/** The bibliography commands. In a plain class (academic) the list is set
 * single-spaced like a journal's, even when the body uses 1.5 spacing. */
function bibBlock(style: string, plainClass: boolean): string {
  const cmds = `\\bibliographystyle{${style}}\n\\bibliography{references}`;
  return plainClass
    ? `\\begingroup\n\\ifdefined\\singlespacing\\singlespacing\\fi\n${cmds}\n\\endgroup`
    : cmds;
}

/** Convert Obsidian-flavored Markdown to a complete LaTeX document. */
export function convert(source: string, options: ConvertOptions = {}): ConvertResult {
  // Draft ```chart blocks become real pgfplots figures in the paper (blocks
  // that fail to translate stay put and get skipped with a comment).
  source = chartBlocksToTikz(source);
  const { tree, frontmatter } = parseMarkdown(source);

  // Resolve the template first: the astronomy journal classes need natbib
  // citations (they reject biblatex), and each has its own .bst style.
  const templateId =
    options.template ?? frontmatter.template ?? options.defaultTemplate ?? "article";
  const natbibStyle = NATBIB_TEMPLATES[templateId];
  const bibMode = natbibStyle ? "natbib" : "biblatex";

  const { body, citationKeys, assets, features } = emit(tree, { citeStyle: bibMode });

  const cjk = options.cjk ?? containsCJK(source);

  const bib = buildBib(options.bib, citationKeys);
  const bibResource = "references.bib";
  const allAssets: Asset[] = [...assets];
  if (features.has("biblatex") || features.has("natbib")) {
    allAssets.push({ kind: "bibliography", ref: bibResource, resolved: bib.length > 0 });
  }

  const preamble = buildPreamble(features, {
    cjk,
    bibResource,
    unicodeText: source,
    bibMode,
    loadNatbib: bibMode === "natbib" && !CLASS_PROVIDES_NATBIB.has(templateId),
    ...(options.bibBackend ? { bibBackend: options.bibBackend } : {}),
  });

  const templates = options.templates ?? CONVERTER_TEMPLATES;
  const template = resolveTemplate(templateId, templates);

  const title = escapeLatex(options.title ?? frontmatter.title ?? "");
  const author = options.author
    ? escapeLatex(options.author)
    : authorField(frontmatter.author);
  const date =
    options.date !== undefined
      ? options.date === ""
        ? ""
        : escapeLatex(options.date)
      : frontmatter.date
        ? escapeLatex(frontmatter.date)
        : "\\today";

  const fields: TemplateFields = {
    preamble,
    title,
    author,
    date,
    body,
    bib: features.has("natbib")
      ? bibBlock(natbibStyle ?? "aasjournal", !CLASS_PROVIDES_NATBIB.has(templateId))
      : features.has("biblatex") ? "\\printbibliography" : "",
  };

  const tex = fillTemplate(template, fields);

  return {
    tex,
    body,
    bib,
    citationKeys,
    assets: allAssets,
    frontmatter,
    cjk,
    bibFormat: bibMode === "natbib" ? "bibtex" : "biblatex",
  };
}
