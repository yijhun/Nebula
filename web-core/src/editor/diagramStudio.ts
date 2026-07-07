/**
 * diagramStudio.ts — the geometry/diagram editor ("圖解編輯器"). A free canvas
 * for explanatory figures — points, segments, arrows, circles, ellipses, text
 * labels (with $math$) — drawn by clicking, movable with the select tool, and
 * written back as a publication-grade ```tikz block.
 *
 * Round-trip: the editable model is embedded as a JSON comment on the first
 * line of the generated block (`% nebula-diagram: {...}`), so reopening the
 * studio restores everything. Hand edits BELOW that comment are regenerated
 * (i.e. overwritten) on the next studio save — the comment says so.
 */
import type { EditorView } from "@codemirror/view";
import { makeHistory } from "./studioHistory.js";

// ── model ─────────────────────────────────────────────────────────────────

type Color = "black" | "blue" | "red" | "green";

type Obj =
  | { t: "pt"; x: number; y: number; label: string; color: Color }
  | { t: "seg" | "arr"; x1: number; y1: number; x2: number; y2: number; dash: boolean; color: Color }
  | { t: "circ"; x: number; y: number; r: number; dash: boolean; color: Color }
  | { t: "ell"; x: number; y: number; rx: number; ry: number; dash: boolean; color: Color }
  | { t: "lbl"; x: number; y: number; text: string; color: Color }
  /** Angle mark: CCW arc from a1° to a2° around vertex (x,y). */
  | { t: "ang"; x: number; y: number; a1: number; a2: number; r: number; label: string; color: Color }
  /** Rectangle by two opposite corners. */
  | { t: "rect"; x1: number; y1: number; x2: number; y2: number; dash: boolean; color: Color }
  /** Closed polygon through the given points (schematic beams, regions). */
  | { t: "poly"; pts: Array<[number, number]>; dash: boolean; color: Color }
  /** Gas/dust cloud — a bumpy closed blob (center + mean radius + a seed so
   * the bumps are stable across re-renders). */
  | { t: "cloud"; x: number; y: number; r: number; seed: number; dash: boolean; color: Color }
  // ── 3D-look helpers (oblique projection, no 3D engine) ──
  /** Isometric-ish x/y/z axis triad at origin (x,y). */
  | { t: "axes3d"; x: number; y: number; len: number; color: Color }
  /** Sphere: outline circle + equator ellipse (star/planet). */
  | { t: "sphere"; x: number; y: number; r: number; color: Color }
  /** Cuboid (volume box) at front-bottom-left (x,y), size w×h, depth d. */
  | { t: "cuboid"; x: number; y: number; w: number; h: number; d: number; color: Color };

// Oblique (cabinet) projection for the 3D helpers: depth axis goes up-right.
const DEPTH_DX = 0.5, DEPTH_DY = 0.4;

/** Points of a bumpy cloud outline (world coords), deterministic per seed. */
function cloudPoints(cx: number, cy: number, r: number, seed: number): Array<[number, number]> {
  const bumps = 11;
  const pts: Array<[number, number]> = [];
  // cheap deterministic pseudo-random from seed+index
  const rnd = (i: number): number => {
    const s = Math.sin((seed + 1) * 12.9898 + i * 78.233) * 43758.5453;
    return s - Math.floor(s);
  };
  for (let i = 0; i < bumps; i++) {
    const a = (i / bumps) * Math.PI * 2;
    const rr = r * (0.78 + 0.34 * rnd(i));
    pts.push([cx + rr * Math.cos(a), cy + rr * Math.sin(a)]);
  }
  return pts;
}

const TIKZ_COLOR: Record<Color, string> = {
  black: "", blue: "blue", red: "red", green: "green!60!black",
};
// Paper ink — the canvas is always white (matching the eventual PDF), so
// "black" is real dark ink, never theme-dependent currentColor.
const SVG_COLOR: Record<Color, string> = {
  black: "#1d1f23", blue: "#1c7ed6", red: "#e03131", green: "#2b8a3e",
};

const MODEL_RE = /^%\s*nebula-diagram:\s*(\{.*\})\s*$/m;

// ── TikZ code generation ──────────────────────────────────────────────────

const n = (v: number): string => String(Math.round(v * 100) / 100);

export function diagramToTikz(objs: Obj[]): string {
  const lines: string[] = [];
  lines.push(`% nebula-diagram: ${JSON.stringify({ v: 1, objs })}`);
  lines.push("% （上面那行是圖解編輯器的模型——保留它才能再次用編輯器打開；以下由編輯器生成）");
  lines.push("\\begin{tikzpicture}[>=stealth, line cap=round]");
  for (const o of objs) {
    const col = TIKZ_COLOR[o.color];
    const style = (extra: string[]): string => {
      const parts = [...extra];
      if (col) parts.push(col);
      if ("dash" in o && o.dash) parts.push("dashed");
      return parts.length ? `[${parts.join(", ")}]` : "";
    };
    switch (o.t) {
      case "pt":
        lines.push(`\\fill${style([])} (${n(o.x)},${n(o.y)}) circle (1.6pt);`);
        if (o.label) lines.push(`\\node${style(["above right"])} at (${n(o.x)},${n(o.y)}) {${o.label}};`);
        break;
      case "seg":
        lines.push(`\\draw${style([])} (${n(o.x1)},${n(o.y1)}) -- (${n(o.x2)},${n(o.y2)});`);
        break;
      case "arr":
        lines.push(`\\draw${style(["->", "thick"])} (${n(o.x1)},${n(o.y1)}) -- (${n(o.x2)},${n(o.y2)});`);
        break;
      case "circ":
        lines.push(`\\draw${style([])} (${n(o.x)},${n(o.y)}) circle (${n(o.r)});`);
        break;
      case "ell":
        lines.push(`\\draw${style([])} (${n(o.x)},${n(o.y)}) ellipse (${n(o.rx)} and ${n(o.ry)});`);
        break;
      case "lbl":
        lines.push(`\\node${style([])} at (${n(o.x)},${n(o.y)}) {${o.text}};`);
        break;
      case "ang": {
        // Numeric start point + label position — avoids the tikz calc library.
        const rad = (d: number) => (d * Math.PI) / 180;
        const sx = o.x + o.r * Math.cos(rad(o.a1));
        const sy = o.y + o.r * Math.sin(rad(o.a1));
        const a2 = o.a2 >= o.a1 ? o.a2 : o.a2 + 360;
        lines.push(`\\draw${style([])} (${n(sx)},${n(sy)}) arc[start angle=${n(o.a1)}, end angle=${n(a2)}, radius=${n(o.r)}];`);
        if (o.label) {
          const mid = rad((o.a1 + a2) / 2);
          const lx = o.x + (o.r + 0.35) * Math.cos(mid);
          const ly = o.y + (o.r + 0.35) * Math.sin(mid);
          lines.push(`\\node${style([])} at (${n(lx)},${n(ly)}) {${o.label}};`);
        }
        break;
      }
      case "rect":
        lines.push(`\\draw${style([])} (${n(o.x1)},${n(o.y1)}) rectangle (${n(o.x2)},${n(o.y2)});`);
        break;
      case "poly": {
        if (o.pts.length >= 2) {
          const path = o.pts.map(([x, y]) => `(${n(x)},${n(y)})`).join(" -- ");
          lines.push(`\\draw${style([])} ${path} -- cycle;`);
        }
        break;
      }
      case "cloud": {
        const pts = cloudPoints(o.x, o.y, o.r, o.seed)
          .map(([x, y]) => `(${n(x)},${n(y)})`).join(" ");
        lines.push(`\\draw${style([])} plot[smooth cycle, tension=0.7] coordinates {${pts}};`);
        break;
      }
      case "axes3d": {
        const L = o.len;
        lines.push(`\\draw${style(["->"])} (${n(o.x)},${n(o.y)}) -- (${n(o.x + L)},${n(o.y)}) node[right] {$x$};`);
        lines.push(`\\draw${style(["->"])} (${n(o.x)},${n(o.y)}) -- (${n(o.x)},${n(o.y + L)}) node[above] {$z$};`);
        lines.push(`\\draw${style(["->"])} (${n(o.x)},${n(o.y)}) -- (${n(o.x + L * DEPTH_DX)},${n(o.y + L * DEPTH_DY)}) node[above right] {$y$};`);
        break;
      }
      case "sphere":
        lines.push(`\\draw${style([])} (${n(o.x)},${n(o.y)}) circle (${n(o.r)});`);
        lines.push(`\\draw${style(["dashed"])} (${n(o.x)},${n(o.y)}) ellipse (${n(o.r)} and ${n(o.r * 0.32)});`);
        break;
      case "cuboid": {
        const { x, y, w, h, d } = o;
        const ox = d * DEPTH_DX, oy = d * DEPTH_DY;
        // front face
        lines.push(`\\draw${style([])} (${n(x)},${n(y)}) rectangle (${n(x + w)},${n(y + h)});`);
        // back face
        lines.push(`\\draw${style(["dashed"])} (${n(x + ox)},${n(y + oy)}) rectangle (${n(x + w + ox)},${n(y + h + oy)});`);
        // connectors
        for (const [cx, cy] of [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] as const) {
          lines.push(`\\draw${style([])} (${n(cx)},${n(cy)}) -- (${n(cx + ox)},${n(cy + oy)});`);
        }
        break;
      }
    }
  }
  lines.push("\\end{tikzpicture}");
  return lines.join("\n");
}

