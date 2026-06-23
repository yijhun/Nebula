/**
 * to-markdown.ts — LaTeX → Obsidian-flavored Markdown (the reverse of emitter.ts).
 *
 * This is a best-effort inverse of the canonical Markdown→LaTeX mapping. It is
 * tuned to the exact constructs emitter.ts produces, so round-tripping a .tex
 * that Notepro itself generated is faithful. Hand-written LaTeX that uses
 * commands/environments outside that set is passed through verbatim (so nothing
 * is silently dropped — it shows up literally for the user to fix).
 */

/** Private-use sentinel that brackets protected (verbatim/math) regions. */
const SENT = "\uE000";

/** Unescape the LaTeX-special replacements escapeLatex() introduces. */
function unescapeLatex(s: string): string {
  return s
    .replace(/\\textbackslash\{\}/g, "\\")
    .replace(/\\textasciitilde\{\}/g, "~")
    .replace(/\\textasciicircum\{\}/g, "^")
    .replace(/\\([&%$#_{}])/g, "$1");
}

/** Convert a `\begin{tabular}` body (rows separated by `\\`, `\hline` rules). */
function tabularToMd(inner: string): string {
  const rows = inner
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && l !== "\\hline")
    .map((l) => l.replace(/\\\\\s*$/, "").trim());
  if (!rows.length) return "";
  const cells = rows.map((r) => r.split(" & ").map((c) => c.trim()));
  const cols = cells[0]!.length;
  const sep = Array(cols).fill("---");
  const lines = [
    `| ${cells[0]!.join(" | ")} |`,
    `| ${sep.join(" | ")} |`,
    ...cells.slice(1).map((r) => `| ${r.join(" | ")} |`),
  ];
  return `\n${lines.join("\n")}\n\n`;
}

/** Convert `\begin{quote}…\end{quote}` — plain blockquote or a callout. */
function quoteToMd(inner: string): string {
  const trimmed = inner.trim();
  // Callout shape: \textbf{[Label: title]}\par  …
  const m = /^\\textbf\{\[([^\]]*)\]\}\\par\s*([^]*)$/.exec(trimmed);
  if (m) {
    const head = m[1]!; // "Label" or "Label: title"
    const ci = head.indexOf(":");
    const type = (ci >= 0 ? head.slice(0, ci) : head).trim().toLowerCase();
    const title = ci >= 0 ? head.slice(ci + 1).trim() : "";
    const bodyLines = m[2]!.trim().split("\n");
    const out = [`> [!${type}]${title ? " " + title : ""}`, ...bodyLines.map((l) => `> ${l}`)];
    return `\n${out.join("\n")}\n\n`;
  }
  const lines = trimmed.split("\n").map((l) => `> ${l}`);
  return `\n${lines.join("\n")}\n\n`;
}

/** Walk itemize/enumerate environments, emitting nested Markdown list items. */
function convertLists(body: string): string {
  const lines = body.split("\n");
  const out: string[] = [];
  const stack: { ordered: boolean; n: number }[] = [];

  for (const raw of lines) {
    const line = raw.trimEnd();
    const beginM = /^\s*\\begin\{(itemize|enumerate)\}\s*$/.exec(line);
    const endM = /^\s*\\end\{(itemize|enumerate)\}\s*$/.exec(line);
    const setc = /^\s*\\setcounter\{enumi\}\{(\d+)\}\s*$/.exec(line);
    if (beginM) {
      stack.push({ ordered: beginM[1] === "enumerate", n: 1 });
      continue;
    }
    if (endM) {
      stack.pop();
      continue;
    }
    if (setc && stack.length) {
      stack[stack.length - 1]!.n = Number(setc[1]) + 1;
      continue;
    }
    const itemM = /^\s*\\item(?:\[(.*?)\])?\s?([^]*)$/.exec(line);
    if (itemM && stack.length) {
      const depth = stack.length - 1;
      const indent = "  ".repeat(depth);
      const top = stack[stack.length - 1]!;
      const optional = itemM[1];
      let marker: string;
      if (optional === "☑") marker = "- [x]";
      else if (optional === "☐") marker = "- [ ]";
      else if (top.ordered) marker = `${top.n++}.`;
      else marker = "-";
      out.push(`${indent}${marker} ${itemM[2]!.trim()}`);
      continue;
    }
    out.push(raw);
  }
  return out.join("\n");
}

/** Iteratively rewrite inline commands from the innermost brace outward. */
function convertInline(s: string): string {
  let prev: string;
  do {
    prev = s;
    s = s
      .replace(/\\textbf\{([^{}]*)\}/g, "**$1**")
      .replace(/\\emph\{([^{}]*)\}/g, "*$1*")
      .replace(/\\textit\{([^{}]*)\}/g, "*$1*")
      .replace(/\\sout\{([^{}]*)\}/g, "~~$1~~")
      .replace(/\\href\{([^{}]*)\}\{([^{}]*)\}/g, "[$2]($1)")
      .replace(/\\texttt\{\[\[([^{}]*)\]\]\}/g, "![[$1]]")
      .replace(/\\texttt\{([^{}]*)\}/g, "`$1`")
      .replace(/\\footnote\{([^{}]*)\}/g, "^[$1]")
      .replace(/\\includegraphics(?:\[[^\]]*\])?\{([^{}]*)\}/g, "![]($1)");
  } while (s !== prev);
  return s;
}

