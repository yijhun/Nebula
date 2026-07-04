import { describe, expect, it } from "vitest";
import { parse, evaluate, freeParams, toPgf } from "../expr.js";
import { chartToTikz } from "../chartTikz.js";
import { parseChartSource, serializeChart, type ChartSpec } from "../chart.js";

const ev = (src: string, vars: Record<string, number> = {}) => evaluate(parse(src), vars);

describe("expr parser + evaluator", () => {
  it("precedence and associativity", () => {
    expect(ev("2+3*4")).toBe(14);
    expect(ev("(2+3)*4")).toBe(20);
    expect(ev("2^3^2")).toBe(512);          // right-assoc: 2^(3^2)
    expect(ev("-2^2")).toBe(-4);            // -(2^2)
    expect(ev("10-4-3")).toBe(3);           // left-assoc subtraction
    expect(ev("12/4/3")).toBe(1);
  });

  it("scientific notation and constants", () => {
    expect(ev("3e-23 * 1e23")).toBeCloseTo(3);
    expect(ev("pi")).toBeCloseTo(Math.PI);
    expect(ev("e^1")).toBeCloseTo(Math.E);
  });

  it("functions", () => {
    expect(ev("sin(pi/2)")).toBeCloseTo(1);
    expect(ev("log10(1000)")).toBeCloseTo(3);
    expect(ev("sqrt(abs(-9))")).toBeCloseTo(3);
    expect(ev("ln(e)")).toBeCloseTo(1);
  });

  it("variables and free parameters", () => {
    expect(ev("a*x^2 + b", { a: 2, x: 3, b: 1 })).toBe(19);
    expect(freeParams(parse("a * x^0.9 + b/c"))).toEqual(["a", "b", "c"]);
    expect(freeParams(parse("sin(x) + pi"))).toEqual([]);   // x/pi aren't params
  });

  it("rejects bad input with readable errors", () => {
    expect(() => parse("2 +")).toThrow();
    expect(() => parse("foo(3)")).toThrow(/未知函數/);
    expect(() => parse("(1+2")).toThrow(/缺少/);
  });

  it("pgfplots printing bakes bindings and wraps trig in deg()", () => {
    expect(toPgf(parse("a*x^0.9"), { a: 3e-23 })).toBe("3e-23*x^0.9");
    expect(toPgf(parse("sin(x)"))).toBe("sin(deg(x))");
    expect(toPgf(parse("(x+1)*2"))).toBe("(x+1)*2");
    expect(toPgf(parse("x/(y+1)"), { y: 2 })).toContain("/");
  });
});

describe("chart spec round-trip + tikz conversion", () => {
  const SRC = `type: scatter
title: SED
log: xy
xlabel: nu (Hz)
param: a = 3e-23 [1e-24, 1e-22]
plot: model = a * x^0.9
x, flux, flux_err
1e11, 2.1e-12, 4e-13
1e12, 8.5e-12, 1.2e-12`;

  it("parses plots, params and error columns", () => {
    const p = parseChartSource(SRC) as ChartSpec;
    expect(typeof p).not.toBe("string");
    expect(p.plots).toHaveLength(1);
    expect(p.params[0]).toMatchObject({ name: "a", value: 3e-23 });
    expect(p.series).toHaveLength(1);           // err column folded in
    expect(p.series[0]!.errs).toBeDefined();
  });

  it("serialization round-trips", () => {
    const p = parseChartSource(SRC) as ChartSpec;
    const p2 = parseChartSource(serializeChart(p)) as ChartSpec;
    expect(p2.plots).toEqual(p.plots);
    expect(p2.params).toEqual(p.params);
    expect(p2.xs).toEqual(p.xs);
    expect(p2.xlog && p2.ylog).toBe(true);
  });

  it("tikz conversion carries axes, data, error bars and baked functions", () => {
    const tikz = chartToTikz(SRC);
    expect(tikz).toContain("xmode=log");
    expect(tikz).toContain("ymode=log");
    expect(tikz).toContain("error bars/.cd");
    expect(tikz).toContain("(100000000000,2.1e-12) +- (0,4e-13)");
    expect(tikz).toContain("3e-23*x^0.9");       // param baked in
    expect(tikz).toContain("domain=");
    expect(tikz).toContain("\\addlegendentry{model}");
  });

  it("function-only charts work", () => {
    const p = parseChartSource("plot: sin(x)\nxmin: 0\nxmax: 6.28") as ChartSpec;
    expect(typeof p).not.toBe("string");
    expect(p.plots).toHaveLength(1);
    const tikz = chartToTikz("plot: sin(x)\nxmin: 0\nxmax: 6.28");
    expect(tikz).toContain("sin(deg(x))");
  });
});
