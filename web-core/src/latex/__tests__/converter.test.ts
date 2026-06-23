import { describe, it, expect } from "vitest";
import { convert, parseMarkdown, escapeLatex } from "../index.js";
import { emit } from "../emitter.js";
import { filterBibtex, referencesToBibtex, parseBibtex } from "../bib.js";

/** Convenience: parse + emit, returning just the body string. */
function body(md: string): string {
  const { tree } = parseMarkdown(md);
  return emit(tree).body;
}

describe("escapeLatex", () => {
  it("escapes LaTeX special characters", () => {
    expect(escapeLatex("100% & $5 #1 _x {y} ~ ^")).toBe(
      "100\\% \\& \\$5 \\#1 \\_x \\{y\\} \\textasciitilde{} \\textasciicircum{}",
    );
  });
  it("escapes backslash without re-escaping its replacement", () => {
    expect(escapeLatex("a\\b")).toBe("a\\textbackslash{}b");
  });
});

describe("inline formatting", () => {
  it("maps emphasis, strong, delete, inline code", () => {
    expect(body("*a* **b** ~~c~~ `d`")).toContain(
      "\\emph{a} \\textbf{b} \\sout{c} \\texttt{d}",
    );
  });
  it("maps headings by depth", () => {
    expect(body("# A")).toContain("\\section{A}");
    expect(body("## B")).toContain("\\subsection{B}");
    expect(body("### C")).toContain("\\subsubsection{C}");
  });
  it("maps links to \\href", () => {
    expect(body("[txt](http://x.com)")).toContain("\\href{http://x.com}{txt}");
  });
});

describe("math", () => {
  it("maps inline math", () => {
    expect(body("$E=mc^2$")).toContain("$E=mc^2$");
  });
  it("maps block math to display", () => {
    expect(body("$$\na=b\n$$")).toContain("\\[\na=b\n\\]");
  });
});

describe("wikilinks and embeds", () => {
  it("renders wikilink display text (alias preferred)", () => {
    expect(body("[[Note A|alias]]")).toContain("alias");
    expect(body("[[Note A]]")).toContain("Note A");
  });
  it("strips #heading from a bare wikilink target", () => {
    expect(body("[[Note A#Section]]")).toContain("Note A");
  });
  it("renders image embeds with includegraphics", () => {
    const { tree } = parseMarkdown("![[diagram.png]]");
    const r = emit(tree);
    expect(r.body).toContain("\\includegraphics[width=\\linewidth]{diagram.png}");
    expect(r.assets).toContainEqual({ kind: "image", ref: "diagram.png", resolved: true });
    expect(r.features.has("graphicx")).toBe(true);
  });
  it("renders non-image embeds as an unresolved placeholder", () => {
    const { tree } = parseMarkdown("![[Some Note]]");
    const r = emit(tree);
    expect(r.body).toContain("\\texttt{[[Some Note]]}");
    expect(r.assets).toContainEqual({ kind: "embed", ref: "Some Note", resolved: false });
  });
});

describe("citations", () => {
  it("maps a single citation", () => {
    const { tree } = parseMarkdown("text [@smith2020] end");
    const r = emit(tree);
    expect(r.body).toContain("\\autocite{smith2020}");
    expect(r.citationKeys).toEqual(["smith2020"]);
  });
  it("maps a citation with a locator suffix", () => {
    expect(body("[@dirac1930, p. 12]")).toContain("\\autocite[p. 12]{dirac1930}");
  });
  it("maps multiple keys in one group", () => {
    const { tree } = parseMarkdown("[@a; @b]");
    const r = emit(tree);
    expect(r.body).toContain("\\autocite{a,b}");
    expect(r.citationKeys).toEqual(["a", "b"]);
  });
  it("dedupes citation keys in first-seen order", () => {
    const { tree } = parseMarkdown("[@a] then [@b] then [@a]");
    expect(emit(tree).citationKeys).toEqual(["a", "b"]);
  });
});