/** Turn \autocite / \autocites variants into Pandoc-style [@key] citations. */
function convertCitations(s: string): string {
  // \autocites[suf]{a}[suf]{b}…  → [@a suf; @b suf]
  s = s.replace(/\\autocites((?:\[[^\]]*\]\{[^{}]*\})+)/g, (_m, body: string) => {
    const parts = [...body.matchAll(/\[([^\]]*)\]\{([^{}]*)\}/g)].map(
      (mm) => `@${mm[2]}${mm[1] ? " " + mm[1] : ""}`,
    );
    return `[${parts.join("; ")}]`;
  });
  // \autocite[suffix]{key}
  s = s.replace(/\\autocite\[([^\]]*)\]\{([^{}]*)\}/g, (_m, suf: string, k: string) =>
    suf ? `[@${k} ${suf}]` : `[@${k}]`,
  );
  // \autocite{a,b}
  s = s.replace(/\\autocite\{([^{}]*)\}/g, (_m, keys: string) =>
    `[${keys.split(",").map((k) => `@${k.trim()}`).join("; ")}]`,
  );
  return s;
}

/** Recover a YAML frontmatter block from \title / \author / \date (preamble). */
function recoverFrontmatter(preamble: string): string {
  const fields: string[] = [];
  const title = /\\title\{([^]*?)\}/.exec(preamble);
  const author = /\\author\{([^]*?)\}/.exec(preamble);
  const date = /\\date\{([^]*?)\}/.exec(preamble);
  if (title && title[1]!.trim()) fields.push(`title: ${unescapeLatex(title[1]!.trim())}`);
  if (author && author[1]!.trim()) {
    const authors = author[1]!
      .split("\\and")
      .map((a) => unescapeLatex(a.trim()))
      .filter(Boolean);
    if (authors.length === 1) fields.push(`author: ${authors[0]}`);
    else if (authors.length > 1) fields.push(`author:\n${authors.map((a) => `  - ${a}`).join("\n")}`);
  }
  if (date && date[1]!.trim() && date[1]!.trim() !== "\\today") {
    fields.push(`date: ${unescapeLatex(date[1]!.trim())}`);
  }
  return fields.length ? `---\n${fields.join("\n")}\n---\n\n` : "";
}

