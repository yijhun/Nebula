/**
 * Editor syntax colours vs. the Markdown→LaTeX export.
 *
 * Colouring is display-only: export output must not depend on it, and what the
 * editor paints as a citation / wikilink must be exactly what the converter
 * turns into `\cite` / a link — so the colours never mislead about the export.
 */
import { describe, it, expect } from "vitest";
import { convert } from "../index.js";
import { scanSyntax } from "../../editor/syntaxColors.js";

const tex = (md: string): string =>
  convert(md, { bibBackend: "bibtex", defaultTemplate: "article" }).tex;

const SAMPLE = [
  "# Results",
  "",
  "Dust emission [@chen2017; @li2020, p. 3] and [see @smith] (not [email @ home]).",
  "See [[Disk model]] and $\\Sigma = M / \\pi r^2$.",
  "",
  "```python",
  "x = [@notacite]",
  "```",
  "",
].join("\n");

describe("syntax colours ↔ export", () => {
  it("export does not change: colouring never touches the text", () => {
    // scanSyntax is a pure read; converting before and after gives identical tex.
    const before = tex(SAMPLE);
    scanSyntax(SAMPLE, "markdown");
    expect(tex(SAMPLE)).toBe(before);
  });

  it("every green citation is exported as a citation, and vice versa", () => {
    const coloured = scanSyntax(SAMPLE, "markdown")
      .filter((s) => s.kind === "cite")
      .flatMap((s) => [...SAMPLE.slice(s.from, s.to).matchAll(/@([^\s,\];]+)/g)].map((m) => m[1]!));
    const out = tex(SAMPLE);
    // e.g. `\autocites[]{chen2017}[p. 3]{li2020}` → keys from the {…} groups.
    const exported = [...out.matchAll(/\\(?:autocites?|citep|cite)((?:\[[^\]]*\]|\{[^}]*\})+)/g)]
      .flatMap((m) => [...m[1]!.matchAll(/\{([^}]*)\}/g)])
      .flatMap((g) => g[1]!.split(",").map((k) => k.trim()).filter(Boolean));
    expect(coloured.sort()).toEqual(["chen2017", "li2020", "smith"]);
    expect([...new Set(exported)].sort()).toEqual(coloured.sort());
    // `[@notacite]` sits in a code fence: not coloured, and exported verbatim
    // rather than as a citation.
    expect(out).toContain("[@notacite]");
    expect(exported).not.toContain("notacite");
  });

  it("coloured wikilinks are the ones the converter sees as links", () => {
    const links = scanSyntax(SAMPLE, "markdown").filter((s) => s.kind === "link");
    expect(links.map((s) => SAMPLE.slice(s.from, s.to))).toEqual(["[[Disk model]]"]);
    expect(tex(SAMPLE)).toContain("Disk model");
  });
});