export function parseDiagramModel(blockSrc: string): Obj[] | null {
  const m = MODEL_RE.exec(blockSrc);
  if (!m) return null;
  try {
    const parsed = JSON.parse(m[1]!) as { objs?: Obj[] };
    return Array.isArray(parsed.objs) ? parsed.objs : null;
  } catch { return null; }
}

// ── standalone SVG rendering (markdown preview) ───────────────────────────

const escXml = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Label text for SVG: `$\theta$` → italic θ-ish plain text (strip $ and
 * backslashes — a draft approximation; the PDF renders the real math). */
function svgLabel(s: string): { text: string; italic: boolean } {
  const italic = s.includes("$");
  return { text: s.replace(/\$/g, "").replace(/\\/g, ""), italic };
}

/** Render a diagram model to a self-contained SVG string — used by the
 * markdown preview so studio figures are visible WITHOUT compiling. White
 * paper + dark ink, auto-fitted bounding box. */
export function diagramToSvg(objs: Obj[]): string {
  if (!objs.length) return "";
  // bounding box over all object extents
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
  const grow = (x: number, y: number): void => {
    x0 = Math.min(x0, x); x1 = Math.max(x1, x);
    y0 = Math.min(y0, y); y1 = Math.max(y1, y);
  };
  for (const o of objs) {
    switch (o.t) {
      case "pt": case "lbl": grow(o.x, o.y); break;
      case "seg": case "arr": grow(o.x1, o.y1); grow(o.x2, o.y2); break;
      case "circ": grow(o.x - o.r, o.y - o.r); grow(o.x + o.r, o.y + o.r); break;
      case "ell": grow(o.x - o.rx, o.y - o.ry); grow(o.x + o.rx, o.y + o.ry); break;
      case "ang": grow(o.x - o.r - 0.5, o.y - o.r - 0.5); grow(o.x + o.r + 0.5, o.y + o.r + 0.5); break;
      case "rect": grow(o.x1, o.y1); grow(o.x2, o.y2); break;
      case "poly": for (const [x, y] of o.pts) grow(x, y); break;
      case "cloud": grow(o.x - o.r * 1.2, o.y - o.r * 1.2); grow(o.x + o.r * 1.2, o.y + o.r * 1.2); break;
      case "sphere": grow(o.x - o.r, o.y - o.r); grow(o.x + o.r, o.y + o.r); break;
      case "axes3d":
        grow(o.x - 0.3, o.y - 0.3);
        grow(o.x + o.len + 0.3, o.y + Math.max(o.len, o.len * DEPTH_DY) + 0.3);
        break;
      case "cuboid":
        grow(o.x, o.y);
        grow(o.x + o.w + o.d * DEPTH_DX, o.y + o.h + o.d * DEPTH_DY);
        break;
    }
  }
  const PAD = 0.7, S = 40;   // padding (cm), px per cm
  x0 -= PAD; x1 += PAD; y0 -= PAD; y1 += PAD;
  const w = Math.max(1, (x1 - x0) * S), h = Math.max(1, (y1 - y0) * S);
  const X = (x: number): number => (x - x0) * S;
  const Y = (y: number): number => (y1 - y) * S;

  const out: string[] = [];
  out.push(`<svg class="np-diagram" viewBox="0 0 ${w.toFixed(0)} ${h.toFixed(0)}" ` +
    `width="${Math.min(w, 640).toFixed(0)}" xmlns="http://www.w3.org/2000/svg" role="img">`);
  out.push(`<rect width="100%" height="100%" fill="#ffffff"/>`);
  for (const o of objs) {
    const col = SVG_COLOR[o.color];
    const dash = "dash" in o && o.dash ? ` stroke-dasharray="7 4"` : "";
    switch (o.t) {
      case "pt": {
        out.push(`<circle cx="${X(o.x)}" cy="${Y(o.y)}" r="3.5" fill="${col}"/>`);
        if (o.label) {
          const l = svgLabel(o.label);
          out.push(`<text x="${X(o.x) + 7}" y="${Y(o.y) - 7}" fill="${col}" font-size="14"` +
            (l.italic ? ` font-style="italic"` : "") + `>${escXml(l.text)}</text>`);
        }
        break;
      }
      case "seg": case "arr": {
        const [ax, ay, bx, by] = [X(o.x1), Y(o.y1), X(o.x2), Y(o.y2)];
        out.push(`<line x1="${ax}" y1="${ay}" x2="${bx}" y2="${by}" stroke="${col}" stroke-width="2"${dash}/>`);
        if (o.t === "arr") {
          const ang = Math.atan2(by - ay, bx - ax);
          for (const s of [-1, 1]) {
            const hx = bx - 10 * Math.cos(ang - s * 0.42);
            const hy = by - 10 * Math.sin(ang - s * 0.42);
            out.push(`<line x1="${bx}" y1="${by}" x2="${hx.toFixed(1)}" y2="${hy.toFixed(1)}" stroke="${col}" stroke-width="2"/>`);
          }
        }
        break;
      }
      case "circ":
        out.push(`<circle cx="${X(o.x)}" cy="${Y(o.y)}" r="${o.r * S}" fill="none" stroke="${col}" stroke-width="2"${dash}/>`);
        break;
      case "ell":
        out.push(`<ellipse cx="${X(o.x)}" cy="${Y(o.y)}" rx="${o.rx * S}" ry="${o.ry * S}" fill="none" stroke="${col}" stroke-width="2"${dash}/>`);
        break;
      case "lbl": {
        const l = svgLabel(o.text);
        out.push(`<text x="${X(o.x)}" y="${Y(o.y)}" fill="${col}" font-size="15" text-anchor="middle"` +
          (l.italic ? ` font-style="italic"` : "") + `>${escXml(l.text)}</text>`);
        break;
      }
      case "ang": {
        const rad = (d: number) => (d * Math.PI) / 180;
        const a2 = o.a2 >= o.a1 ? o.a2 : o.a2 + 360;
        const sx = X(o.x + o.r * Math.cos(rad(o.a1))), sy = Y(o.y + o.r * Math.sin(rad(o.a1)));
        const ex = X(o.x + o.r * Math.cos(rad(a2))), ey = Y(o.y + o.r * Math.sin(rad(a2)));
        const large = a2 - o.a1 > 180 ? 1 : 0;
        out.push(`<path d="M ${sx.toFixed(1)} ${sy.toFixed(1)} A ${(o.r * S).toFixed(1)} ${(o.r * S).toFixed(1)} 0 ${large} 0 ${ex.toFixed(1)} ${ey.toFixed(1)}" fill="none" stroke="${col}" stroke-width="2"/>`);
        if (o.label) {
          const mid = rad((o.a1 + a2) / 2);
          const l = svgLabel(o.label);
          out.push(`<text x="${X(o.x + (o.r + 0.35) * Math.cos(mid))}" y="${Y(o.y + (o.r + 0.35) * Math.sin(mid))}" fill="${col}" font-size="14" text-anchor="middle"` +
            (l.italic ? ` font-style="italic"` : "") + `>${escXml(l.text)}</text>`);
        }
        break;
      }
      case "rect": {
        const x = Math.min(X(o.x1), X(o.x2)), y = Math.min(Y(o.y1), Y(o.y2));
        out.push(`<rect x="${x}" y="${y}" width="${Math.abs(X(o.x2) - X(o.x1))}" height="${Math.abs(Y(o.y2) - Y(o.y1))}" fill="none" stroke="${col}" stroke-width="2"${dash}/>`);
        break;
      }
      case "poly": {
        if (o.pts.length >= 2) {
          const pts = o.pts.map(([x, y]) => `${X(x).toFixed(1)},${Y(y).toFixed(1)}`).join(" ");
          out.push(`<polygon points="${pts}" fill="none" stroke="${col}" stroke-width="2"${dash}/>`);
        }
        break;
      }
      case "cloud": {
        const p = cloudPoints(o.x, o.y, o.r, o.seed).map(([x, y]) => [X(x), Y(y)] as const);
        // smooth closed path (Catmull-Rom-ish via quadratic midpoints)
        let d = `M ${((p[p.length - 1]![0] + p[0]![0]) / 2).toFixed(1)} ${((p[p.length - 1]![1] + p[0]![1]) / 2).toFixed(1)}`;
        for (let i = 0; i < p.length; i++) {
          const cur = p[i]!, nxt = p[(i + 1) % p.length]!;
          d += ` Q ${cur[0].toFixed(1)} ${cur[1].toFixed(1)} ${((cur[0] + nxt[0]) / 2).toFixed(1)} ${((cur[1] + nxt[1]) / 2).toFixed(1)}`;
        }
        out.push(`<path d="${d} Z" fill="none" stroke="${col}" stroke-width="2"${dash}/>`);
        break;
      }
      case "sphere":
        out.push(`<circle cx="${X(o.x)}" cy="${Y(o.y)}" r="${o.r * S}" fill="none" stroke="${col}" stroke-width="2"/>`);
        out.push(`<ellipse cx="${X(o.x)}" cy="${Y(o.y)}" rx="${o.r * S}" ry="${o.r * 0.32 * S}" fill="none" stroke="${col}" stroke-width="1.5" stroke-dasharray="5 3"/>`);
        break;
      case "axes3d": {
        const L = o.len;
        const arrow = (bx: number, by: number, lbl: string): void => {
          const ax = X(o.x), ay = Y(o.y);
          out.push(`<line x1="${ax}" y1="${ay}" x2="${X(bx)}" y2="${Y(by)}" stroke="${col}" stroke-width="2"/>`);
          const ang = Math.atan2(Y(by) - ay, X(bx) - ax);
          for (const s of [-1, 1]) {
            out.push(`<line x1="${X(bx)}" y1="${Y(by)}" x2="${(X(bx) - 9 * Math.cos(ang - s * 0.42)).toFixed(1)}" y2="${(Y(by) - 9 * Math.sin(ang - s * 0.42)).toFixed(1)}" stroke="${col}" stroke-width="2"/>`);
          }
          out.push(`<text x="${X(bx) + 6}" y="${Y(by)}" fill="${col}" font-size="13" font-style="italic">${lbl}</text>`);
        };
        arrow(o.x + L, o.y, "x");
        arrow(o.x, o.y + L, "z");
        arrow(o.x + L * DEPTH_DX, o.y + L * DEPTH_DY, "y");
        break;
      }
      case "cuboid": {
        const { x, y, w, h, d } = o;
        const ox = d * DEPTH_DX, oy = d * DEPTH_DY;
        const face = (fx: number, fy: number, extra: string): void => {
          out.push(`<rect x="${X(fx)}" y="${Y(fy + h)}" width="${w * S}" height="${h * S}" fill="none" stroke="${col}" stroke-width="2"${extra}/>`);
        };
        face(x + ox, y + oy, ` stroke-dasharray="5 3"`);   // back
        for (const [cx, cy] of [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] as const) {
          out.push(`<line x1="${X(cx)}" y1="${Y(cy)}" x2="${X(cx + ox)}" y2="${Y(cy + oy)}" stroke="${col}" stroke-width="1.5"/>`);
        }
        face(x, y, "");                                     // front
        break;
      }
    }
  }
  out.push("</svg>");
  return out.join("");
}

