/**
 * templates.ts — load a .tex template and fill placeholders.
 *
 * Placeholder syntax is `{{KEY}}` (uppercase). Recognized keys:
 *   {{PREAMBLE}}  — package directives from preamble.ts
 *   {{TITLE}}     — document title (already LaTeX-escaped by caller)
 *   {{AUTHOR}}    — author(s)
 *   {{DATE}}      — date, or \today
 *   {{BODY}}      — converted document body
 *   {{BIB}}       — \printbibliography (or empty)
 *
 * A frontmatter `template:` value selects the template id; unknown ids fall
 * back to "article". Templates live in /templates and are injected by the
 * host (the CLI reads them from disk; the Swift shell will bundle them).
 */

export interface TemplateFields {
  preamble: string;
  title: string;
  author: string;
  date: string;
  body: string;
  bib: string;
}

const PLACEHOLDER: Record<string, keyof TemplateFields> = {
  "{{PREAMBLE}}": "preamble",
  "{{TITLE}}": "title",
  "{{AUTHOR}}": "author",
  "{{DATE}}": "date",
  "{{BODY}}": "body",
  "{{BIB}}": "bib",
};

/** Fill a raw template string with the given fields. Unknown placeholders are
 * left intact; missing fields render as empty. */
export function fillTemplate(template: string, fields: TemplateFields): string {
  return template.replace(/\{\{[A-Z]+\}\}/g, (token) => {
    const field = PLACEHOLDER[token];
    return field ? (fields[field] ?? "") : token;
  });
}

/** A minimal built-in fallback template, so conversion never hard-depends on
 * the /templates directory being present (e.g. in unit tests). */
export const BUILTIN_ARTICLE = `\\documentclass[11pt]{article}
{{PREAMBLE}}
\\title{{{TITLE}}}
\\author{{{AUTHOR}}}
\\date{{{DATE}}}
\\begin{document}
\\maketitle
{{BODY}}
{{BIB}}
\\end{document}
`;

/** Resolve a template by id from a provided map, falling back to the built-in. */
export function resolveTemplate(
  id: string | undefined,
  templates: Record<string, string> | undefined,
): string {
  if (id && templates && templates[id]) return templates[id]!;
  if (templates && templates["article"]) return templates["article"]!;
  return BUILTIN_ARTICLE;
}
