import { describe, it, expect } from "vitest";
import { convert } from "../index.js";

const tex = (md: string, opts: Record<string, unknown> = {}): string =>
  convert(md, { bibBackend: "bibtex", ...opts }).tex;

describe("wide-math fit (Overfull handling)", () => {
  it("wraps a wide matrix in a resizebox", () => {
    expect(tex("$$ \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix} $$")).toMatch(/resizebox[\s\S]*pmatrix/);
  });
  it("leaves a normal equation unwrapped", () => {
    expect(tex("$$ E = mc^2 $$")).not.toMatch(/resizebox/);
  });
  it("does not wrap a numbered align environment", () => {
    expect(tex("$$ \\begin{align} x &= 1 \\end{align} $$")).not.toMatch(/resizebox/);
  });
});

describe("math hardening", () => {
  it("strips blank lines inside display math", () => {
    const block = tex("$$\n\\boxed{R =\n\n1}\n$$").match(/\\\[[\s\S]*?\\\]/)?.[0] ?? "";
    expect(block).toContain("\\boxed");
    expect(block).not.toMatch(/\n[ \t]*\n/);
  });
  it("a stray $$ does not span a heading (matrices after survive)", () => {
    const md = "# A\n\n$$ x = 1 $$\n\none stray $$ delimiter\n\n# Rotation\n\n"
      + "$$ \\begin{pmatrix} a \\\\ b \\end{pmatrix} $$\n";
    const t = tex(md, { defaultTemplate: "article" });
    expect(t).toContain("\\section{Rotation}");
    expect(t).toMatch(/pmatrix/);
  });
});

describe("unicode preamble (only used chars)", () => {
  it("emits \\newunicodechar only for characters present", () => {
    expect((tex("Uses α and × only.").match(/\\newunicodechar/g) || []).length).toBe(2);
  });
  it("omits the package entirely when no special chars are used", () => {
    expect(tex("Plain ascii text only.")).not.toContain("newunicodechar");
  });
});

describe("apj / natbib via convert()", () => {
  it("apj default template → aastex631 + \\citep, no biblatex", () => {
    const t = tex("# T\n\nSee [@x].\n", { defaultTemplate: "apj" });
    expect(t).toContain("\\documentclass{aastex631}");
    expect(t).toContain("\\citep{x}");
    expect(t).not.toMatch(/biblatex/);
  });
  it("default (article) template still uses biblatex \\autocite", () => {
    const t = tex("# T\n\nSee [@x].\n", { defaultTemplate: "article" });
    expect(t).toContain("\\autocite{x}");
    expect(t).toMatch(/biblatex/);
  });
});