/** Convert a (full or fragment) LaTeX document to Obsidian-flavored Markdown. */
export function latexToMarkdown(tex: string): string {
  const src = tex.replace(/\r\n/g, "\n");

  const begin = src.indexOf("\\begin{document}");
  const end = src.lastIndexOf("\\end{document}");
  const hasDoc = begin >= 0 && end > begin;
  const preamble = hasDoc ? src.slice(0, begin) : "";
  let body = hasDoc ? src.slice(begin + "\\begin{document}".length, end) : src;

  body = body
    .replace(/\\maketitle\s*/g, "")
    .replace(/\\printbibliography\s*/g, "")
    .replace(/\\tableofcontents\s*/g, "")
    // Normalize task-list markers before math protection swallows $…$.
    .replace(/\\item\[\$\\boxtimes\$\]/g, "\\item[☑]")
    .replace(/\\item\[\$\\square\$\]/g, "\\item[☐]");

  // 1. Protect verbatim + math so later passes don't touch their contents.
  const stash: string[] = [];
  const ph = (s: string): string => {
    stash.push(s);
    return `${SENT}${stash.length - 1}${SENT}`;
  };
  body = body.replace(
    /(?:% language: ([^\n]*)\n)?\\begin\{verbatim\}\n([^]*?)\n\\end\{verbatim\}/g,
    (_m, lang: string | undefined, code: string) =>
      ph("```" + (lang ? lang.trim() : "") + "\n" + code + "\n```"),
  );
  // Raw LaTeX environments we don't translate (equation, align, figure, …) are
  // kept verbatim so hand-written/passed-through LaTeX survives the round trip.
  body = body.replace(
    /\\begin\{(?!itemize|enumerate|quote|center|tabular|verbatim)([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}/g,
    (m) => ph(m),
  );
  body = body.replace(/\\\[\s*([^]*?)\s*\\\]/g, (_m, e: string) => ph("$$\n" + e.trim() + "\n$$"));
  body = body.replace(/\$([^$]+)\$/g, (_m, e: string) => ph("$" + e + "$"));

  // 2. Block-level environments.
  body = body.replace(
    /\\begin\{center\}\s*\\includegraphics(?:\[[^\]]*\])?\{([^}]*)\}\s*\\end\{center\}/g,
    (_m, p: string) => `\n![[${p}]]\n`,
  );
  body = body.replace(
    /\\begin\{center\}\\rule\{[^}]*\}\{[^}]*\}\\end\{center\}/g,
    "\n---\n",
  );
  body = body.replace(
    /\\begin\{center\}\n\\begin\{tabular\}\{[^}]*\}\n([^]*?)\n\\end\{tabular\}\n\\end\{center\}/g,
    (_m, inner: string) => tabularToMd(inner),
  );
  body = body.replace(/\\begin\{quote\}\n([^]*?)\n\\end\{quote\}/g, (_m, inner: string) =>
    quoteToMd(inner),
  );

  // 3. Lists (line-based, supports nesting).
  body = convertLists(body);

  // 4. Inline commands + citations, then headings (so heading text is converted).
  body = convertCitations(body);
  body = convertInline(body);
  body = body
    .replace(/\\subsubsection\*?\{([^{}]*)\}/g, "### $1")
    .replace(/\\subsection\*?\{([^{}]*)\}/g, "## $1")
    .replace(/\\section\*?\{([^{}]*)\}/g, "# $1")
    .replace(/\\subparagraph\*?\{([^{}]*)\}/g, "##### $1")
    .replace(/\\paragraph\*?\{([^{}]*)\}/g, "#### $1");
  body = body.replace(/\\\\\n/g, "  \n"); // line break

  // 5. Unescape, tidy whitespace.
  body = unescapeLatex(body);
  body = body.replace(/\n{3,}/g, "\n\n").trim();

  // 6. Restore protected verbatim/math regions.
  body = body.replace(new RegExp(`${SENT}(\\d+)${SENT}`, "g"), (_m, i: string) => stash[Number(i)]!);

  const fm = hasDoc ? recoverFrontmatter(preamble) : "";
  return fm + body + "\n";
}
