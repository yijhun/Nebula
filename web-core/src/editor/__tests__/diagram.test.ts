import { describe, expect, it } from "vitest";
import { diagramToTikz, parseDiagramModel } from "../diagramStudio.js";

const MODEL = [
  { t: "arr", x1: 0, y1: 0, x2: 4, y2: 0, dash: false, color: "black" },
  { t: "arr", x1: 0, y1: 0, x2: 0, y2: 3, dash: false, color: "black" },
  { t: "pt", x: 2, y: 1.5, label: "$P_1$", color: "blue" },
  { t: "seg", x1: 0, y1: 0, x2: 2, y2: 1.5, dash: true, color: "red" },
  { t: "circ", x: 2, y: 1.5, r: 0.75, dash: false, color: "green" },
  { t: "ell", x: 6, y: 2, rx: 2, ry: 1, dash: true, color: "black" },
  { t: "lbl", x: 1, y: 1.2, text: "$\\theta$", color: "black" },
] as Parameters<typeof diagramToTikz>[0];

describe("diagram studio TikZ codegen", () => {
  it("emits every object type with styles", () => {
    const tikz = diagramToTikz(MODEL);
    expect(tikz).toContain("\\begin{tikzpicture}[>=stealth");
    expect(tikz).toContain("\\draw[->, thick] (0,0) -- (4,0);");
    expect(tikz).toContain("\\fill[blue] (2,1.5) circle (1.6pt);");
    expect(tikz).toContain("{$P_1$}");
    expect(tikz).toContain("\\draw[red, dashed] (0,0) -- (2,1.5);");
    expect(tikz).toContain("circle (0.75);");
    expect(tikz).toContain("ellipse (2 and 1);");
    expect(tikz).toContain("{$\\theta$}");
    expect(tikz).toContain("green!60!black");
  });

  it("round-trips the model through the embedded comment", () => {
    const tikz = diagramToTikz(MODEL);
    const restored = parseDiagramModel(tikz);
    expect(restored).toEqual(MODEL);
  });

  it("returns null for plain tikz without a model comment", () => {
    expect(parseDiagramModel("\\begin{tikzpicture}\\draw (0,0)--(1,1);\\end{tikzpicture}")).toBeNull();
  });
});
