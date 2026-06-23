import { describe, it, expect } from "vitest";
import { convertProject } from "../project.js";

const chapters = [
  { name: "01-intro.md", md: "# Introduction\n\nWe study disks [@a]. $E=mc^2$.\n" },
  { name: "02-method.md", md: "# Method\n\nWe use HLLD [@b].\n" },
];

describe("convertProject", () => {
  it("emits each chapter as its own body (section), without a preamble", () => {
    const r = convertProject(chapters, { template: "academic" });
    expect(r.chapters).toHaveLength(2);
    expect(r.chapters[0]!.name).toBe("01-intro.tex");
    expect(r.chapters[0]!.body).toContain("\\section{Introduction}");
    expect(r.chapters[0]!.body).not.toContain("\\documentclass");
  });

  it("master \\inputs every chapter in order", () => {
    const r = convertProject(chapters, { template: "academic" });
    expect(r.master).toContain("\\documentclass");
    const a = r.master.indexOf("chapters/01-intro");
    const b = r.master.indexOf("chapters/02-method");
    expect(a).toBeGreaterThan(-1);
    expect(b).toBeGreaterThan(a);
    expect((r.master.match(/\\input\{chapters\//g) || []).length).toBe(2);
  });

  it("flat output inlines bodies (no \\input)", () => {
    const r = convertProject(chapters, { template: "academic" });
    expect(r.flat).not.toContain("\\input{chapters");
    expect(r.flat).toContain("Introduction");
    expect(r.flat).toContain("Method");
  });

  it("unions citation keys across chapters (deduped, in order)", () => {
    const r = convertProject(
      [...chapters, { name: "03.md", md: "More [@a] and [@c].\n" }],
      { template: "academic" },
    );
    expect(r.citationKeys).toEqual(["a", "b", "c"]);
  });

  it("apj template uses natbib (\\citep + \\bibliography, no biblatex)", () => {
    const r = convertProject(chapters, { template: "apj" });
    expect(r.master).toContain("\\documentclass{aastex631}");
    expect(r.chapters[0]!.body).toContain("\\citep{a}");
    expect(r.chapters[0]!.body).not.toContain("\\autocite");
    expect(r.master).not.toMatch(/biblatex/);
    expect(r.master).toContain("\\bibliography{references}");
  });
});
