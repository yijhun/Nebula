/**
 * chart.ts — tiny dependency-free SVG chart renderer for ```chart code blocks
 * in the preview. Meant for quick looks at small tables while drafting — not a
 * plotting library.
 *
 * Block format (options first, then rows; comma/tab/whitespace separated):
 *
 *   ```chart
 *   type: line          ← line | scatter | bar   (default line)
 *   title: 光變曲線      ← optional
 *   x, flux, err        ← optional header row → axis label + legend names
 *   0, 1.2, 0.1
 *   1, 2.4, 0.2
 *   ```
 *
 * First column = x; every further column is a series.
 */

const COLORS = ["#4a9eff", "#ff6b6b", "#51cf66", "#ffa94d", "#b197fc", "#f783ac"];

interface Parsed {
  type: "line" | "scatter" | "bar";
  title: string;
  names: string[];        // series names (excluding x)
  xLabel: string;
  xs: number[];
  series: number[][];     // series[i][row]
}

function parseChart(src: string): Parsed | string {
  const lines = src.split("\n").map((l) => l.trim()).filter(Boolean);
  let type: Parsed["type"] = "line";
  let title = "";
  let header: string[] | null = null;
  const rows: number[][] = [];

  for (const line of lines) {
    const opt = /^(type|title)\s*[:：]\s*(.+)$/i.exec(line);
    if (opt) {
      if (opt[1]!.toLowerCase() === "type") {
        const t = opt[2]!.trim().toLowerCase();
        if (t === "line" || t === "scatter" || t === "bar") type = t;
      } else title = opt[2]!.trim();
      continue;
    }
    const cells = line.split(/[,\t]|\s{2,}|\s(?=[-\d.])/).map((c) => c.trim()).filter(Boolean);
    if (!cells.length) continue;
    const nums = cells.map(Number);
    if (nums.every((n) => Number.isFinite(n))) rows.push(nums);
    else if (!rows.length && !header) header = cells;
    // non-numeric rows after data start are ignored
  }

  if (!rows.length) return "chart: 沒有數據列";
  const colCount = Math.max(...rows.map((r) => r.length));
  if (colCount < 2) return "chart: 至少要兩欄（x 與一個數列）";

  const xs = rows.map((r) => r[0] ?? 0);
  const series: number[][] = [];
  for (let c = 1; c < colCount; c++) series.push(rows.map((r) => r[c] ?? NaN));
  const names = header
    ? header.slice(1, colCount).map((h, i) => h || `y${i + 1}`)
    : series.map((_, i) => (series.length > 1 ? `y${i + 1}` : ""));
  return { type, title, names, xLabel: header?.[0] ?? "", xs, series };
}

function ticks(min: number, max: number, n = 5): number[] {
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

const fmt = (v: number): string =>
  Math.abs(v) >= 1e5 || (v !== 0 && Math.abs(v) < 1e-3)
    ? v.toExponential(1) : String(Math.round(v * 1000) / 1000);

const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Render a ```chart block to an SVG string (or an error message div). */
export function renderChart(src: string): string {
  const p = parseChart(src);
  if (typeof p === "string") {
    return `<div class="np-chart-error">${esc(p)}</div>`;
  }
  const W = 560, H = 320, m = { l: 56, r: 14, t: p.title ? 34 : 14, b: 40 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;

  const finite = (a: number[]) => a.filter(Number.isFinite);
  let xMin = Math.min(...finite(p.xs)), xMax = Math.max(...finite(p.xs));
  const allY = finite(p.series.flat());
  let yMin = Math.min(...allY), yMax = Math.max(...allY);
  if (p.type === "bar") yMin = Math.min(0, yMin);
  if (xMin === xMax) { xMin -= 1; xMax += 1; }
  if (yMin === yMax) { yMin -= 1; yMax += 1; }
  const xPad = p.type === "bar" ? (xMax - xMin) / Math.max(1, p.xs.length - 1) / 2 : 0;
  xMin -= xPad; xMax += xPad;

  const X = (v: number) => m.l + ((v - xMin) / (xMax - xMin)) * iw;
  const Y = (v: number) => m.t + ih - ((v - yMin) / (yMax - yMin)) * ih;

  const parts: string[] = [];
  parts.push(`<svg class="np-chart" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" role="img">`);
  if (p.title) parts.push(`<text x="${W / 2}" y="20" text-anchor="middle" class="np-chart-title">${esc(p.title)}</text>`);

  // grid + ticks
  for (const tv of ticks(yMin, yMax)) {
    const y = Y(tv);
    parts.push(`<line x1="${m.l}" y1="${y}" x2="${W - m.r}" y2="${y}" class="np-chart-grid"/>`);
    parts.push(`<text x="${m.l - 6}" y="${y + 3}" text-anchor="end" class="np-chart-tick">${fmt(tv)}</text>`);
  }
  for (const tv of ticks(xMin, xMax)) {
    const x = X(tv);
    parts.push(`<text x="${x}" y="${H - m.b + 16}" text-anchor="middle" class="np-chart-tick">${fmt(tv)}</text>`);
  }
  // axes
  parts.push(`<line x1="${m.l}" y1="${m.t}" x2="${m.l}" y2="${m.t + ih}" class="np-chart-axis"/>`);
  parts.push(`<line x1="${m.l}" y1="${m.t + ih}" x2="${W - m.r}" y2="${m.t + ih}" class="np-chart-axis"/>`);
  if (p.xLabel) parts.push(`<text x="${m.l + iw / 2}" y="${H - 6}" text-anchor="middle" class="np-chart-tick">${esc(p.xLabel)}</text>`);

  // series
  const barW = Math.max(2, (iw / Math.max(1, p.xs.length)) / (p.series.length + 0.5));
  p.series.forEach((ys, si) => {
    const color = COLORS[si % COLORS.length]!;
    if (p.type === "bar") {
      ys.forEach((v, i) => {
        if (!Number.isFinite(v)) return;
        const x = X(p.xs[i]!) - (barW * p.series.length) / 2 + si * barW;
        const y0 = Y(Math.max(0, yMin)); const y1 = Y(v);
        parts.push(`<rect x="${x}" y="${Math.min(y0, y1)}" width="${barW - 1}" height="${Math.abs(y0 - y1)}" fill="${color}" opacity="0.85"/>`);
      });
    } else {
      const pts = p.xs.map((x, i) => [X(x), Y(ys[i]!)] as const)
        .filter(([, y]) => Number.isFinite(y));
      if (p.type === "line" && pts.length > 1) {
        parts.push(`<polyline points="${pts.map(([x, y]) => `${x},${y}`).join(" ")}" fill="none" stroke="${color}" stroke-width="2"/>`);
      }
      for (const [x, y] of pts) {
        parts.push(`<circle cx="${x}" cy="${y}" r="${p.type === "scatter" ? 3.5 : 2.5}" fill="${color}"/>`);
      }
    }
  });

  // legend (only when named / multiple series)
  const legendNames = p.names.filter(Boolean);
  if (legendNames.length && (p.series.length > 1 || p.names[0])) {
    p.names.forEach((name, i) => {
      if (!name) return;
      const x = m.l + 10 + i * 110, y = m.t + 12;
      parts.push(`<rect x="${x}" y="${y - 8}" width="10" height="10" fill="${COLORS[i % COLORS.length]}"/>`);
      parts.push(`<text x="${x + 15}" y="${y + 1}" class="np-chart-tick">${esc(name)}</text>`);
    });
  }

  parts.push("</svg>");
  return parts.join("");
}
