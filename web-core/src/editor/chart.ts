/**
 * chart.ts — tiny dependency-free SVG chart renderer for ```chart code blocks
 * in the preview. Meant for quick looks at small tables while drafting — not a
 * plotting library.
 *
 * Block format (options first, then rows; comma/tab/whitespace separated):
 *
 *   ```chart
 *   type: line            ← line | scatter | bar        (default line)
 *   title: 光變曲線        ← optional
 *   xlabel: ν (Hz)        ← optional axis labels
 *   ylabel: νFν
 *   log: xy               ← log axes: x | y | xy  (or xlog:/ylog: true)
 *   yflip: true           ← invert the y axis (magnitudes!)
 *   xmin/xmax/ymin/ymax: 0.1  ← optional manual ranges
 *   x, flux, flux_err     ← optional header; a column ending in “err”
 *   0, 1.2, 0.1              attaches error bars to the column before it
 *   1, 2.4, 0.2
 *   ```
 *
 * First column = x; every further column is a series (unless it's an err
 * column). In log mode non-positive values are skipped.
 */

const COLORS = ["#4a9eff", "#ff6b6b", "#51cf66", "#ffa94d", "#b197fc", "#f783ac"];

interface Series {
  name: string;
  ys: number[];
  errs?: number[];
}

interface Parsed {
  type: "line" | "scatter" | "bar";
  title: string;
  xLabel: string;
  yLabel: string;
  xlog: boolean;
  ylog: boolean;
  yflip: boolean;
  xmin?: number; xmax?: number; ymin?: number; ymax?: number;
  xs: number[];
  series: Series[];
}

const OPT_RE = /^(type|title|xlabel|ylabel|log|xlog|ylog|yflip|xmin|xmax|ymin|ymax)\s*[:：]\s*(.+)$/i;
const ERR_RE = /(^err$|err$|error$)/i;
const truthy = (v: string): boolean => /^(true|1|yes|on)$/i.test(v.trim());

function parseChart(src: string): Parsed | string {
  const lines = src.split("\n").map((l) => l.trim()).filter(Boolean);
  const p: Parsed = {
    type: "line", title: "", xLabel: "", yLabel: "",
    xlog: false, ylog: false, yflip: false,
    xs: [], series: [],
  };
  let header: string[] | null = null;
  const rows: number[][] = [];

  for (const line of lines) {
    const opt = OPT_RE.exec(line);
    if (opt) {
      const key = opt[1]!.toLowerCase();
      const val = opt[2]!.trim();
      switch (key) {
        case "type": {
          const t = val.toLowerCase();
          if (t === "line" || t === "scatter" || t === "bar") p.type = t;
          break;
        }
        case "title": p.title = val; break;
        case "xlabel": p.xLabel = val; break;
        case "ylabel": p.yLabel = val; break;
        case "log": {
          const t = val.toLowerCase();
          p.xlog = t.includes("x"); p.ylog = t.includes("y");
          break;
        }
        case "xlog": p.xlog = truthy(val); break;
        case "ylog": p.ylog = truthy(val); break;
        case "yflip": p.yflip = truthy(val); break;
        case "xmin": case "xmax": case "ymin": case "ymax": {
          const n = Number(val);
          if (Number.isFinite(n)) p[key] = n;
          break;
        }
      }
      continue;
    }
    const cells = line.split(/[,\t]|\s{2,}|\s(?=[-\d.])/).map((c) => c.trim()).filter(Boolean);
    if (!cells.length) continue;
    const nums = cells.map(Number);
    if (nums.every((n) => Number.isFinite(n))) rows.push(nums);
    else if (!rows.length && !header) header = cells;
  }

  if (!rows.length) return "chart: 沒有數據列";
  const colCount = Math.max(...rows.map((r) => r.length));
  if (colCount < 2) return "chart: 至少要兩欄（x 與一個數列）";

  p.xs = rows.map((r) => r[0] ?? 0);
  // Column → series, folding “…err” columns into the series before them.
  for (let c = 1; c < colCount; c++) {
    const name = header?.[c] ?? "";
    const col = rows.map((r) => r[c] ?? NaN);
    if (name && ERR_RE.test(name) && p.series.length) {
      p.series[p.series.length - 1]!.errs = col;
    } else {
      p.series.push({
        name: name || (colCount > 2 ? `y${p.series.length + 1}` : ""),
        ys: col,
      });
    }
  }
  if (!p.xLabel && header?.[0]) p.xLabel = header[0]!;
  return p;
}

// ── axis helpers ──────────────────────────────────────────────────────────

function linTicks(min: number, max: number, n = 5): number[] {
  if (min === max) { min -= 1; max += 1; }
  const span = max - min;
  const step = Math.pow(10, Math.floor(Math.log10(span / n)));
  const err = (span / n) / step;
  const mult = err >= 7.5 ? 10 : err >= 3.5 ? 5 : err >= 1.5 ? 2 : 1;
  const s = step * mult;
  const t: number[] = [];
  for (let v = Math.ceil(min / s) * s; v <= max + s * 1e-9; v += s) t.push(v);
  return t;
}

