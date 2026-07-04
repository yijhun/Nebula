/**
 * project.ts — multi-file ("project") Markdown → LaTeX assembly.
 *
 * A Notepro project compiles several Markdown chapters into ONE paper. This
 * supports both shapes the user wants:
 *   - per-chapter `.tex`: each chapter md → its own body fragment (like the
 *     single-note conversion), written to `build/chapters/<name>.tex`;
 *   - merged paper: a master `build/paper.tex` with the shared preamble that
 *     `\input`s each chapter in order (one compile → cross-refs/cites/bib all
 *     resolve across chapters);
 *   - flattened single file: `paper-flat.tex` with every chapter body inlined,
 *     for journal submission ("md 合併成單一個 latex").
 *
 * It reuses the same parser/emitter/preamble/template stack as `convert()`, but
 * unions the detected features/citation keys across all chapters so the single
 * shared preamble covers everything.
 */
import { parseMarkdown } from "./parser.js";
import { emit, escapeLatex, type Feature } from "./emitter.js";
import { buildPreamble } from "./preamble.js";
import { buildBib } from "./bib.js";
import { fillTemplate, resolveTemplate, type TemplateFields } from "./templates.js";
import { CONVERTER_TEMPLATES } from "./builtin-templates.js";
import { containsCJK, NATBIB_TEMPLATES } from "./index.js";

export interface ProjectChapterInput {
  /** Source filename, e.g. "01-intro.md". */
  name: string;
  /** Raw Markdown of the chapter. */
  md: string;
}

export interface ProjectChapterOutput {
  /** Output filename, e.g. "01-intro.tex". */
  name: string;
  /** The chapter body LaTeX (no preamble, no \begin{document}). */
  body: string;
}

export interface ProjectConvertOptions {
  template?: string;
  title?: string;
  author?: string;
  date?: string;
  bibBackend?: "biber" | "bibtex";
  cjk?: boolean;
}

export interface ProjectConvertResult {
  /** Master document: preamble + title + \input{chapters/...} per chapter. */
  master: string;
  /** Self-contained single file with every chapter body inlined. */
  flat: string;
  /** Per-chapter body fragments to write under build/chapters/. */
  chapters: ProjectChapterOutput[];
  /** Union of citation keys across all chapters (host resolves the .bib). */
  citationKeys: string[];
  cjk: boolean;
}

/** Strip a trailing ".md"/".markdown" → bare basename (for the chapter .tex). */
function baseName(name: string): string {
  return name.replace(/\.(md|markdown)$/i, "");
}

/** Convert an ordered list of Markdown chapters into a single paper. */
export function convertProject(
  chapters: ProjectChapterInput[],
  options: ProjectConvertOptions = {},
): ProjectConvertResult {
  const features = new Set<Feature>();
  const citationKeys: string[] = [];
  const seenKeys = new Set<string>();
  const outputs: ProjectChapterOutput[] = [];
  const bodies: string[] = [];
  let anyCJK = false;
  let firstTitle = "";
  let firstAuthor: string | string[] | undefined;
  let firstDate: string | undefined;

  const templateId = options.template ?? "article";
  const natbibStyle = NATBIB_TEMPLATES[templateId];
  const bibMode = natbibStyle ? "natbib" : "biblatex";

  for (const ch of chapters) {
    const { tree, frontmatter } = parseMarkdown(ch.md);
    const r = emit(tree, { citeStyle: bibMode });
    r.features.forEach((f) => features.add(f));
    for (const k of r.citationKeys) {
      if (!seenKeys.has(k)) { seenKeys.add(k); citationKeys.push(k); }
    }
    if (containsCJK(ch.md)) anyCJK = true;
    if (!firstTitle && frontmatter.title) firstTitle = frontmatter.title;
    if (firstAuthor === undefined && frontmatter.author) firstAuthor = frontmatter.author;
    if (firstDate === undefined && frontmatter.date) firstDate = frontmatter.date;
    outputs.push({ name: baseName(ch.name) + ".tex", body: r.body });
    bodies.push(r.body);
  }

  const cjk = options.cjk ?? anyCJK;
  const bibResource = "references.bib";
  const preamble = buildPreamble(features, {
    cjk,
    bibResource,
    unicodeText: chapters.map((c) => c.md).join("\n"),
    bibMode,
    ...(options.bibBackend ? { bibBackend: options.bibBackend } : {}),
  });

  const template = resolveTemplate(templateId, CONVERTER_TEMPLATES);

  const title = escapeLatex(options.title ?? firstTitle ?? "");
  const author = options.author
    ? escapeLatex(options.author)
    : Array.isArray(firstAuthor)
      ? firstAuthor.map((a) => escapeLatex(a)).join(" \\and ")
      : escapeLatex(firstAuthor ?? "");
  const date =
    options.date !== undefined
      ? (options.date === "" ? "" : escapeLatex(options.date))
      : firstDate ? escapeLatex(firstDate) : "\\today";

  const bibField = features.has("natbib")
    ? `\\bibliographystyle{${natbibStyle ?? "aasjournal"}}\n\\bibliography{references}`
    : features.has("biblatex") ? "\\printbibliography" : "";

  const inputBody = outputs
    .map((o) => `\\input{chapters/${baseName(o.name)}}`)
    .join("\n\n");
  const flatBody = bodies.join("\n\n");

  const base = (body: string): TemplateFields => ({
    preamble, title, author, date, body, bib: bibField,
  });

  return {
    master: fillTemplate(template, base(inputBody)),
    flat: fillTemplate(template, base(flatBody)),
    chapters: outputs,
    citationKeys,
    cjk,
  };
}