describe("callouts", () => {
  it("converts a [!type] blockquote to a titled quote", () => {
    const md = "> [!warning] Be careful\n> body line";
    const out = body(md);
    expect(out).toContain("\\begin{quote}");
    expect(out).toContain("\\textbf{[Warning: Be careful]}");
    expect(out).toContain("body line");
  });
  it("handles a callout with no title", () => {
    expect(body("> [!note]\n> hi")).toContain("\\textbf{[Note]}");
  });
  it("leaves a plain blockquote alone", () => {
    const out = body("> just a quote");
    expect(out).toContain("\\begin{quote}");
    expect(out).not.toContain("\\textbf{[");
  });
});

describe("lists and tasks", () => {
  it("maps unordered lists to itemize", () => {
    expect(body("- a\n- b")).toContain("\\begin{itemize}");
  });
  it("maps ordered lists to enumerate", () => {
    expect(body("1. a\n2. b")).toContain("\\begin{enumerate}");
  });
  it("maps task list checkboxes", () => {
    const out = body("- [ ] todo\n- [x] done");
    expect(out).toContain("\\item[$\\square$] todo");
    expect(out).toContain("\\item[$\\boxtimes$] done");
  });
});

describe("tables", () => {
  it("maps a gfm table to tabular with alignment", () => {
    const md = "| A | B |\n| :--- | :---: |\n| 1 | 2 |";
    const out = body(md);
    expect(out).toContain("\\begin{tabular}{lc}");
    expect(out).toContain("A & B \\\\");
    expect(out).toContain("1 & 2 \\\\");
  });
});

describe("bib", () => {
  const db = `@book{dirac1930, title={QM}, author={Dirac}, year={1930}, note={a {b} c}}
@article{feynman1965, title={Lectures}}
@misc{uncited, title={no}}`;

  it("parses entries with nested braces", () => {
    const m = parseBibtex(db);
    expect([...m.keys()].sort()).toEqual(["dirac1930", "feynman1965", "uncited"]);
  });
  it("filters to cited keys in cited order", () => {
    const out = filterBibtex(db, ["feynman1965", "dirac1930"]);
    expect(out.indexOf("feynman1965")).toBeLessThan(out.indexOf("dirac1930"));
    expect(out).not.toContain("uncited");
  });
  it("synthesizes biblatex from structured references", () => {
    const out = referencesToBibtex(
      [{ key: "k1", entryType: "article", title: "T", authors: ["A B", "C D"], year: 2020 }],
      ["k1"],
    );
    expect(out).toContain("@article{k1,");
    expect(out).toContain("title = {T}");
    expect(out).toContain("author = {A B and C D}");
    expect(out).toContain("year = {2020}");
  });
});

describe("convert (end-to-end)", () => {
  it("reads frontmatter, selects template, and fills the document", () => {
    const md = `---\ntitle: My Doc\nauthor: Ada\n---\n# Hi\nbody`;
    const r = convert(md);
    expect(r.frontmatter.title).toBe("My Doc");
    expect(r.tex).toContain("\\documentclass");
    expect(r.tex).toContain("\\title{My Doc}");
    expect(r.tex).toContain("\\author{Ada}");
    expect(r.tex).toContain("\\section{Hi}");
    expect(r.tex).toContain("\\begin{document}");
    expect(r.tex).toContain("\\end{document}");
  });
  it("auto-detects CJK and adds the ctex preamble", () => {
    const r = convert("# 標題\n內容");
    expect(r.cjk).toBe(true);
    expect(r.tex).toContain("\\usepackage{ctex}");
  });
  it("does not add ctex for pure-ASCII input", () => {
    const r = convert("# Title\nbody");
    expect(r.cjk).toBe(false);
    expect(r.tex).not.toContain("ctex");
  });
  it("emits \\printbibliography and addbibresource when cited", () => {
    const r = convert("text [@x]", {
      bib: { kind: "references", entries: [{ key: "x", title: "X" }] },
    });
    expect(r.tex).toContain("\\printbibliography");
    expect(r.tex).toContain("\\addbibresource{references.bib}");
    expect(r.bib).toContain("@misc{x,");
  });
  it("escapes special characters in title and body", () => {
    const r = convert("---\ntitle: 100% sure\n---\ncost & risk", { template: "article" });
    expect(r.tex).toContain("\\title{100\\% sure}");
    expect(r.tex).toContain("cost \\& risk");
  });
});