// ── block locating (any ```tikz fence around the cursor) ─────────────────

interface BlockLoc { innerFrom: number; innerTo: number }

function findTikzBlock(view: EditorView): BlockLoc | null {
  const doc = view.state.doc;
  const cur = doc.lineAt(view.state.selection.main.head).number;
  let open = -1;
  for (let i = cur; i >= 1; i--) {
    const t = doc.line(i).text.trim();
    if (/^```tikz\s*$/.test(t)) { open = i; break; }
    if (/^```/.test(t) && i !== cur) break;
  }
  if (open === -1) return null;
  let close = -1;
  for (let i = Math.max(cur, open + 1); i <= doc.lines; i++) {
    if (i > open && /^```\s*$/.test(doc.line(i).text.trim())) { close = i; break; }
  }
  if (close === -1 || cur > close) return null;
  return {
    innerFrom: doc.line(open).to + 1,
    innerTo: doc.line(close).from > doc.line(open).to + 1 ? doc.line(close).from - 1 : doc.line(open).to + 1,
  };
}

// ── the studio overlay ────────────────────────────────────────────────────

/** World window (TikZ cm): x ∈ [-1, 12], y ∈ [-1, 7.5], 44 px/cm. */
const PPC = 44, X0 = -1, Y1 = 7.5, WCM = 13, HCM = 8.5;
const SNAP = 0.25;

export function openDiagramStudio(view: EditorView): void {
  if (document.querySelector(".np-diagram-studio")) return;
  const loc = findTikzBlock(view);
  const src = loc ? view.state.sliceDoc(loc.innerFrom, loc.innerTo) : "";
  const restored = loc ? parseDiagramModel(src) : null;
  const editable = !!restored;           // plain tikz without a model → new diagram
  const objs: Obj[] = restored ?? [];

  let tool: "select"|"pt"|"seg"|"arr"|"circ"|"ell"|"lbl"|"ang"|"rect"|"poly"|"cloud"|"axes3d"|"sphere"|"cuboid" = objs.length ? "select" : "arr";
  let color: Color = "black";
  let dashed = false;
  let pending: { x: number; y: number } | null = null;   // first click of 2-click tools
  let pending2: { x: number; y: number } | null = null;  // second click (angle = 3 clicks)
  let polyPending: Array<[number, number]> = [];         // polygon vertices so far
  let showGrid = true;
  let selected = -1;
  let dragOff: { dx: number; dy: number } | null = null;
  let activeHandle: { x: number; y: number; set(nx: number, ny: number): void } | null = null;
  const hist = makeHistory(
    () => JSON.stringify(objs),
    (json) => { objs.splice(0, objs.length, ...(JSON.parse(json) as Obj[])); selected = -1; activeHandle = null; pending = null; pending2 = null; polyPending = []; draw(); },
  );

  // overlay scaffolding — panel follows the app theme; the CANVAS itself is
  // always white paper with dark ink (that's what the figure will look like
  // in the compiled PDF, and it stays readable in dark mode).
  const light = document.body.classList.contains("np-light");
  const overlay = document.createElement("div");
  overlay.className = "np-diagram-studio";
  overlay.style.cssText =
    "position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.35);display:flex;" +
    "align-items:center;justify-content:center;";
  const panel = document.createElement("div");
  panel.style.cssText =
    `background:${light ? "#ffffff" : "#23252b"};color:${light ? "#1d1f23" : "#dddddd"};` +
    "border-radius:10px;padding:12px;" +
    "display:flex;flex-direction:column;gap:8px;box-shadow:0 12px 40px rgba(0,0,0,0.45);" +
    "font-size:13px;max-width:96vw;max-height:92vh;overflow:auto;";
  overlay.appendChild(panel);

  // toolbar
  const bar = document.createElement("div");
  bar.style.cssText = "display:flex;gap:6px;align-items:center;flex-wrap:wrap;";
  panel.appendChild(bar);
  const toolBtns = new Map<string, HTMLButtonElement>();
  const mkTool = (id: typeof tool, label: string, hint: string): void => {
    const b = document.createElement("button");
    b.textContent = label;
    b.title = hint;
    b.style.cssText = "border:1px solid rgba(127,127,127,0.4);background:rgba(127,127,127,0.12);" +
      "color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;";
    b.addEventListener("click", () => { tool = id; pending = null; pending2 = null; polyPending = []; syncBar(); });
    toolBtns.set(id, b);
    bar.appendChild(b);
  };
  const title = document.createElement("b");
  title.textContent = "圖解編輯器";
  title.style.marginRight = "6px";
  bar.appendChild(title);
  mkTool("select", "選取", "點物件選取；拖曳移動；Delete 刪除");
  mkTool("pt", "點", "點一下放置（可輸入標籤，如 $P_1$）");
  mkTool("seg", "線段", "點兩下：起點 → 終點");
  mkTool("arr", "箭頭", "點兩下：起點 → 終點");
  mkTool("circ", "圓", "點兩下：圓心 → 半徑");
  mkTool("ell", "橢圓", "點兩下：中心 → 角落");
  mkTool("lbl", "文字", "點一下放置文字（支援 $math$）");
  mkTool("ang", "角度", "點三下：頂點 → 第一邊 → 第二邊（逆時針掃）");
  mkTool("rect", "矩形", "點兩下：一角 → 對角");
  mkTool("poly", "多邊形", "逐點點擊，雙擊或點回起點閉合");
  mkTool("cloud", "雲氣團", "點兩下：中心 → 邊緣（雲/塵埃）");
  mkTool("axes3d", "3D軸", "點一下放置等角 x/y/z 座標軸");
  mkTool("sphere", "球體", "點兩下：中心 → 半徑（星球）");
  mkTool("cuboid", "立方體", "點兩下：前面左下 → 右上（自動加深度）");

  const colorSel = document.createElement("select");
  colorSel.style.cssText = "background:rgba(127,127,127,0.12);color:inherit;border-radius:5px;padding:3px;";
  for (const [v, label] of [["black", "黑"], ["blue", "藍"], ["red", "紅"], ["green", "綠"]] as const) {
    const o = document.createElement("option");
    o.value = v; o.textContent = label;
    colorSel.appendChild(o);
  }
  colorSel.addEventListener("change", () => {
    color = colorSel.value as Color;
    if (selected >= 0) { objs[selected]!.color = color; draw(); }
  });
  bar.appendChild(colorSel);

  const dashLbl = document.createElement("label");
  dashLbl.style.cssText = "display:inline-flex;gap:4px;align-items:center;cursor:pointer;";
  const dashChk = document.createElement("input");
  dashChk.type = "checkbox";
  dashChk.addEventListener("change", () => {
    dashed = dashChk.checked;
    const o = selected >= 0 ? objs[selected] : undefined;
    if (o && "dash" in o) { o.dash = dashed; draw(); }
  });
  dashLbl.appendChild(dashChk);
  dashLbl.appendChild(document.createTextNode("虛線"));
  bar.appendChild(dashLbl);

  const gridLbl = document.createElement("label");
  gridLbl.style.cssText = "display:inline-flex;gap:4px;align-items:center;cursor:pointer;";
  const gridChk = document.createElement("input");
  gridChk.type = "checkbox"; gridChk.checked = true;
  gridChk.addEventListener("change", () => { showGrid = gridChk.checked; draw(); });
  gridLbl.appendChild(gridChk);
  gridLbl.appendChild(document.createTextNode("網格"));
  bar.appendChild(gridLbl);

  const dupBtn = document.createElement("button");
  dupBtn.textContent = "複製";
  dupBtn.style.cssText = "border:none;background:rgba(127,127,127,0.15);color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;";
  dupBtn.addEventListener("click", () => {
    if (selected < 0) return;
    hist.capture();
    const copy = JSON.parse(JSON.stringify(objs[selected]!)) as Obj;
    moveObj(copy, 0.5, -0.5);
    objs.push(copy);
    selected = objs.length - 1;
    hist.commit();
    draw();
  });
  bar.appendChild(dupBtn);

  const delBtn = document.createElement("button");
  delBtn.textContent = "刪除選取";
  delBtn.style.cssText = "border:none;background:rgba(220,38,38,0.18);color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;";
  delBtn.addEventListener("click", deleteSelected);
  bar.appendChild(delBtn);

  const iconBtn = (label: string, hintTxt: string, fn: () => void): void => {
    const b = document.createElement("button");
    b.textContent = label; b.title = hintTxt;
    b.style.cssText = "border:none;background:rgba(127,127,127,0.15);color:inherit;border-radius:6px;padding:4px 9px;cursor:pointer;font-size:14px;";
    b.addEventListener("click", () => { fn(); draw(); });
    bar.appendChild(b);
  };
  iconBtn("↶", "復原 ⌘Z", () => hist.undo());
  iconBtn("↷", "重做 ⇧⌘Z", () => hist.redo());

  const hint = document.createElement("div");
  hint.style.cssText = "opacity:.65;font-size:12px;min-height:16px;";
  panel.appendChild(hint);

  // canvas
  const NSVG = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NSVG, "svg");
  svg.setAttribute("width", String(WCM * PPC));
  svg.setAttribute("height", String(HCM * PPC));
  svg.style.cssText = "background:#ffffff;border:1px solid rgba(127,127,127,0.45);" +
    "border-radius:6px;cursor:crosshair;touch-action:none;";
  panel.appendChild(svg);

  // actions + keyboard hint
  const actions = document.createElement("div");
  actions.style.cssText = "display:flex;gap:8px;align-items:center;";
  const kbd = document.createElement("span");
  kbd.textContent = "⌘Z 復原 · ⇧⌘Z 重做 · Delete 刪除 · Esc 關閉";
  kbd.style.cssText = "opacity:.55;font-size:11px;margin-right:auto;";
  actions.appendChild(kbd);
  const mkBtn = (label: string, primary: boolean, fn: () => void): void => {
    const b = document.createElement("button");
    b.textContent = label;
    b.style.cssText = primary
      ? "background:#4a9eff;color:#fff;border:none;border-radius:6px;padding:6px 14px;cursor:pointer;"
      : "background:rgba(127,127,127,0.15);color:inherit;border:none;border-radius:6px;padding:6px 14px;cursor:pointer;";
    b.addEventListener("click", fn);
    actions.appendChild(b);
  };
  mkBtn("取消", false, close);
  mkBtn(editable ? "寫回 TikZ 區塊" : "插入 TikZ 區塊", true, writeBack);
  panel.appendChild(actions);

  // coordinate transforms
  const toPx = (x: number, y: number): [number, number] => [(x - X0) * PPC, (Y1 - y) * PPC];
  const toWorld = (e: { clientX: number; clientY: number }): [number, number] => {
    const r = svg.getBoundingClientRect();
    const x = X0 + (e.clientX - r.left) / PPC;
    const y = Y1 - (e.clientY - r.top) / PPC;
    return [Math.round(x / SNAP) * SNAP, Math.round(y / SNAP) * SNAP];
  };

  function syncBar(): void {
    for (const [id, b] of toolBtns) {
      b.style.background = id === tool ? "rgba(74,158,255,0.35)" : "rgba(127,127,127,0.12)";
    }
    const hints: Record<string, string> = {
      select: "點物件選取、拖曳移動；Delete 刪除。",
      pt: "點一下放置一個點（會問標籤，可留空）。",
      seg: pending ? "再點一下 = 終點" : "點一下 = 起點",
      arr: pending ? "再點一下 = 箭頭終點" : "點一下 = 箭頭起點",
      circ: pending ? "再點一下 = 圓上一點（定半徑）" : "點一下 = 圓心",
      ell: pending ? "再點一下 = 角落（定 rx, ry）" : "點一下 = 中心",
      lbl: "點一下放置文字（支援 $\\theta$ 這類 math）。",
      ang: pending2 ? "再點一下 = 第二邊方向" : pending ? "再點一下 = 第一邊方向" : "點一下 = 角的頂點",
      rect: pending ? "再點一下 = 對角" : "點一下 = 一角",
      poly: polyPending.length ? `已 ${polyPending.length} 點：繼續點，雙擊或點回起點閉合` : "點一下 = 第一個頂點",
      cloud: pending ? "再點一下 = 雲的邊緣" : "點一下 = 雲的中心",
      axes3d: "點一下放置 x/y/z 座標軸",
      sphere: pending ? "再點一下 = 球面上一點" : "點一下 = 球心",
      cuboid: pending ? "再點一下 = 前面對角" : "點一下 = 前面左下角",
    };
    hint.textContent = hints[tool] ?? "";
  }

  function hitTest(x: number, y: number): number {
    const close2 = (ax: number, ay: number, d = 0.3): boolean =>
      (ax - x) ** 2 + (ay - y) ** 2 < d * d;
    for (let i = objs.length - 1; i >= 0; i--) {
      const o = objs[i]!;
      switch (o.t) {
        case "pt": if (close2(o.x, o.y)) return i; break;
        case "lbl": if (close2(o.x, o.y, 0.45)) return i; break;
        case "seg": case "arr": {
          // distance point→segment
          const dx = o.x2 - o.x1, dy = o.y2 - o.y1;
          const len2 = dx * dx + dy * dy || 1e-9;
          const t = Math.max(0, Math.min(1, ((x - o.x1) * dx + (y - o.y1) * dy) / len2));
          const px = o.x1 + t * dx, py = o.y1 + t * dy;
          if (close2(px, py, 0.22)) return i;
          break;
        }
        case "circ": {
          const d = Math.hypot(x - o.x, y - o.y);
          if (Math.abs(d - o.r) < 0.25 || d < 0.2) return i;
          break;
        }
        case "ell": {
          const v = ((x - o.x) / (o.rx || 1e-9)) ** 2 + ((y - o.y) / (o.ry || 1e-9)) ** 2;
          if (Math.abs(v - 1) < 0.3) return i;
          break;
        }
        case "ang": case "sphere": {
          const d = Math.hypot(x - o.x, y - o.y);
          if (Math.abs(d - o.r) < 0.3 || d < 0.2) return i;
          break;
        }
        case "rect": {
          const lo = [Math.min(o.x1, o.x2), Math.min(o.y1, o.y2)];
          const hi = [Math.max(o.x1, o.x2), Math.max(o.y1, o.y2)];
          if (x > lo[0]! - 0.25 && x < hi[0]! + 0.25 && y > lo[1]! - 0.25 && y < hi[1]! + 0.25) return i;
          break;
        }
        case "poly": {
          for (const [px, py] of o.pts) if (close2(px, py, 0.35)) return i;
          break;
        }
        case "cloud": { if (Math.hypot(x - o.x, y - o.y) < o.r * 1.2) return i; break; }
        case "axes3d": if (close2(o.x, o.y, 0.5) || (x > o.x - 0.3 && x < o.x + o.len && y > o.y - 0.3 && y < o.y + o.len)) return i; break;
        case "cuboid": if (x > o.x - 0.25 && x < o.x + o.w + o.d * DEPTH_DX + 0.25 && y > o.y - 0.25 && y < o.y + o.h + o.d * DEPTH_DY + 0.25) return i; break;
      }
    }
    return -1;
  }

  function objCenter(o: Obj): [number, number] {
    switch (o.t) {
      case "pt": case "lbl": case "circ": case "ell": case "ang":
      case "cloud": case "sphere": case "axes3d": case "cuboid": return [o.x, o.y];
      case "seg": case "arr": case "rect": return [(o.x1 + o.x2) / 2, (o.y1 + o.y2) / 2];
      case "poly": {
        const s = o.pts.reduce((a, [px, py]) => [a[0] + px, a[1] + py], [0, 0]);
        return [s[0] / o.pts.length, s[1] / o.pts.length];
      }
    }
  }

  function moveObj(o: Obj, dx: number, dy: number): void {
    switch (o.t) {
      case "pt": case "lbl": case "circ": case "ell": case "ang":
      case "cloud": case "sphere": case "axes3d": case "cuboid": o.x += dx; o.y += dy; break;
      case "seg": case "arr": case "rect": o.x1 += dx; o.y1 += dy; o.x2 += dx; o.y2 += dy; break;
      case "poly": o.pts = o.pts.map(([px, py]) => [px + dx, py + dy]); break;
    }
  }

  function deleteSelected(): void {
    if (selected >= 0) { hist.capture(); objs.splice(selected, 1); hist.commit(); selected = -1; draw(); }
  }

  interface Handle { x: number; y: number; set(nx: number, ny: number): void }
  /** Resize handles for an object (world coords). Empty = nothing to resize. */
  function handlesFor(o: Obj): Handle[] {
    const S = SNAP;
    switch (o.t) {
      case "seg": case "arr": case "rect":
        return [
          { x: o.x1, y: o.y1, set: (nx, ny) => { o.x1 = nx; o.y1 = ny; } },
          { x: o.x2, y: o.y2, set: (nx, ny) => { o.x2 = nx; o.y2 = ny; } },
        ];
      case "circ": case "cloud":
        return [{ x: o.x + o.r, y: o.y, set: (nx, ny) => { o.r = Math.max(S, Math.hypot(nx - o.x, ny - o.y)); } }];
      case "sphere":
        return [{ x: o.x + o.r, y: o.y, set: (nx, ny) => { o.r = Math.max(S, Math.hypot(nx - o.x, ny - o.y)); } }];
      case "ell":
        return [
          { x: o.x + o.rx, y: o.y, set: (nx) => { o.rx = Math.max(S, Math.abs(nx - o.x)); } },
          { x: o.x, y: o.y + o.ry, set: (_nx, ny) => { o.ry = Math.max(S, Math.abs(ny - o.y)); } },
        ];
      case "ang": {
        const mid = (((o.a2 >= o.a1 ? o.a2 : o.a2 + 360) + o.a1) / 2) * Math.PI / 180;
        return [{ x: o.x + o.r * Math.cos(mid), y: o.y + o.r * Math.sin(mid),
                  set: (nx, ny) => { o.r = Math.max(0.3, Math.hypot(nx - o.x, ny - o.y)); } }];
      }
      case "axes3d":
        return [{ x: o.x + o.len, y: o.y, set: (nx) => { o.len = Math.max(0.5, nx - o.x); } }];
      case "cuboid":
        return [
          { x: o.x + o.w, y: o.y + o.h, set: (nx, ny) => { o.w = Math.max(S, nx - o.x); o.h = Math.max(S, ny - o.y); } },
          { x: o.x + o.w + o.d * DEPTH_DX, y: o.y + o.h + o.d * DEPTH_DY,
            set: (nx) => { o.d = Math.max(S, (nx - o.x - o.w) / DEPTH_DX); } },
        ];
      case "poly":
        return o.pts.map((_, k) => ({ x: o.pts[k]![0], y: o.pts[k]![1], set: (nx: number, ny: number) => { o.pts[k] = [nx, ny]; } }));
      default:
        return [];
    }
  }

  // pointer interaction
  svg.addEventListener("pointerdown", (e: PointerEvent) => {
    hist.capture();
    const [x, y] = toWorld(e);
    if (tool === "select") {
      // First: a resize handle of the already-selected object?
      if (selected >= 0) {
        for (const h of handlesFor(objs[selected]!)) {
          if (Math.hypot(h.x - x, h.y - y) < 0.3) {
            activeHandle = h; svg.setPointerCapture(e.pointerId); return;
          }
        }
      }
      selected = hitTest(x, y);
      if (selected >= 0) {
        const [cx, cy] = objCenter(objs[selected]!);
        dragOff = { dx: cx - x, dy: cy - y };
        const o = objs[selected]!;
        colorSel.value = o.color;
        if ("dash" in o) dashChk.checked = o.dash;
        svg.setPointerCapture(e.pointerId);
      }
      draw();
      return;
    }
    if (tool === "pt") {
      const label = window.prompt("點的標籤（可空，支援 $math$）", "") ?? "";
      objs.push({ t: "pt", x, y, label, color });
      draw();
      return;
    }
    if (tool === "lbl") {
      const text = window.prompt("文字內容（支援 $math$）", "$\\theta$");
      if (text) { objs.push({ t: "lbl", x, y, text, color }); draw(); }
      return;
    }
    // 3-click tool: angle (vertex → ray 1 → ray 2, CCW sweep)
    if (tool === "ang") {
      if (!pending) { pending = { x, y }; syncBar(); draw(); return; }
      if (!pending2) { pending2 = { x, y }; syncBar(); draw(); return; }
      const v = pending, p1 = pending2;
      pending = null; pending2 = null;
      const deg = (dx: number, dy: number) => ((Math.atan2(dy, dx) * 180) / Math.PI + 360) % 360;
      const a1 = deg(p1.x - v.x, p1.y - v.y);
      const a2 = deg(x - v.x, y - v.y);
      const label = window.prompt("角度標籤（可空，支援 $math$）", "$\\theta$") ?? "";
      objs.push({ t: "ang", x: v.x, y: v.y, a1, a2, r: 0.7, label, color });
      syncBar(); draw();
      return;
    }
    // 1-click tool: 3D axis triad
    if (tool === "axes3d") {
      objs.push({ t: "axes3d", x, y, len: 2, color });
      draw();
      return;
    }
    // multi-click tool: polygon (close by clicking near the first vertex)
    if (tool === "poly") {
      if (polyPending.length >= 3 && Math.hypot(x - polyPending[0]![0], y - polyPending[0]![1]) < 0.3) {
        objs.push({ t: "poly", pts: polyPending, dash: dashed, color });
        polyPending = [];
      } else {
        polyPending.push([x, y]);
      }
      syncBar(); draw();
      return;
    }
    // 2-click tools
    if (!pending) { pending = { x, y }; syncBar(); draw(); return; }
    const a = pending; pending = null;
    if (tool === "seg" || tool === "arr") {
      objs.push({ t: tool, x1: a.x, y1: a.y, x2: x, y2: y, dash: dashed, color });
    } else if (tool === "circ") {
      objs.push({ t: "circ", x: a.x, y: a.y, r: Math.max(SNAP, Math.hypot(x - a.x, y - a.y)), dash: dashed, color });
    } else if (tool === "ell") {
      objs.push({ t: "ell", x: a.x, y: a.y, rx: Math.max(SNAP, Math.abs(x - a.x)), ry: Math.max(SNAP, Math.abs(y - a.y)), dash: dashed, color });
    } else if (tool === "rect") {
      objs.push({ t: "rect", x1: a.x, y1: a.y, x2: x, y2: y, dash: dashed, color });
    } else if (tool === "cloud") {
      objs.push({ t: "cloud", x: a.x, y: a.y, r: Math.max(SNAP, Math.hypot(x - a.x, y - a.y)), seed: Math.floor((a.x * 7 + a.y * 13) * 100) % 997, dash: dashed, color });
    } else if (tool === "sphere") {
      objs.push({ t: "sphere", x: a.x, y: a.y, r: Math.max(SNAP, Math.hypot(x - a.x, y - a.y)), color });
    } else if (tool === "cuboid") {
      objs.push({ t: "cuboid", x: Math.min(a.x, x), y: Math.min(a.y, y), w: Math.max(SNAP, Math.abs(x - a.x)), h: Math.max(SNAP, Math.abs(y - a.y)), d: 1, color });
    }
    syncBar();
    draw();
  });
  // Double-click closes a polygon-in-progress (≥3 points).
  svg.addEventListener("dblclick", () => {
    if (tool === "poly" && polyPending.length >= 3) {
      hist.capture();
      objs.push({ t: "poly", pts: polyPending, dash: dashed, color });
      hist.commit();
      polyPending = [];
      syncBar(); draw();
    }
  });
  svg.addEventListener("pointermove", (e: PointerEvent) => {
    if (tool !== "select") return;
    const [x, y] = toWorld(e);
    if (activeHandle) { activeHandle.set(x, y); draw(); return; }
    if (dragOff && selected >= 0) {
      const o = objs[selected]!;
      const [cx, cy] = objCenter(o);
      moveObj(o, x + dragOff.dx - cx, y + dragOff.dy - cy);
      draw();
    }
  });
  svg.addEventListener("pointerup", () => { dragOff = null; activeHandle = null; hist.commit(); });
  // Capture can be lost without a pointerup (window blur, tool switch) — reset
  // so the next move in select mode doesn't resume dragging the old object.
  svg.addEventListener("lostpointercapture", () => { dragOff = null; activeHandle = null; });
  svg.addEventListener("dblclick", (e: MouseEvent) => {
    const [x, y] = toWorld(e);
    const i = hitTest(x, y);
    const o = i >= 0 ? objs[i] : undefined;
    if (o && (o.t === "lbl" || o.t === "pt" || o.t === "ang")) {
      const cur = o.t === "lbl" ? o.text : o.label;
      const next = window.prompt("編輯文字", cur);
      if (next !== null) {
        hist.capture();
        if (o.t === "lbl") o.text = next; else o.label = next;
        hist.commit();
        draw();
      }
    }
  });
  document.addEventListener("keydown", onKey);
  function onKey(e: KeyboardEvent): void {
    if (e.key === "Escape") { close(); return; }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
      e.preventDefault(); if (e.shiftKey) hist.redo(); else hist.undo(); return;
    }
    if ((e.key === "Delete" || e.key === "Backspace") && selected >= 0
        && !(e.target instanceof HTMLInputElement) && !(e.target instanceof HTMLTextAreaElement)) {
      e.preventDefault();
      deleteSelected();
    }
  }

  // draw the model into the SVG canvas
  function draw(): void {
    svg.replaceChildren();
    // grid
    if (showGrid)
    for (let gx = Math.ceil(X0); gx <= X0 + WCM; gx++) {
      const [px] = toPx(gx, 0);
      const l = document.createElementNS(NSVG, "line");
      l.setAttribute("x1", String(px)); l.setAttribute("x2", String(px));
      l.setAttribute("y1", "0"); l.setAttribute("y2", String(HCM * PPC));
      l.setAttribute("stroke", "#1d1f23");
      l.setAttribute("stroke-opacity", gx === 0 ? "0.4" : "0.1");
      svg.appendChild(l);
    }
    if (showGrid)
    for (let gy = Math.ceil(Y1 - HCM); gy <= Y1; gy++) {
      const [, py] = toPx(0, gy);
      const l = document.createElementNS(NSVG, "line");
      l.setAttribute("y1", String(py)); l.setAttribute("y2", String(py));
      l.setAttribute("x1", "0"); l.setAttribute("x2", String(WCM * PPC));
      l.setAttribute("stroke", "#1d1f23");
      l.setAttribute("stroke-opacity", gy === 0 ? "0.4" : "0.1");
      svg.appendChild(l);
    }
    objs.forEach((o, i) => {
      const col = SVG_COLOR[o.color];
      const sel = i === selected;
      const mk = (name: string): SVGElement => {
        const el = document.createElementNS(NSVG, name) as SVGElement;
        el.setAttribute("stroke", col);
        el.setAttribute("fill", "none");
        el.setAttribute("stroke-width", sel ? "3" : "2");
        if ("dash" in o && o.dash) el.setAttribute("stroke-dasharray", "7 4");
        if (sel) el.setAttribute("stroke-opacity", "0.95");
        svg.appendChild(el);
        return el;
      };
      switch (o.t) {
        case "pt": {
          const [px, py] = toPx(o.x, o.y);
          const c = mk("circle");
          c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py));
          c.setAttribute("r", sel ? "5" : "4");
          c.setAttribute("fill", col);
          if (o.label) {
            const t = document.createElementNS(NSVG, "text");
            t.setAttribute("x", String(px + 7)); t.setAttribute("y", String(py - 7));
            t.setAttribute("fill", col); t.setAttribute("font-size", "13");
            t.textContent = o.label;
            svg.appendChild(t);
          }
          break;
        }
        case "seg": case "arr": {
          const [x1, y1] = toPx(o.x1, o.y1);
          const [x2, y2] = toPx(o.x2, o.y2);
          const l = mk("line");
          l.setAttribute("x1", String(x1)); l.setAttribute("y1", String(y1));
          l.setAttribute("x2", String(x2)); l.setAttribute("y2", String(y2));
          if (o.t === "arr") {
            // arrow head
            const ang = Math.atan2(y2 - y1, x2 - x1);
            for (const s of [-1, 1]) {
              const hx = x2 - 11 * Math.cos(ang - s * 0.42);
              const hy = y2 - 11 * Math.sin(ang - s * 0.42);
              const h = mk("line");
              h.setAttribute("x1", String(x2)); h.setAttribute("y1", String(y2));
              h.setAttribute("x2", String(hx)); h.setAttribute("y2", String(hy));
            }
          }
          break;
        }
        case "circ": {
          const [px, py] = toPx(o.x, o.y);
          const c = mk("circle");
          c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py));
          c.setAttribute("r", String(o.r * PPC));
          break;
        }
        case "ell": {
          const [px, py] = toPx(o.x, o.y);
          const c = mk("ellipse");
          c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py));
          c.setAttribute("rx", String(o.rx * PPC)); c.setAttribute("ry", String(o.ry * PPC));
          break;
        }
        case "lbl": {
          const [px, py] = toPx(o.x, o.y);
          const t = document.createElementNS(NSVG, "text");
          t.setAttribute("x", String(px)); t.setAttribute("y", String(py));
          t.setAttribute("fill", col); t.setAttribute("font-size", "14");
          t.setAttribute("text-anchor", "middle");
          if (sel) t.setAttribute("font-weight", "700");
          t.textContent = o.text;
          svg.appendChild(t);
          break;
        }
        case "ang": {
          const rad = (d: number) => (d * Math.PI) / 180;
          const a2 = o.a2 >= o.a1 ? o.a2 : o.a2 + 360;
          const [sx, sy] = toPx(o.x + o.r * Math.cos(rad(o.a1)), o.y + o.r * Math.sin(rad(o.a1)));
          const [ex, ey] = toPx(o.x + o.r * Math.cos(rad(a2)), o.y + o.r * Math.sin(rad(a2)));
          const large = a2 - o.a1 > 180 ? 1 : 0;
          const path = mk("path");
          path.setAttribute("d", `M ${sx.toFixed(1)} ${sy.toFixed(1)} A ${(o.r * PPC).toFixed(1)} ${(o.r * PPC).toFixed(1)} 0 ${large} 0 ${ex.toFixed(1)} ${ey.toFixed(1)}`);
          if (o.label) {
            const mid = rad((o.a1 + a2) / 2);
            const [lx, ly] = toPx(o.x + (o.r + 0.35) * Math.cos(mid), o.y + (o.r + 0.35) * Math.sin(mid));
            const t = document.createElementNS(NSVG, "text");
            t.setAttribute("x", String(lx)); t.setAttribute("y", String(ly));
            t.setAttribute("fill", col); t.setAttribute("font-size", "13");
            t.setAttribute("text-anchor", "middle");
            t.textContent = o.label;
            svg.appendChild(t);
          }
          break;
        }
        case "rect": {
          const [ax, ay] = toPx(o.x1, o.y1), [bx, by] = toPx(o.x2, o.y2);
          const r = mk("rect");
          r.setAttribute("x", String(Math.min(ax, bx))); r.setAttribute("y", String(Math.min(ay, by)));
          r.setAttribute("width", String(Math.abs(bx - ax))); r.setAttribute("height", String(Math.abs(by - ay)));
          break;
        }
        case "poly": {
          const pl = mk("polygon");
          pl.setAttribute("points", o.pts.map(([x, y]) => { const [px, py] = toPx(x, y); return `${px.toFixed(1)},${py.toFixed(1)}`; }).join(" "));
          break;
        }
        case "cloud": {
          const p = cloudPoints(o.x, o.y, o.r, o.seed).map(([x, y]) => toPx(x, y));
          let d = `M ${((p[p.length - 1]![0] + p[0]![0]) / 2).toFixed(1)} ${((p[p.length - 1]![1] + p[0]![1]) / 2).toFixed(1)}`;
          for (let k = 0; k < p.length; k++) { const c = p[k]!, nx = p[(k + 1) % p.length]!; d += ` Q ${c[0].toFixed(1)} ${c[1].toFixed(1)} ${((c[0] + nx[0]) / 2).toFixed(1)} ${((c[1] + nx[1]) / 2).toFixed(1)}`; }
          mk("path").setAttribute("d", d + " Z");
          break;
        }
        case "sphere": {
          const [px, py] = toPx(o.x, o.y);
          const c = mk("circle"); c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py)); c.setAttribute("r", String(o.r * PPC));
          const el = mk("ellipse"); el.setAttribute("cx", String(px)); el.setAttribute("cy", String(py));
          el.setAttribute("rx", String(o.r * PPC)); el.setAttribute("ry", String(o.r * 0.32 * PPC)); el.setAttribute("stroke-dasharray", "5 3");
          break;
        }
        case "axes3d": {
          const L = o.len;
          const drawArr = (bx: number, by: number, lbl: string): void => {
            const [ox, oy] = toPx(o.x, o.y), [tx, ty] = toPx(bx, by);
            const l = mk("line"); l.setAttribute("x1", String(ox)); l.setAttribute("y1", String(oy)); l.setAttribute("x2", String(tx)); l.setAttribute("y2", String(ty));
            const ang = Math.atan2(ty - oy, tx - ox);
            for (const s of [-1, 1]) { const h = mk("line"); h.setAttribute("x1", String(tx)); h.setAttribute("y1", String(ty)); h.setAttribute("x2", (tx - 9 * Math.cos(ang - s * 0.42)).toFixed(1)); h.setAttribute("y2", (ty - 9 * Math.sin(ang - s * 0.42)).toFixed(1)); }
            const t = document.createElementNS(NSVG, "text"); t.setAttribute("x", String(tx + 6)); t.setAttribute("y", String(ty)); t.setAttribute("fill", col); t.setAttribute("font-size", "13"); t.setAttribute("font-style", "italic"); t.textContent = lbl; svg.appendChild(t);
          };
          drawArr(o.x + L, o.y, "x"); drawArr(o.x, o.y + L, "z"); drawArr(o.x + L * DEPTH_DX, o.y + L * DEPTH_DY, "y");
          break;
        }
        case "cuboid": {
          const { x, y, w, h, d } = o;
          const ox = d * DEPTH_DX, oy = d * DEPTH_DY;
          const rectAt = (fx: number, fy: number, dashB: boolean): void => {
            const [ax, ay] = toPx(fx, fy + h); const r = mk("rect");
            r.setAttribute("x", String(ax)); r.setAttribute("y", String(ay)); r.setAttribute("width", String(w * PPC)); r.setAttribute("height", String(h * PPC));
            if (dashB) r.setAttribute("stroke-dasharray", "5 3");
          };
          rectAt(x + ox, y + oy, true);
          for (const [cx, cy] of [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] as const) { const [ax, ay] = toPx(cx, cy), [bx, by] = toPx(cx + ox, cy + oy); const l = mk("line"); l.setAttribute("x1", String(ax)); l.setAttribute("y1", String(ay)); l.setAttribute("x2", String(bx)); l.setAttribute("y2", String(by)); }
          rectAt(x, y, false);
          break;
        }
      }
    });
    // resize handles for the selected object (blue squares)
    if (tool === "select" && selected >= 0 && objs[selected]) {
      for (const h of handlesFor(objs[selected]!)) {
        const [px, py] = toPx(h.x, h.y);
        const sq = document.createElementNS(NSVG, "rect");
        sq.setAttribute("x", (px - 4).toFixed(1)); sq.setAttribute("y", (py - 4).toFixed(1));
        sq.setAttribute("width", "8"); sq.setAttribute("height", "8");
        sq.setAttribute("fill", "#4a9eff"); sq.setAttribute("stroke", "#fff"); sq.setAttribute("stroke-width", "1");
        svg.appendChild(sq);
      }
    }
    // polygon in progress
    if (polyPending.length) {
      for (const [x, y] of polyPending) { const [px, py] = toPx(x, y); const c = document.createElementNS(NSVG, "circle"); c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py)); c.setAttribute("r", "3.5"); c.setAttribute("fill", "#4a9eff"); svg.appendChild(c); }
      if (polyPending.length > 1) { const pl = document.createElementNS(NSVG, "polyline"); pl.setAttribute("points", polyPending.map(([x, y]) => { const [px, py] = toPx(x, y); return `${px.toFixed(1)},${py.toFixed(1)}`; }).join(" ")); pl.setAttribute("fill", "none"); pl.setAttribute("stroke", "#4a9eff"); pl.setAttribute("stroke-width", "1.5"); pl.setAttribute("stroke-dasharray", "4 3"); svg.appendChild(pl); }
    }
    // pending click markers
    if (pending2) {
      const [px, py] = toPx(pending2.x, pending2.y);
      const c = document.createElementNS(NSVG, "circle");
      c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py));
      c.setAttribute("r", "4");
      c.setAttribute("fill", "#37b24d");
      svg.appendChild(c);
    }
    if (pending) {
      const [px, py] = toPx(pending.x, pending.y);
      const c = document.createElementNS(NSVG, "circle");
      c.setAttribute("cx", String(px)); c.setAttribute("cy", String(py));
      c.setAttribute("r", "4");
      c.setAttribute("fill", "#4a9eff");
      svg.appendChild(c);
    }
  }

  function writeBack(): void {
    const tikz = diagramToTikz(objs);
    if (loc && editable) {
      view.dispatch({ changes: { from: loc.innerFrom, to: loc.innerTo, insert: tikz } });
    } else {
      const pos = view.state.selection.main.head;
      view.dispatch({ changes: { from: pos, insert: `\n\`\`\`tikz\n${tikz}\n\`\`\`\n` } });
    }
    close();
  }

  function close(): void {
    document.removeEventListener("keydown", onKey);
    overlay.remove();
    view.focus();
  }

  overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
  document.body.appendChild(overlay);
  syncBar();
  draw();
}
