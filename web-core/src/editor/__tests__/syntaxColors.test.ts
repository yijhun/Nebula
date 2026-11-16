import { describe, it, expect } from "vitest";
import { scanSyntax, type SynKind, type SynMode } from "../syntaxColors.js";

/** The source text of every span of `kind`, in document order. */
const texts = (doc: string, kind: SynKind, mode: SynMode = "markdown"): string[] =>
  scanSyntax(doc, mode).filter((s) => s.kind === kind).map((s) => doc.slice(s.from, s.to));

describe("scanSyntax — Markdown", () => {
  it("colours inline and display math, with delimiters split out", () => {
    const doc = "Energy $E = mc^2$ and\n$$\n\\int f\n$$\n";
    expect(texts(doc, "math")).toEqual(["E = mc^2", "\n\\int f\n"]);
    expect(texts(doc, "mathDelim")).toEqual(["$", "$", "$$", "$$"]);
  });

  it("inline $ never spans a line, and \\$ is not a delimiter", () => {
    expect(texts("costs \\$5 and $x\nmore $y$", "math")).toEqual(["y"]);
  });

  it("colours \\[…\\] and math environments", () => {
    const doc = "\\[ a+b \\]\n\\begin{align}\nx &= 1\n\\end{align}";
    expect(texts(doc, "math")).toEqual([" a+b ", "\nx &= 1\n"]);
    expect(texts(doc, "mathDelim")).toEqual(["\\[", "\\]", "\\begin{align}", "\\end{align}"]);
  });

  it("colours LaTeX commands, symbol commands only inside math", () => {
    const doc = "A \\textbf{bold} \\* star and $\\frac{a}{b}\\,x$";
    expect(texts(doc, "cmd")).toEqual(["\\textbf", "\\frac", "\\,"]);
  });

  it("colours Pandoc citations like the converter does", () => {
    const doc = "As shown [@chen2017; @li2020, p. 3] and [see @smith]. Not [email me @ home].";
    expect(texts(doc, "cite")).toEqual(["[@chen2017; @li2020, p. 3]", "[see @smith]"]);
  });

  it("colours raw \\cite/\\ref commands as cite/link, not as plain commands", () => {
    const doc = "See \\citep[e.g.][]{a,b} and Eq.~\\eqref{eq:1}.";
    expect(texts(doc, "cite")).toEqual(["\\citep[e.g.][]{a,b}"]);
    expect(texts(doc, "link")).toEqual(["\\eqref{eq:1}"]);
    expect(texts(doc, "cmd")).toEqual([]);
  });

  it("colours wikilinks and embeds", () => {
    const doc = "See [[Note A|alias]] and ![[fig.png|300]].";
    expect(texts(doc, "link")).toEqual(["[[Note A|alias]]", "![[fig.png|300]]"]);
  });

  it("colours headings, with the # marks separate", () => {
    const doc = "## Results $x$\n#nottag\n";
    expect(texts(doc, "headingMark")).toEqual(["##"]);
    expect(texts(doc, "heading")).toEqual([" Results $x$"]);
    expect(texts(doc, "math")).toEqual(["x"]);         // nested math still coloured
  });

  it("code fences: markers + body lines, nothing coloured inside", () => {
    const doc = "```python\nx = $a$ # [@k] \\frac\n```\nafter $b$";
    expect(texts(doc, "fence")).toEqual(["```python", "```"]);
    const body = scanSyntax(doc, "markdown").filter((s) => s.kind === "fenceBody");
    expect(body.map((s) => doc.slice(s.from, s.to))).toEqual(["x = $a$ # [@k] \\frac"]);
    expect(texts(doc, "math")).toEqual(["b"]);
    expect(texts(doc, "cite")).toEqual([]);
    expect(texts(doc, "cmd")).toEqual([]);
    expect(texts(doc, "heading")).toEqual([]);
  });

  it("an unclosed fence runs to the end of the note", () => {
    const doc = "text\n~~~\n$a$\n";
    expect(texts(doc, "math")).toEqual([]);
  });

  it("skips inline code, comments and front matter", () => {
    const doc = "---\ntitle: $x$\n---\nUse `$y$ [@k]` here <!-- $z$ --> %% [@c] %% $w$";
    expect(texts(doc, "math")).toEqual(["w"]);
    expect(texts(doc, "cite")).toEqual([]);
  });

  it("does not treat a citation-looking group inside math as a citation", () => {
    expect(texts("$[a@b]$", "cite")).toEqual([]);
  });

  it("never returns a span outside the document or inverted", () => {
    const doc = "# T\n$$ unterminated\n[[x]] $a$ ``` `b` \\";
    for (const s of scanSyntax(doc, "markdown")) {
      expect(s.from).toBeGreaterThanOrEqual(0);
      expect(s.to).toBeLessThanOrEqual(doc.length);
      expect(s.to).toBeGreaterThanOrEqual(s.from);
    }
  });
});

describe("scanSyntax — LaTeX", () => {
  it("colours sectioning commands as headings", () => {
    const doc = "\\section*{Intro}\n\\subsection[short]{Long {nested} title}\n";
    expect(texts(doc, "heading", "latex")).toEqual([
      "\\section*{Intro}", "\\subsection[short]{Long {nested} title}",
    ]);
  });

  it("colours \\(…\\), $…$ and equation bodies; commands only inside math", () => {
    const doc = "\\textbf{x} \\(\\alpha\\) $\\beta$\n\\begin{equation*}\n\\gamma\n\\end{equation*}";
    expect(texts(doc, "math", "latex")).toEqual(["\\alpha", "\\beta", "\n\\gamma\n"]);
    expect(texts(doc, "cmd", "latex")).toEqual(["\\alpha", "\\beta", "\\gamma"]);
  });

  it("skips % comments (but not \\%) and verbatim", () => {
    const doc = "50\\% $a$ % $b$ \\cite{k}\n\\verb|$c$| \\begin{verbatim}\n$d$\n\\end{verbatim}\n\\cite{z}";
    expect(texts(doc, "math", "latex")).toEqual(["a"]);
    expect(texts(doc, "cite", "latex")).toEqual(["\\cite{z}"]);
  });

  it("does not colour Markdown citations in a .tex file", () => {
    expect(texts("[@key]", "cite", "latex")).toEqual([]);
  });
});
