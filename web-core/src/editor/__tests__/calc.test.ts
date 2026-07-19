import { describe, expect, it } from "vitest";
import { fmtNum, evalInline, evalCalcLine, renderCalcBlock } from "../calc.js";

describe("fmtNum", () => {
  it("integers stay exact", () => {
    expect(fmtNum(18)).toBe("18");
    expect(fmtNum(1024)).toBe("1024");
    expect(fmtNum(-4)).toBe("-4");
  });
  it("floats to ~6 sig figs, trailing zeros trimmed", () => {
    expect(fmtNum(Math.SQRT2)).toBe("1.41421");
    expect(fmtNum(0.5)).toBe("0.5");
  });
  it("keeps exponential for tiny magnitudes", () => {
    expect(fmtNum(4.14e-21)).toBe("4.14e-21");
  });
});

describe("evalInline (L1)", () => {
  it("computes and echoes the source", () => {
    expect(evalInline("3*(4+2)")).toBe("3*(4+2) = 18");
    expect(evalInline("2^10")).toBe("2^10 = 1024");
    expect(evalInline("sin(pi/6)")).toBe("sin(pi/6) = 0.5");
  });
  it("returns null (leave untouched) for non-expressions", () => {
    expect(evalInline("operator")).toBeNull();       // bare word → NaN
    expect(evalInline("VLOOKUP(2)")).toBeNull();      // unknown function → throws
    expect(evalInline("x + 1")).toBeNull();           // free variable → NaN
  });
});

describe("evalCalcLine + block (L2)", () => {
  it("accumulates variables across lines", () => {
    const vars: Record<string, number> = {};
    expect(evalCalcLine("m = 5", vars)).toMatchObject({ kind: "result", name: "m", value: "5" });
    expect(evalCalcLine("v = 10", vars)).toMatchObject({ kind: "result", name: "v", value: "10" });
    expect(evalCalcLine("p = m*v", vars)).toMatchObject({ kind: "result", value: "50" });
    expect(vars).toEqual({ m: 5, v: 10, p: 50 });
  });
  it("comments and blanks", () => {
    expect(evalCalcLine("# note", {})).toMatchObject({ kind: "comment", text: "note" });
    expect(evalCalcLine("   ", {})).toBeNull();
  });
  it("reports errors per line without throwing", () => {
    expect(evalCalcLine("1/", {})).toMatchObject({ kind: "error" });
    expect(evalCalcLine("y + 1", {})).toMatchObject({ kind: "error" }); // undefined var → non-finite
  });
  it("renders an HTML block with rows", () => {
    const html = renderCalcBlock("m = 5\nv = 10\np = m*v");
    expect(html).toContain("np-calc-block");
    expect(html).toContain("m = 5");
    expect(html).toContain(">50<");
  });
});
