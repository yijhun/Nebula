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
 *   param: a = 3e-23 [1e-24, 1e-22]   ← slider parameter (range optional)
 *   plot: 模型 = a * x^0.9            ← function overlay ("name =" optional)
 *   x, flux, flux_err     ← optional header; a column ending in “err”
 *   0, 1.2, 0.1              attaches error bars to the column before it
 *   1, 2.4, 0.2
 *   ```
 *
 * First column = x; every further column is a series (unless it's an err
 * column). In log mode non-positive values are skipped. Function-only charts
 * (no data rows) are allowed when at least one plot: is present.
 */
import { parse as parseExpr, evaluate, freeParams, type Ast } from "./expr.js";

const COLORS = ["#4a9eff", "#ff6b6b", "#51cf66", "#ffa94d", "#b197fc", "#f783ac"];

export interface Series { name: string; ys: number[]; errs?: number[] }
export interface PlotDef { name: string; exprSrc: string }
export interface FitDef { kind: "linear" | "powerlaw" | "exp" | "log" }
export interface ParamDef { name: string; value: number; min: number; max: number }

export interface ChartSpec {
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
  plots: PlotDef[];
  params: ParamDef[];
  /** Least-squares fits over the FIRST data series (`fit: powerlaw` …). */
  fits: FitDef[];
  /** Raw data lines (header + numeric rows) exactly as typed — round-trips
   * through the studio's data textarea. */
  dataLines: string[];
  /** External data file (`data: obs.csv`) — rows come from the vault file
   * via the async cache below instead of inline lines. */
  dataRef?: string;
}

const OPT_RE = /^(type|title|xlabel|ylabel|log|xlog|ylog|yflip|xmin|xmax|ymin|ymax|data)\s*[:：]\s*(.+)$/i;
const PLOT_RE = /^plot\s*[:：]\s*(.+)$/i;
const PARAM_RE = /^param\s*[:：]\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^[\]]+?)\s*(?:\[\s*([^,\]]+)\s*,\s*([^,\]]+)\s*\])?\s*$/i;
const ERR_RE = /(^err$|err$|error$)/i;
const truthy = (v: string): boolean => /^(true|1|yes|on)$/i.test(v.trim());

// ── external data files (`data: obs.csv`) ────────────────────────────────
// Loaded asynchronously through the native bridge and cached; while a file is
// in flight the chart renders a loading card, and `onLoad` re-renders the
// preview once the text arrives.
type CsvEntry = { state: "loading" | "ok" | "fail"; text?: string; error?: string };
const csvCache = new Map<string, CsvEntry>();
let csvFetcher: ((ref: string) => Promise<string>) | null = null;
let csvOnLoad: (() => void) | null = null;

export function setCsvFetcher(
  fetch: (ref: string) => Promise<string>,
  onLoad: () => void,
): void {
  csvFetcher = fetch;
  csvOnLoad = onLoad;
}

function requestCsv(ref: string): CsvEntry {
  const hit = csvCache.get(ref);
  if (hit) return hit;
  const entry: CsvEntry = { state: csvFetcher ? "loading" : "fail", error: csvFetcher ? undefined : "無檔案讀取管道" };
  csvCache.set(ref, entry);
  if (csvFetcher) {
    csvFetcher(ref).then(
      (text) => { csvCache.set(ref, { state: "ok", text: String(text) }); csvOnLoad?.(); },
      (e) => { csvCache.set(ref, { state: "fail", error: e instanceof Error ? e.message : String(e) }); csvOnLoad?.(); },
    );
  }
  return entry;
}

/** Drop a cached file so the next render re-reads it (e.g. after saving). */
export function invalidateCsv(ref?: string): void {
  if (ref) csvCache.delete(ref); else csvCache.clear();
}

/** Default slider range for a parameter the author didn't bound. */
export function defaultParamRange(value: number): [number, number] {
  if (value === 0 || !Number.isFinite(value)) return [-10, 10];
  const a = value / 10, b = value * 10;
  return a < b ? [a, b] : [b, a];
}

export function parseChartSource(src: string): ChartSpec | string {
  const lines = src.split("\n").map((l) => l.trim()).filter(Boolean);
  const p: ChartSpec = {
    type: "line", title: "", xLabel: "", yLabel: "",
    xlog: false, ylog: false, yflip: false,
    xs: [], series: [], plots: [], params: [], fits: [], dataLines: [],
  };
  let header: string[] | null = null;
  const rows: number[][] = [];

  for (const line of lines) {
    const fit = /^fit\s*[:：]\s*(linear|powerlaw|exp|log)\s*$/i.exec(line);
    if (fit) { p.fits.push({ kind: fit[1]!.toLowerCase() as FitDef["kind"] }); continue; }
    const plot = PLOT_RE.exec(line);
    if (plot) {
      const body = plot[1]!.trim();
      // "name = expr" — only when the left of the first '=' has no math.
      const eq = body.indexOf("=");
      if (eq > 0 && !/[-+*/^()]/.test(body.slice(0, eq))) {
        p.plots.push({ name: body.slice(0, eq).trim(), exprSrc: body.slice(eq + 1).trim() });
      } else {
        p.plots.push({ name: "", exprSrc: body });
      }
      continue;
    }
    const param = PARAM_RE.exec(line);
    if (param) {
      const value = Number(param[2]!.trim());
      if (Number.isFinite(value)) {
        const [dmin, dmax] = defaultParamRange(value);
        const min = param[3] !== undefined ? Number(param[3]) : dmin;
        const max = param[4] !== undefined ? Number(param[4]) : dmax;
        p.params.push({
          name: param[1]!,
          value,
          min: Number.isFinite(min) ? min : dmin,
          max: Number.isFinite(max) ? max : dmax,
        });
      }
      continue;
    }
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
        case "data": p.dataRef = val; break;
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
    if (nums.every((n) => Number.isFinite(n))) { rows.push(nums); p.dataLines.push(line); }
    else if (!rows.length && !header) { header = cells; p.dataLines.push(line); }
  }

  // External data file: splice its lines in as if they were typed inline.
  if (p.dataRef) {
    const entry = requestCsv(p.dataRef);
    if (entry.state === "ok" && entry.text) {
      for (const raw of entry.text.split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const cells = line.split(/[,\t]|\s{2,}|\s(?=[-\d.])/).map((c) => c.trim()).filter(Boolean);
        if (!cells.length) continue;
        const nums = cells.map(Number);
        if (nums.every((n) => Number.isFinite(n))) rows.push(nums);
        else if (!rows.length && !header) header = cells;
      }
    } else if (entry.state === "loading") {
      return `chart: 載入 ${p.dataRef} 中…`;
    } else {
      return `chart: 讀取 ${p.dataRef} 失敗（${entry.error ?? "?"}）`;
    }
  }

  if (!rows.length && !p.plots.length) return "chart: 沒有數據列（或至少一條 plot: 函數）";
  if (rows.length) {
    const colCount = Math.max(...rows.map((r) => r.length));
    if (colCount < 2) return "chart: 至少要兩欄（x 與一個數列）";
    p.xs = rows.map((r) => r[0] ?? 0);
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
  }
  return p;
}

/** Rebuild chart-block source from a spec (studio write-back). */
export function serializeChart(p: ChartSpec): string {
  const out: string[] = [];
  out.push(`type: ${p.type}`);
  if (p.title) out.push(`title: ${p.title}`);
  if (p.xLabel) out.push(`xlabel: ${p.xLabel}`);
  if (p.yLabel) out.push(`ylabel: ${p.yLabel}`);
  if (p.xlog || p.ylog) out.push(`log: ${(p.xlog ? "x" : "") + (p.ylog ? "y" : "")}`);
  if (p.yflip) out.push("yflip: true");
  for (const k of ["xmin", "xmax", "ymin", "ymax"] as const) {
    if (p[k] !== undefined) out.push(`${k}: ${p[k]}`);
  }
  for (const prm of p.params) {
    out.push(`param: ${prm.name} = ${prm.value} [${prm.min}, ${prm.max}]`);
  }
  if (p.dataRef) out.push(`data: ${p.dataRef}`);
  for (const f of p.fits) out.push(`fit: ${f.kind}`);
  for (const pl of p.plots) {
    out.push(pl.name ? `plot: ${pl.name} = ${pl.exprSrc}` : `plot: ${pl.exprSrc}`);
  }
  out.push(...p.dataLines);
  return out.join("\n");
}

/** Least-squares fit of the FIRST data series → a plot-compatible expression
 * (rendered exactly like a `plot:` overlay) + legend labels. Null when the
 * data can't support the kind (too few points / non-positive values). */
export function computeFit(p: ChartSpec, kind: FitDef["kind"]):
  { exprSrc: string; label: string; texLabel: string } | null {
  const s = p.series[0];
  if (!s) return null;
  const pts: Array<[number, number]> = [];
  p.xs.forEach((x, i) => {
    const y = s.ys[i];
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    if ((kind === "powerlaw" || kind === "log") && x <= 0) return;
    if ((kind === "powerlaw" || kind === "exp") && (y as number) <= 0) return;
    pts.push([x, y as number]);
  });
  if (pts.length < 2) return null;
  const txf = (x: number) => (kind === "powerlaw" || kind === "log" ? Math.log(x) : x);
  const tyf = (y: number) => (kind === "powerlaw" || kind === "exp" ? Math.log(y) : y);
  const X = pts.map(([x]) => txf(x)), Y = pts.map(([, y]) => tyf(y));
  const n0 = X.length;
  const sx = X.reduce((a, b) => a + b, 0), sy = Y.reduce((a, b) => a + b, 0);
  const sxx = X.reduce((a, b) => a + b * b, 0);
  const sxy = X.reduce((a, x, i) => a + x * Y[i]!, 0);
  const denom = n0 * sxx - sx * sx;
  if (Math.abs(denom) < 1e-12) return null;
  const b = (n0 * sxy - sx * sy) / denom;
  const A = (sy - b * sx) / n0;
  const s6 = (v: number) => Number(v.toPrecision(6)).toString();
  const s3 = (v: number) => Number(v.toPrecision(3)).toString();
  switch (kind) {
    case "linear":
      return { exprSrc: `${s6(A)} + ${s6(b)}*x`,
               label: `fit: y=${s3(A)}+${s3(b)}x`,
               texLabel: `fit $y=${s3(A)}+${s3(b)}x$` };
    case "powerlaw": {
      const a = Math.exp(A);
      return { exprSrc: `${s6(a)} * x^(${s6(b)})`,
               label: `fit: y=${s3(a)}·x^${s3(b)}`,
               texLabel: `fit $y=${s3(a)}\\,x^{${s3(b)}}$` };
    }
    case "exp": {
      const a = Math.exp(A);
      return { exprSrc: `${s6(a)} * exp(${s6(b)}*x)`,
               label: `fit: y=${s3(a)}·e^${s3(b)}x`,
               texLabel: `fit $y=${s3(a)}\\,e^{${s3(b)}x}$` };
    }
    case "log":
      return { exprSrc: `${s6(A)} + ${s6(b)}*ln(x)`,
               label: `fit: y=${s3(A)}+${s3(b)}·ln x`,
               texLabel: `fit $y=${s3(A)}+${s3(b)}\\ln x$` };
  }
}

/** The x range (raw data units) a plot should span — data extent, manual
 * overrides, or a sensible default for function-only charts. */
export function chartXRange(p: ChartSpec): [number, number] {
  const finite = p.xs.filter(Number.isFinite);
  let a = p.xmin ?? (finite.length ? Math.min(...finite) : p.xlog ? 0.1 : 0);
  let b = p.xmax ?? (finite.length ? Math.max(...finite) : 10);
  if (!(a < b)) { a = p.xlog ? 0.1 : 0; b = 10; }
  return [a, b];
}

/** Bindings for evaluating plot expressions: current param values. */
export function paramBindings(p: ChartSpec): Record<string, number> {
  const env: Record<string, number> = {};
  for (const prm of p.params) env[prm.name] = prm.value;
  return env;
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

/** Ticks for a log axis (inputs in log10 space, outputs in log10 space). */
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

const fmtLog = (lv: number): string => {
  const v = Math.pow(10, lv);
  const near = Math.round(lv);
  if (Math.abs(lv - near) < 1e-9 && (near > 3 || near < -3)) return `1e${near}`;
  return fmt(v);
};

const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// ── renderer ──────────────────────────────────────────────────────────────

const SAMPLES = 160;

/** Render a ```chart block to an SVG string (or an error message div). */
export function renderChart(src: string): string {
  const p = parseChartSource(src);
  if (typeof p === "string") {
    return `<div class="np-chart-error">${esc(p)}</div>`;
  }

  // Compile plot expressions (collect readable errors instead of dying).
  const env = paramBindings(p);
  const compiled: Array<{ name: string; ast: Ast }> = [];
  const errors: string[] = [];
  for (const pl of p.plots) {
    try {
      compiled.push({ name: pl.name || pl.exprSrc, ast: parseExpr(pl.exprSrc) });
    } catch (e) {
      errors.push(`plot ${pl.exprSrc}: ${e instanceof Error ? e.message : e}`);
    }
  }
  for (const f of p.fits) {
    const fit = computeFit(p, f.kind);
    if (!fit) { errors.push(`fit ${f.kind}: 數據不足或含非正值`); continue; }
    try { compiled.push({ name: fit.label, ast: parseExpr(fit.exprSrc) }); } catch { /* unreachable */ }
  }
  if (errors.length && !compiled.length && !p.series.length) {
    return `<div class="np-chart-error">${esc(errors.join("；"))}</div>`;
  }

  const W = 560, H = 320;
  const m = { l: p.yLabel ? 72 : 56, r: 14, t: p.title ? 34 : 14, b: p.xLabel ? 48 : 40 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;

  const tx = (v: number) => (p.xlog ? (v > 0 ? Math.log10(v) : NaN) : v);
  const ty = (v: number) => (p.ylog ? (v > 0 ? Math.log10(v) : NaN) : v);

  // Sample the function overlays across the x range (log-uniform when xlog).
  const [rawA, rawB] = chartXRange(p);
  const sampleXs: number[] = [];
  if (compiled.length) {
    const a = tx(rawA), b = tx(rawB);
    if (Number.isFinite(a) && Number.isFinite(b) && a < b) {
      for (let i = 0; i <= SAMPLES; i++) {
        const t = a + ((b - a) * i) / SAMPLES;
        sampleXs.push(p.xlog ? Math.pow(10, t) : t);
      }
    }
  }
  const curves = compiled.map((c) => ({
    name: c.name,
    pts: sampleXs.map((x) => [x, evaluate(c.ast, { ...env, x })] as const),
  }));

  const xsT = p.xs.map(tx);
  const dataYT = p.series.flatMap((s) => s.ys.map(ty)).filter(Number.isFinite);
  const curveYT = curves.flatMap((c) => c.pts.map(([, y]) => ty(y))).filter(Number.isFinite);
  const finiteX = [...xsT.filter(Number.isFinite), ...sampleXs.map(tx).filter(Number.isFinite)];
  const allYT = [...dataYT, ...curveYT];
  if (!finiteX.length || !allYT.length) {
    return `<div class="np-chart-error">chart: 沒有可畫的點（log 模式下需要正值）</div>`;
  }

  let xMin = p.xmin !== undefined ? tx(p.xmin) : Math.min(...finiteX);
  let xMax = p.xmax !== undefined ? tx(p.xmax) : Math.max(...finiteX);
  let yMin = p.ymin !== undefined ? ty(p.ymin) : Math.min(...allYT);
  let yMax = p.ymax !== undefined ? ty(p.ymax) : Math.max(...allYT);
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
  parts.push(`<line x1="${m.l}" y1="${m.t}" x2="${m.l}" y2="${m.t + ih}" class="np-chart-axis"/>`);
  parts.push(`<line x1="${m.l}" y1="${m.t + ih}" x2="${W - m.r}" y2="${m.t + ih}" class="np-chart-axis"/>`);
  if (p.xLabel) parts.push(`<text x="${m.l + iw / 2}" y="${H - 6}" text-anchor="middle" class="np-chart-tick">${esc(p.xLabel)}</text>`);
  if (p.yLabel) parts.push(`<text transform="translate(14 ${m.t + ih / 2}) rotate(-90)" text-anchor="middle" class="np-chart-tick">${esc(p.yLabel)}</text>`);

  // data series
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

  // function overlays (colors continue after the data series)
  curves.forEach((c, ci) => {
    const color = COLORS[(p.series.length + ci) % COLORS.length]!;
    const pts = c.pts
      .map(([x, y]) => [tx(x), ty(y)] as const)
      .filter(([x, y]) => Number.isFinite(x) && Number.isFinite(y))
      .map(([x, y]) => [X(x), Y(y)] as const)
      .filter(([, y]) => y > m.t - 40 && y < m.t + ih + 40);   // clip runaway values
    if (pts.length > 1) {
      parts.push(`<polyline points="${pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ")}" fill="none" stroke="${color}" stroke-width="2" stroke-dasharray="6 3"/>`);
    }
  });

  // legend: data series first, then function curves
  const legendItems: string[] = [];
  p.series.forEach((s) => legendItems.push(s.name));
  curves.forEach((c) => legendItems.push(c.name));
  if (legendItems.some(Boolean) && (legendItems.length > 1 || legendItems[0])) {
    let li = 0;
    legendItems.forEach((name, i) => {
      if (!name) return;
      const x = m.l + 10 + li * 120, y = m.t + 12;
      li++;
      parts.push(`<rect x="${x}" y="${y - 8}" width="10" height="10" fill="${COLORS[i % COLORS.length]}"/>`);
      parts.push(`<text x="${x + 15}" y="${y + 1}" class="np-chart-tick">${esc(name.length > 14 ? name.slice(0, 13) + "…" : name)}</text>`);
    });
  }

  if (errors.length) {
    parts.push(`<text x="${m.l + 4}" y="${m.t + ih - 6}" class="np-chart-tick" fill="#dc2626">⚠ ${esc(errors[0]!.slice(0, 60))}</text>`);
  }

  parts.push("</svg>");
  return parts.join("");
}

/** Free parameters used by the plots but not declared via `param:` lines —
 * the studio auto-creates sliders for these. */
export function undeclaredParams(p: ChartSpec): string[] {
  const declared = new Set(p.params.map((x) => x.name));
  const out = new Set<string>();
  for (const pl of p.plots) {
    try {
      for (const name of freeParams(parseExpr(pl.exprSrc))) {
        if (!declared.has(name)) out.add(name);
      }
    } catch { /* unparseable plot — studio shows the error inline */ }
  }
  return [...out].sort();
}