/** Ticks for a log axis (inputs in log10 space, outputs in log10 space).
 * Integer decades when the range is wide; 2/5 mantissa fills when narrow. */
function logTicks(lmin: number, lmax: number): number[] {
  const t: number[] = [];
  const d0 = Math.floor(lmin), d1 = Math.ceil(lmax);
  for (let d = d0; d <= d1; d++) {
    for (const m of d1 - d0 <= 3 ? [1, 2, 5] : [1]) {
      const lv = d + Math.log10(m);
      if (lv >= lmin - 1e-9 && lv <= lmax + 1e-9) t.push(lv);
    }
  }
  return t.length >= 2 ? t : linTicks(lmin, lmax);
}

const fmt = (v: number): string =>
  Math.abs(v) >= 1e5 || (v !== 0 && Math.abs(v) < 1e-3)
    ? v.toExponential(1) : String(Math.round(v * 1000) / 1000);

/** Format a log-space tick as its real value (10^n decades stay readable). */
const fmtLog = (lv: number): string => {
  const v = Math.pow(10, lv);
  const near = Math.round(lv);
  if (Math.abs(lv - near) < 1e-9 && (near > 3 || near < -3)) return `1e${near}`;
  return fmt(v);
};

const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// ── renderer ──────────────────────────────────────────────────────────────

