import { describe, it, expect } from "vitest";
import { lintLatex } from "../lint.js";

describe("lintLatex — delimiter balance", () => {
  it("clean doc → no issues", () => {
    expect(lintLatex("$a$ and $$b$$ and \\begin{aligned}x&=1\\end{aligned}")).toEqual([]);
  });

  it("flags an unclosed inline $ (shouldn't span a line)", () => {
    const r = lintLatex("a $x = 1\nnext line");
    expect(r.some((i) => i.message.includes("$"))).toBe(true);
  });

  it("flags an unclosed $$ block", () => {
    const r = lintLatex("$$ x = 1");
    expect(r.some((i) => i.message.includes("$$"))).toBe(true);
  });

  it("flags an extra } at the right line", () => {
    const r = lintLatex("ok\n\\frac{a}{b}}\nmore");
    expect(r[0]).toMatchObject({ line: 2 });
    expect(r[0]!.message).toContain("}");
  });

  it("flags an unclosed {", () => {
    expect(lintLatex("\\frac{a}{b").length).toBeGreaterThan(0);
  });

  it("flags a mismatched \\begin/\\end", () => {
    const r = lintLatex("\\begin{aligned} x \\end{vmatrix}");
    expect(r.some((i) => i.message.includes("aligned") || i.message.includes("vmatrix"))).toBe(true);
  });

  it("braces:false skips brace checks but keeps the $ check", () => {
    expect(lintLatex("code {a} and a lone } here.", { braces: false })).toEqual([]);
    expect(lintLatex("$x has no close", { braces: false }).length).toBe(1);
  });
});
