import { describe, expect, it } from "vitest";
import { convert } from "../index.js";
import { extractLatexBlocks } from "../parser.js";

describe("fenced code blocks are opaque to LaTeX extraction", () => {
  it("extractLatexBlocks leaves \\begin{…} inside ``` fences untouched", () => {
    const src = "前文 $$a+b$$\n\n```tikz\n\\begin{axis}\n\\addplot {x};\n\\end{axis}\n```\n\n\\begin{align}\nx &= 1\n\\end{align}\n";
    const { text } = extractLatexBlocks(src);
    // inside the fence: intact
    expect(text).toContain("\\begin{axis}\n\\addplot {x};\n\\end{axis}");
    // outside the fence: extracted to placeholders
    expect(text).not.toContain("\\begin{align}");
    expect(text).not.toContain("$$a+b$$");
  });

  it("convert(): ```tikz with a bare axis survives whole (regression: was mangled to a placeholder)", () => {
    const md = "# T\n\n```tikz\n\\begin{axis}[xlabel={$x$}]\n  \\addplot coordinates {(0,1) (1,2)};\n\\end{axis}\n```\n";
    const tex = convert(md).tex;
    expect(tex).toContain("\\begin{tikzpicture}");
    expect(tex).toContain("\\begin{axis}[xlabel={$x$}]");
    expect(tex).toContain("\\addplot coordinates {(0,1) (1,2)};");
    expect(tex).toContain("\\usepackage{pgfplots}");
    expect(tex).not.toContain("\u{E000}");   // no stray placeholder markers
  });

  it("convert(): ```chart auto-translates to pgfplots in the paper", () => {
    const md = "# T\n\n```chart\ntype: scatter\nlog: xy\nparam: a = 3e-23\nplot: model = a * x^0.9\nx, flux, flux_err\n1e11, 2.1e-12, 4e-13\n1e12, 8.5e-12, 1.2e-12\n```\n";
    const tex = convert(md).tex;
    expect(tex).toContain("\\begin{axis}");
    expect(tex).toContain("xmode=log");
    expect(tex).toContain("error bars/.cd");
    expect(tex).toContain("3e-23*x^0.9");
    expect(tex).not.toContain("已略過");
  });

  it("plain code blocks still come out verbatim, math outside still works", () => {
    const md = "```python\nprint('$x$ and \\\\begin{x}')\n```\n\n$$E=mc^2$$\n";
    const tex = convert(md).tex;
    expect(tex).toContain("\\begin{verbatim}");
    expect(tex).toContain("E=mc^2");
  });
});
