/**
 * chartTikz.ts — "轉正": translate a draft ```chart block into an equivalent
 * publication-grade ```tikz (pgfplots) block. Data points, error bars, log
 * axes, labels, y-flip and function overlays (with slider parameters baked in
 * as numbers) all carry over. The emitter/preamble already handle ```tikz →
 * paper, so the output compiles straight into the manuscript.
 */
import { parseChartSource, chartXRange, paramBindings, type ChartSpec } from "./chart.js";
import { parse as parseExpr, toPgf } from "./expr.js";

/** Convert chart-block source → tikz-block INNER source (no fences).
 * Returns a readable error string prefixed with "error:" on bad input. */
export function chartToTikz(src: string): string {
  const p = parseChartSource(src);
  if (typeof p === "string") return `error: ${p}`;

  const opts: string[] = [];
  if (p.title) opts.push(`title={${texText(p.title)}}`);
  if (p.xLabel) opts.push(`xlabel={${texText(p.xLabel)}}`);
  if (p.yLabel) opts.push(`ylabel={${texText(p.yLabel)}}`);
  if (p.xlog) opts.push("xmode=log");
  if (p.ylog) opts.push("ymode=log");
  if (p.yflip) opts.push("y dir=reverse");
  for (const k of ["xmin", "xmax", "ymin", "ymax"] as const) {
    if (p[k] !== undefined) opts.push(`${k}=${p[k]}`);
  }
  opts.push("grid=major");
  const legendNames = [
    ...p.series.map((s) => s.name),
    ...p.plots.map((pl) => pl.name || pl.exprSrc),
  ].filter(Boolean);
  if (legendNames.length) opts.push("legend pos=outer north east", "legend cell align=left");

  const lines: string[] = [];
  lines.push(`\\begin{axis}[`);
  lines.push(`  ${opts.join(",\n  ")},`);
  lines.push(`]`);

  // data series
  for (const s of p.series) {
    const style = p.type === "bar" ? "ybar" : p.type === "scatter" ? "only marks" : "mark=*";
    const errOpts = s.errs ? ", error bars/.cd, y dir=both, y explicit" : "";
    const coords = p.xs.map((x, i) => {
      const y = s.ys[i];
      if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
      const e = s.errs?.[i];
      return s.errs
        ? `(${x},${y}) +- (0,${Number.isFinite(e) ? e : 0})`
        : `(${x},${y})`;
    }).filter(Boolean).join(" ");
    lines.push(`\\addplot+[${style}${errOpts}] coordinates { ${coords} };`);
    if (legendNames.length) lines.push(`\\addlegendentry{${texText(s.name || "data")}}`);
  }

  // function overlays — params baked in as numbers so the .tex is standalone
  const env = paramBindings(p);
  const [a, b] = chartXRange(p);
  for (const pl of p.plots) {
    let pgf: string;
    try {
      pgf = toPgf(parseExpr(pl.exprSrc), env);
    } catch (e) {
      lines.push(`% plot 略過（無法解析）: ${pl.exprSrc}`);
      continue;
    }
    lines.push(`\\addplot[smooth, thick, domain=${a}:${b}, samples=120] { ${pgf} };`);
    if (legendNames.length) lines.push(`\\addlegendentry{${texText(pl.name || pl.exprSrc)}}`);
  }

  lines.push(`\\end{axis}`);
  return lines.join("\n");
}

/** Minimal TeX escaping for label text (math stays if the author wrote $…$). */
function texText(s: string): string {
  if (s.includes("$")) return s;   // author wrote math — trust it
  return s.replace(/([%#&_])/g, "\\$1");
}

/** Markdown pre-pass for the LaTeX converter: every ```chart block that
 * translates cleanly becomes an equivalent ```tikz block, so draft charts
 * SHOW UP in the exported paper instead of silently disappearing. Blocks that
 * fail to translate are left as-is (the emitter then skips them with a
 * comment marking the spot). */
export function chartBlocksToTikz(md: string): string {
  return md.replace(/```chart[ \t]*\n([\s\S]*?)\n```/g, (whole, body: string) => {
    const tikz = chartToTikz(body);
    if (tikz.startsWith("error:")) return whole;
    return "```tikz\n% （由 chart 草稿自動轉換；要客製請用「插入 ▸ 圖表 ▸ 轉成 TikZ」再手調）\n" + tikz + "\n```";
  });
}