/** Render a ```chart block to an SVG string (or an error message div). */
export function renderChart(src: string): string {
  const p = parseChart(src);
  if (typeof p === "string") {
    return `<div class="np-chart-error">${esc(p)}</div>`;
  }
  const W = 560, H = 320;
  const m = { l: p.yLabel ? 72 : 56, r: 14, t: p.title ? 34 : 14, b: p.xLabel ? 48 : 40 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;

  // Transform to plot space (log10 when requested); drop non-positives in log.
  const tx = (v: number) => (p.xlog ? (v > 0 ? Math.log10(v) : NaN) : v);
  const ty = (v: number) => (p.ylog ? (v > 0 ? Math.log10(v) : NaN) : v);

  const xsT = p.xs.map(tx);
  const allYT = p.series.flatMap((s) => s.ys.map(ty)).filter(Number.isFinite);
  const finiteX = xsT.filter(Number.isFinite);
  if (!finiteX.length || !allYT.length) {
    return `<div class="np-chart-error">chart: log 模式下沒有正值可畫</div>`;
  }

  let xMin = p.xmin !== undefined ? tx(p.xmin) : Math.min(...finiteX);
  let xMax = p.xmax !== undefined ? tx(p.xmax) : Math.max(...finiteX);
  let yMin = p.ymin !== undefined ? ty(p.ymin) : Math.min(...allYT);
  let yMax = p.ymax !== undefined ? ty(p.ymax) : Math.max(...allYT);
  // Include error-bar extents.
  for (const s of p.series) {
    if (!s.errs) continue;
    s.ys.forEach((v, i) => {
      const e = s.errs![i];
      if (!Number.isFinite(v) || !Number.isFinite(e)) return;
      const lo = ty(v - e!), hi = ty(v + e!);
      if (p.ymin === undefined && Number.isFinite(lo)) yMin = Math.min(yMin, lo);
      if (p.ymax === undefined && Number.isFinite(hi)) yMax = Math.max(yMax, hi);
    });
  }
  if (p.type === "bar" && !p.ylog && p.ymin === undefined) yMin = Math.min(0, yMin);
  if (!Number.isFinite(xMin) || !Number.isFinite(xMax)) { xMin = 0; xMax = 1; }
  if (xMin === xMax) { xMin -= 1; xMax += 1; }
  if (yMin === yMax) { yMin -= 1; yMax += 1; }
  const xPad = p.type === "bar" ? (xMax - xMin) / Math.max(1, p.xs.length - 1) / 2 : 0;
  xMin -= xPad; xMax += xPad;

  const X = (v: number) => m.l + ((v - xMin) / (xMax - xMin)) * iw;
  const Y = (v: number) => {
    const r = (v - yMin) / (yMax - yMin);
    return p.yflip ? m.t + r * ih : m.t + ih - r * ih;
  };

  const parts: string[] = [];
  parts.push(`<svg class="np-chart" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" role="img">`);
  if (p.title) parts.push(`<text x="${W / 2}" y="20" text-anchor="middle" class="np-chart-title">${esc(p.title)}</text>`);

  // grid + ticks
  const yTicks = p.ylog ? logTicks(yMin, yMax) : linTicks(yMin, yMax);
  const xTicks = p.xlog ? logTicks(xMin, xMax) : linTicks(xMin, xMax);
  const yLab = (v: number) => (p.ylog ? fmtLog(v) : fmt(v));
  const xLab = (v: number) => (p.xlog ? fmtLog(v) : fmt(v));
  for (const tv of yTicks) {
    const y = Y(tv);
    parts.push(`<line x1="${m.l}" y1="${y}" x2="${W - m.r}" y2="${y}" class="np-chart-grid"/>`);
    parts.push(`<text x="${m.l - 6}" y="${y + 3}" text-anchor="end" class="np-chart-tick">${yLab(tv)}</text>`);
  }
  for (const tv of xTicks) {
    const x = X(tv);
    parts.push(`<text x="${x}" y="${H - m.b + 16}" text-anchor="middle" class="np-chart-tick">${xLab(tv)}</text>`);
  }
  // axes + labels
  parts.push(`<line x1="${m.l}" y1="${m.t}" x2="${m.l}" y2="${m.t + ih}" class="np-chart-axis"/>`);
  parts.push(`<line x1="${m.l}" y1="${m.t + ih}" x2="${W - m.r}" y2="${m.t + ih}" class="np-chart-axis"/>`);
  if (p.xLabel) parts.push(`<text x="${m.l + iw / 2}" y="${H - 6}" text-anchor="middle" class="np-chart-tick">${esc(p.xLabel)}</text>`);
  if (p.yLabel) parts.push(`<text transform="translate(14 ${m.t + ih / 2}) rotate(-90)" text-anchor="middle" class="np-chart-tick">${esc(p.yLabel)}</text>`);

  // series
  const barW = Math.max(2, (iw / Math.max(1, p.xs.length)) / (p.series.length + 0.5));
  p.series.forEach((s, si) => {
    const color = COLORS[si % COLORS.length]!;
    if (p.type === "bar") {
      s.ys.forEach((v, i) => {
        const vT = ty(v), xT = xsT[i]!;
        if (!Number.isFinite(vT) || !Number.isFinite(xT)) return;
        const x = X(xT) - (barW * p.series.length) / 2 + si * barW;
        const base = p.ylog ? yMin : Math.max(0, yMin);
        const y0 = Y(base), y1 = Y(vT);
        parts.push(`<rect x="${x}" y="${Math.min(y0, y1)}" width="${barW - 1}" height="${Math.abs(y0 - y1)}" fill="${color}" opacity="0.85"/>`);
      });
      return;
    }
    // error bars first (under the markers)
    if (s.errs) {
      s.ys.forEach((v, i) => {
        const e = s.errs![i], xT = xsT[i]!;
        if (!Number.isFinite(v) || !Number.isFinite(e) || !Number.isFinite(xT)) return;
        const loT = ty(v - e!), hiT = ty(v + e!);
        if (!Number.isFinite(loT) || !Number.isFinite(hiT)) return;
        const x = X(xT), yLo = Y(loT), yHi = Y(hiT);
        parts.push(`<line x1="${x}" y1="${yLo}" x2="${x}" y2="${yHi}" stroke="${color}" stroke-width="1.2" opacity="0.8"/>`);
        parts.push(`<line x1="${x - 3}" y1="${yLo}" x2="${x + 3}" y2="${yLo}" stroke="${color}" stroke-width="1.2" opacity="0.8"/>`);
        parts.push(`<line x1="${x - 3}" y1="${yHi}" x2="${x + 3}" y2="${yHi}" stroke="${color}" stroke-width="1.2" opacity="0.8"/>`);
      });
    }
    const pts = p.xs.map((_, i) => [xsT[i]!, ty(s.ys[i]!)] as const)
      .filter(([x, y]) => Number.isFinite(x) && Number.isFinite(y))
      .map(([x, y]) => [X(x), Y(y)] as const);
    if (p.type === "line" && pts.length > 1) {
      parts.push(`<polyline points="${pts.map(([x, y]) => `${x},${y}`).join(" ")}" fill="none" stroke="${color}" stroke-width="2"/>`);
    }
    for (const [x, y] of pts) {
      parts.push(`<circle cx="${x}" cy="${y}" r="${p.type === "scatter" ? 3.5 : 2.5}" fill="${color}"/>`);
    }
  });

  // legend (only when named / multiple series)
  const legendNames = p.series.map((s) => s.name).filter(Boolean);
  if (legendNames.length && (p.series.length > 1 || p.series[0]!.name)) {
    p.series.forEach((s, i) => {
      if (!s.name) return;
      const x = m.l + 10 + i * 110, y = m.t + 12;
      parts.push(`<rect x="${x}" y="${y - 8}" width="10" height="10" fill="${COLORS[i % COLORS.length]}"/>`);
      parts.push(`<text x="${x + 15}" y="${y + 1}" class="np-chart-tick">${esc(s.name)}</text>`);
    });
  }

  parts.push("</svg>");
  return parts.join("");
}
