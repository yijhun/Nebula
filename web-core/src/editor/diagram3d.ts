/**
 * diagram3d.ts — a real 3D figure editor. Objects live in (x,y,z); an
 * orthographic camera (azimuth + elevation) is rotated by dragging the canvas.
 * On save the chosen view is BAKED into 2D coordinates inside a plain
 * tikzpicture (no tikz-3dplot dependency) — a fixed figure, exactly what a
 * paper wants — with the editable 3D model + camera stored as a
 * `% nebula-diagram3d: {...}` comment so the studio can reopen it.
 */
import type { EditorView } from "@codemirror/view";
import { makeHistory } from "./studioHistory.js";

type Color = "black" | "blue" | "red" | "green";
type V3 = [number, number, number];

type Obj3 =
  | { t: "axes"; o: V3; len: number; color: Color }
  | { t: "pt"; p: V3; label: string; color: Color }
  | { t: "vec" | "seg"; a: V3; b: V3; dash: boolean; color: Color }
  | { t: "sphere"; c: V3; r: number; color: Color }
  | { t: "disk"; c: V3; r: number; plane: "xy" | "xz" | "yz"; dash: boolean; color: Color }
  | { t: "box"; c: V3; w: number; d: number; h: number; color: Color };

interface Cam { az: number; el: number }   // degrees

const TIKZ_COLOR: Record<Color, string> = { black: "", blue: "blue", red: "red", green: "green!60!black" };
const SVG_COLOR: Record<Color, string> = { black: "#1d1f23", blue: "#1c7ed6", red: "#e03131", green: "#2b8a3e" };
const MODEL_RE = /^%\s*nebula-diagram3d:\s*(\{.*\})\s*$/m;

/** The anchor point of an object (for hit-testing / selection ring). */
function objAnchor(o: Obj3): V3 {
  switch (o.t) {
    case "axes": return o.o;
    case "pt": return o.p;
    case "vec": case "seg": return o.a;
    case "sphere": case "disk": case "box": return o.c;
  }
}

// ── projection ──────────────────────────────────────────────────────────

/** Orthographic camera basis. right/up are unit vectors → projected lengths
 * match world units, and a sphere's silhouette stays a circle of radius r. */
function basis(cam: Cam): { right: V3; up: V3 } {
  const a = (cam.az * Math.PI) / 180, e = (cam.el * Math.PI) / 180;
  return {
    right: [-Math.sin(a), Math.cos(a), 0],
    up: [-Math.cos(a) * Math.sin(e), -Math.sin(a) * Math.sin(e), Math.cos(e)],
  };
}
function project(p: V3, cam: Cam): [number, number] {
  const { right, up } = basis(cam);
  return [p[0] * right[0] + p[1] * right[1] + p[2] * right[2],
          p[0] * up[0] + p[1] * up[1] + p[2] * up[2]];
}
/** Inverse-project a screen point onto the z=0 ground plane (for click-place).
 * Returns [x,y,0]; null when the ground is near edge-on (low elevation). */
function unprojectGround(sx: number, sy: number, cam: Cam): V3 | null {
  const { right, up } = basis(cam);
  // sx = x*right.x + y*right.y ; sy = x*up.x + y*up.y  (z=0)
  const det = right[0] * up[1] - right[1] * up[0];
  if (Math.abs(det) < 1e-4) return null;
  const x = (sx * up[1] - sy * right[1]) / det;
  const y = (right[0] * sy - up[0] * sx) / det;
  return [x, y, 0];
}

function circleInPlane(c: V3, r: number, plane: "xy" | "xz" | "yz", n = 40): V3[] {
  const pts: V3[] = [];
  for (let i = 0; i < n; i++) {
    const t = (i / n) * Math.PI * 2, cs = r * Math.cos(t), sn = r * Math.sin(t);
    pts.push(plane === "xy" ? [c[0] + cs, c[1] + sn, c[2]]
      : plane === "xz" ? [c[0] + cs, c[1], c[2] + sn]
      : [c[0], c[1] + cs, c[2] + sn]);
  }
  return pts;
}
function boxCorners(c: V3, w: number, d: number, h: number): V3[] {
  const [x, y, z] = c;
  return [
    [x, y, z], [x + w, y, z], [x + w, y + d, z], [x, y + d, z],
    [x, y, z + h], [x + w, y, z + h], [x + w, y + d, z + h], [x, y + d, z + h],
  ];
}
const BOX_EDGES = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]] as const;

// ── scene → 2D draw commands (shared by SVG preview, studio canvas, TikZ) ──

type Cmd =
  | { k: "line"; x1: number; y1: number; x2: number; y2: number; color: Color; dash: boolean; arrow: boolean }
  | { k: "circle"; x: number; y: number; r: number; color: Color; dash: boolean }
  | { k: "poly"; pts: Array<[number, number]>; color: Color; dash: boolean; closed: boolean }
  | { k: "dot"; x: number; y: number; color: Color }
  | { k: "text"; x: number; y: number; text: string; color: Color };

/** Build the flat 2D command list for a model under a camera. Depth ordering
 * is left simple (model order); good enough for schematic figures. */
export function buildScene3d(objs: Obj3[], cam: Cam): Cmd[] {
  const out: Cmd[] = [];
  const P = (p: V3): [number, number] => project(p, cam);
  for (const o of objs) {
    const color = o.color;
    const dash = "dash" in o ? o.dash : false;
    switch (o.t) {
      case "axes": {
        const [ox, oy] = P(o.o);
        for (const [ax, lbl] of [[[o.len, 0, 0], "x"], [[0, o.len, 0], "y"], [[0, 0, o.len], "z"]] as const) {
          const [tx, ty] = P([o.o[0] + ax[0], o.o[1] + ax[1], o.o[2] + ax[2]]);
          out.push({ k: "line", x1: ox, y1: oy, x2: tx, y2: ty, color, dash: false, arrow: true });
          out.push({ k: "text", x: tx, y: ty, text: `$${lbl}$`, color });
        }
        break;
      }
      case "pt": {
        const [x, y] = P(o.p);
        out.push({ k: "dot", x, y, color });
        if (o.label) out.push({ k: "text", x: x + 0.18, y: y + 0.18, text: o.label, color });
        break;
      }
      case "vec": case "seg": {
        const [x1, y1] = P(o.a), [x2, y2] = P(o.b);
        out.push({ k: "line", x1, y1, x2, y2, color, dash, arrow: o.t === "vec" });
        break;
      }
      case "sphere": {
        const [x, y] = P(o.c);
        out.push({ k: "circle", x, y, r: o.r, color, dash: false });
        out.push({ k: "poly", pts: circleInPlane(o.c, o.r, "xy").map(P), color, dash: true, closed: true });
        break;
      }
      case "disk":
        out.push({ k: "poly", pts: circleInPlane(o.c, o.r, o.plane).map(P), color, dash, closed: true });
        break;
      case "box": {
        const cs = boxCorners(o.c, o.w, o.d, o.h).map(P);
        for (const [i, j] of BOX_EDGES) {
          out.push({ k: "line", x1: cs[i]![0], y1: cs[i]![1], x2: cs[j]![0], y2: cs[j]![1], color, dash: false, arrow: false });
        }
        break;
      }
    }
  }
  return out;
}

// ── TikZ export (bake the projected 2D coords) ────────────────────────────

const n = (v: number): string => String(Math.round(v * 1000) / 1000);

export function diagram3dToTikz(objs: Obj3[], cam: Cam): string {
  const cmds = buildScene3d(objs, cam);
  const lines: string[] = [];
  lines.push(`% nebula-diagram3d: ${JSON.stringify({ v: 1, cam, objs })}`);
  lines.push("% （上面那行是 3D 編輯器的模型＋視角——保留它才能再次打開；以下已烙入 2D 座標）");
  lines.push("\\begin{tikzpicture}[>=stealth, line cap=round, line join=round]");
  for (const c of cmds) {
    const col = TIKZ_COLOR[c.color];
    const st = (extra: string[]): string => {
      const p = [...extra]; if (col) p.push(col);
      return p.length ? `[${p.join(", ")}]` : "";
    };
    switch (c.k) {
      case "line": {
        const e: string[] = []; if (c.arrow) e.push("->", "thick"); if (c.dash) e.push("dashed");
        lines.push(`\\draw${st(e)} (${n(c.x1)},${n(c.y1)}) -- (${n(c.x2)},${n(c.y2)});`);
        break;
      }
      case "circle":
        lines.push(`\\draw${st(c.dash ? ["dashed"] : [])} (${n(c.x)},${n(c.y)}) circle (${n(c.r)});`);
        break;
      case "poly": {
        const path = c.pts.map(([x, y]) => `(${n(x)},${n(y)})`).join(" -- ");
        lines.push(`\\draw${st(c.dash ? ["dashed"] : [])} ${path}${c.closed ? " -- cycle" : ""};`);
        break;
      }
      case "dot":
        lines.push(`\\fill${st([])} (${n(c.x)},${n(c.y)}) circle (1.6pt);`);
        break;
      case "text":
        lines.push(`\\node${st([])} at (${n(c.x)},${n(c.y)}) {${c.text}};`);
        break;
    }
  }
  lines.push("\\end{tikzpicture}");
  return lines.join("\n");
}

export function parseDiagram3dModel(src: string): { objs: Obj3[]; cam: Cam } | null {
  const m = MODEL_RE.exec(src);
  if (!m) return null;
  try {
    const parsed = JSON.parse(m[1]!) as { objs?: Obj3[]; cam?: Cam };
    if (Array.isArray(parsed.objs) && parsed.cam) return { objs: parsed.objs, cam: parsed.cam };
  } catch { /* fall through */ }
  return null;
}

// ── standalone SVG (markdown preview) ─────────────────────────────────────

const escXml = (s: string): string => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const svgLabel = (s: string): { text: string; italic: boolean } =>
  ({ text: s.replace(/\$/g, "").replace(/\\/g, ""), italic: s.includes("$") });

export function diagram3dToSvg(objs: Obj3[], cam: Cam): string {
  const cmds = buildScene3d(objs, cam);
  if (!cmds.length) return "";
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
  const grow = (x: number, y: number): void => { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); };
  for (const c of cmds) {
    if (c.k === "line") { grow(c.x1, c.y1); grow(c.x2, c.y2); }
    else if (c.k === "circle") { grow(c.x - c.r, c.y - c.r); grow(c.x + c.r, c.y + c.r); }
    else if (c.k === "poly") for (const [x, y] of c.pts) grow(x, y);
    else grow(c.x, c.y);
  }
  const PAD = 0.7, S = 40;
  x0 -= PAD; x1 += PAD; y0 -= PAD; y1 += PAD;
  const w = Math.max(1, (x1 - x0) * S), h = Math.max(1, (y1 - y0) * S);
  const X = (x: number): number => (x - x0) * S;
  const Y = (y: number): number => (y1 - y) * S;      // flip: +y up
  const out: string[] = [];
  out.push(`<svg class="np-diagram" viewBox="0 0 ${w.toFixed(0)} ${h.toFixed(0)}" width="${Math.min(w, 640).toFixed(0)}" xmlns="http://www.w3.org/2000/svg" role="img">`);
  out.push(`<rect width="100%" height="100%" fill="#ffffff"/>`);
  for (const c of cmds) {
    const col = SVG_COLOR[c.color];
    const dash = "dash" in c && c.dash ? ` stroke-dasharray="6 4"` : "";
    switch (c.k) {
      case "line": {
        const [ax, ay, bx, by] = [X(c.x1), Y(c.y1), X(c.x2), Y(c.y2)];
        out.push(`<line x1="${ax.toFixed(1)}" y1="${ay.toFixed(1)}" x2="${bx.toFixed(1)}" y2="${by.toFixed(1)}" stroke="${col}" stroke-width="2"${dash}/>`);
        if (c.arrow) {
          const ang = Math.atan2(by - ay, bx - ax);
          for (const s of [-1, 1]) out.push(`<line x1="${bx.toFixed(1)}" y1="${by.toFixed(1)}" x2="${(bx - 9 * Math.cos(ang - s * 0.42)).toFixed(1)}" y2="${(by - 9 * Math.sin(ang - s * 0.42)).toFixed(1)}" stroke="${col}" stroke-width="2"/>`);
        }
        break;
      }
      case "circle":
        out.push(`<circle cx="${X(c.x).toFixed(1)}" cy="${Y(c.y).toFixed(1)}" r="${(c.r * S).toFixed(1)}" fill="none" stroke="${col}" stroke-width="2"/>`);
        break;
      case "poly": {
        const pts = c.pts.map(([x, y]) => `${X(x).toFixed(1)},${Y(y).toFixed(1)}`).join(" ");
        out.push(`<poly${c.closed ? "gon" : "line"} points="${pts}" fill="none" stroke="${col}" stroke-width="1.6"${dash}/>`);
        break;
      }
      case "dot":
        out.push(`<circle cx="${X(c.x).toFixed(1)}" cy="${Y(c.y).toFixed(1)}" r="3.5" fill="${col}"/>`);
        break;
      case "text": {
        const l = svgLabel(c.text);
        out.push(`<text x="${X(c.x).toFixed(1)}" y="${Y(c.y).toFixed(1)}" fill="${col}" font-size="14"${l.italic ? ' font-style="italic"' : ""}>${escXml(l.text)}</text>`);
        break;
      }
    }
  }
  out.push("</svg>");
  return out.join("");
}

// ── the interactive studio ────────────────────────────────────────────────

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
  for (let i = Math.max(cur, open + 1); i <= doc.lines; i++) if (i > open && /^```\s*$/.test(doc.line(i).text.trim())) { close = i; break; }
  if (close === -1 || cur > close) return null;
  return { innerFrom: doc.line(open).to + 1, innerTo: doc.line(close).from > doc.line(open).to + 1 ? doc.line(close).from - 1 : doc.line(open).to + 1 };
}

const W = 640, H = 420, PPC = 42, CX = W / 2, CY = H / 2;   // canvas centered on origin

export function openDiagram3dStudio(view: EditorView): void {
  if (document.querySelector(".np-diagram3d-studio")) return;
  const loc = findTikzBlock(view);
  const src = loc ? view.state.sliceDoc(loc.innerFrom, loc.innerTo) : "";
  const restored = loc ? parseDiagram3dModel(src) : null;
  const editable = !!restored;
  const objs: Obj3[] = restored?.objs ?? [{ t: "axes", o: [0, 0, 0], len: 3, color: "black" }];
  const cam: Cam = restored?.cam ?? { az: -55, el: 25 };

  let tool: "rotate" | "pt" | "vec" | "seg" | "disk" | "sphere" | "box" = "rotate";
  let color: Color = "black";
  let height = 0;                       // z used for the next placed object
  let pending: V3 | null = null;        // first click of 2-click tools
  let selected = -1;
  const hist = makeHistory(
    () => JSON.stringify({ objs, cam }),
    (json) => { const st = JSON.parse(json) as { objs: Obj3[]; cam: Cam }; objs.splice(0, objs.length, ...st.objs); cam.az = st.cam.az; cam.el = st.cam.el; selected = -1; pending = null; for (const sl of camSliders) sl._sync?.(); draw(); },
  );

  const light = document.body.classList.contains("np-light");
  const overlay = document.createElement("div");
  overlay.className = "np-diagram3d-studio";
  overlay.style.cssText = "position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.35);display:flex;align-items:center;justify-content:center;";
  const panel = document.createElement("div");
  panel.style.cssText = `background:${light ? "#ffffff" : "#23252b"};color:${light ? "#1d1f23" : "#dddddd"};border-radius:10px;padding:12px;display:flex;flex-direction:column;gap:8px;box-shadow:0 12px 40px rgba(0,0,0,0.45);font-size:13px;max-width:96vw;max-height:92vh;overflow:auto;`;
  overlay.appendChild(panel);

  const bar = document.createElement("div");
  bar.style.cssText = "display:flex;gap:6px;align-items:center;flex-wrap:wrap;";
  panel.appendChild(bar);
  const title = document.createElement("b"); title.textContent = "3D 圖編輯器"; title.style.marginRight = "6px"; bar.appendChild(title);
  const toolBtns = new Map<string, HTMLButtonElement>();
  const mkTool = (id: typeof tool, label: string, hint: string): void => {
    const b = document.createElement("button"); b.textContent = label; b.title = hint;
    b.style.cssText = "border:1px solid rgba(127,127,127,0.4);background:rgba(127,127,127,0.12);color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;";
    b.addEventListener("click", () => { tool = id; pending = null; syncBar(); });
    toolBtns.set(id, b); bar.appendChild(b);
  };
  mkTool("rotate", "旋轉視角", "在畫布上拖曳 = 旋轉 3D 視角");
  mkTool("pt", "點", "點一下放在地面 (z=0)，可設高度");
  mkTool("vec", "向量", "點兩下：起點 → 終點（箭頭）");
  mkTool("seg", "線段", "點兩下");
  mkTool("disk", "圓盤", "點兩下：中心 → 邊（xy 平面，如吸積盤）");
  mkTool("sphere", "球", "點兩下：中心 → 半徑（星球）");
  mkTool("box", "立方體", "點兩下：對角（底面）");

  const colorSel = document.createElement("select");
  colorSel.style.cssText = "background:rgba(127,127,127,0.12);color:inherit;border-radius:5px;padding:3px;";
  for (const [v, l] of [["black", "黑"], ["blue", "藍"], ["red", "紅"], ["green", "綠"]] as const) { const o = document.createElement("option"); o.value = v; o.textContent = l; colorSel.appendChild(o); }
  colorSel.addEventListener("change", () => { color = colorSel.value as Color; if (selected >= 0) { objs[selected]!.color = color; draw(); } });
  bar.appendChild(colorSel);

  // height (z) for the next placed object
  const hWrap = document.createElement("label");
  hWrap.style.cssText = "display:inline-flex;gap:4px;align-items:center;";
  hWrap.appendChild(document.createTextNode("高度 z"));
  const hIn = document.createElement("input"); hIn.type = "number"; hIn.step = "0.5"; hIn.value = "0";
  hIn.style.cssText = "width:56px;background:rgba(127,127,127,0.12);border:1px solid rgba(127,127,127,0.3);border-radius:5px;padding:2px 5px;color:inherit;";
  hIn.addEventListener("input", () => { height = Number(hIn.value) || 0; });
  hWrap.appendChild(hIn); bar.appendChild(hWrap);

  const delBtn = document.createElement("button"); delBtn.textContent = "刪除選取";
  delBtn.style.cssText = "border:none;background:rgba(220,38,38,0.18);color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;";
  delBtn.addEventListener("click", () => { if (selected >= 0) { hist.capture(); objs.splice(selected, 1); hist.commit(); selected = -1; draw(); } });
  bar.appendChild(delBtn);

  const iconBtn = (label: string, hintTxt: string, fn: () => void): void => {
    const b = document.createElement("button"); b.textContent = label; b.title = hintTxt;
    b.style.cssText = "border:none;background:rgba(127,127,127,0.15);color:inherit;border-radius:6px;padding:4px 9px;cursor:pointer;font-size:14px;";
    b.addEventListener("click", () => { fn(); draw(); });
    bar.appendChild(b);
  };
  iconBtn("↶", "復原 ⌘Z", () => hist.undo());
  iconBtn("↷", "重做 ⇧⌘Z", () => hist.redo());

  // camera sliders
  const camRow = document.createElement("div");
  camRow.style.cssText = "display:flex;gap:12px;align-items:center;font-size:12px;opacity:.85;";
  const mkSlider = (label: string, min: number, max: number, get: () => number, set: (v: number) => void): void => {
    const w2 = document.createElement("label"); w2.style.cssText = "display:inline-flex;gap:5px;align-items:center;";
    w2.appendChild(document.createTextNode(label));
    const s = document.createElement("input"); s.type = "range"; s.min = String(min); s.max = String(max); s.value = String(get());
    s.addEventListener("input", () => { set(Number(s.value)); draw(); });
    (s as HTMLInputElement & { _sync?: () => void })._sync = () => { s.value = String(get()); };
    w2.appendChild(s); camRow.appendChild(w2); camSliders.push(s as HTMLInputElement & { _sync?: () => void });
  };
  const camSliders: Array<HTMLInputElement & { _sync?: () => void }> = [];
  mkSlider("方位", -180, 180, () => cam.az, (v) => { cam.az = v; });
  mkSlider("仰角", 5, 85, () => cam.el, (v) => { cam.el = v; });
  panel.appendChild(camRow);

  const hint = document.createElement("div"); hint.style.cssText = "opacity:.65;font-size:12px;min-height:16px;"; panel.appendChild(hint);

  const NSVG = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NSVG, "svg");
  svg.setAttribute("width", String(W)); svg.setAttribute("height", String(H));
  svg.style.cssText = "background:#ffffff;border:1px solid rgba(127,127,127,0.45);border-radius:6px;cursor:crosshair;touch-action:none;";
  panel.appendChild(svg);

  const actions = document.createElement("div");
  actions.style.cssText = "display:flex;gap:8px;align-items:center;";
  const kbd = document.createElement("span");
  kbd.textContent = "拖曳 = 旋轉 · ⌘Z 復原 · Delete 刪除 · Esc 關閉";
  kbd.style.cssText = "opacity:.55;font-size:11px;margin-right:auto;";
  actions.appendChild(kbd);
  const mkBtn = (label: string, primary: boolean, fn: () => void): void => {
    const b = document.createElement("button"); b.textContent = label;
    b.style.cssText = primary ? "background:#4a9eff;color:#fff;border:none;border-radius:6px;padding:6px 14px;cursor:pointer;" : "background:rgba(127,127,127,0.15);color:inherit;border:none;border-radius:6px;padding:6px 14px;cursor:pointer;";
    b.addEventListener("click", fn); actions.appendChild(b);
  };
  mkBtn("取消", false, close);
  mkBtn(editable ? "寫回 TikZ 區塊" : "插入 TikZ 區塊", true, writeBack);
  panel.appendChild(actions);

  // screen(px) ↔ projected-2D(cm). Origin (0,0,0) sits at canvas center.
  const toPx = (sx: number, sy: number): [number, number] => [CX + sx * PPC, CY - sy * PPC];
  const fromPx = (clientX: number, clientY: number): [number, number] => {
    const r = svg.getBoundingClientRect();
    return [(clientX - r.left - CX) / PPC, -(clientY - r.top - CY) / PPC];
  };

  function syncBar(): void {
    for (const [id, b] of toolBtns) b.style.background = id === tool ? "rgba(74,158,255,0.35)" : "rgba(127,127,127,0.12)";
    const h: Record<string, string> = {
      rotate: "拖曳畫布 = 旋轉視角。點物件 = 選取。",
      pt: "點一下放置（在 z=0 地面，用上方「高度 z」設高）。",
      vec: pending ? "再點一下 = 終點" : "點一下 = 起點",
      seg: pending ? "再點一下 = 終點" : "點一下 = 起點",
      disk: pending ? "再點一下 = 邊緣" : "點一下 = 盤中心",
      sphere: pending ? "再點一下 = 球面" : "點一下 = 球心",
      box: pending ? "再點一下 = 底面對角" : "點一下 = 底面一角",
    };
    hint.textContent = h[tool] ?? "";
  }

  function place(g: V3): void {
    const gh: V3 = [g[0], g[1], height];
    if (tool === "pt") { objs.push({ t: "pt", p: gh, label: window.prompt("點標籤（可空，支援 $math$）", "") ?? "", color }); return; }
    if (!pending) { pending = gh; syncBar(); draw(); return; }
    const a = pending; pending = null;
    if (tool === "vec" || tool === "seg") objs.push({ t: tool, a, b: gh, dash: false, color });
    else if (tool === "disk") objs.push({ t: "disk", c: a, r: Math.max(0.25, Math.hypot(gh[0] - a[0], gh[1] - a[1])), plane: "xy", dash: false, color });
    else if (tool === "sphere") objs.push({ t: "sphere", c: a, r: Math.max(0.25, Math.hypot(gh[0] - a[0], gh[1] - a[1])), color });
    else if (tool === "box") objs.push({ t: "box", c: [Math.min(a[0], gh[0]), Math.min(a[1], gh[1]), a[2]], w: Math.max(0.25, Math.abs(gh[0] - a[0])), d: Math.max(0.25, Math.abs(gh[1] - a[1])), h: 1.5, color });
  }

  /** Which object is near a screen point (projected centers). */
  function hit(sx: number, sy: number): number {
    for (let i = objs.length - 1; i >= 0; i--) {
      const o = objs[i]!;
      const c = objAnchor(o);
      const [px, py] = project(c, cam);
      if (Math.hypot(px - sx, py - sy) < 0.4) return i;
    }
    return -1;
  }

  // pointer: drag rotates the camera; a click (little move) places/selects.
  let down: { cx: number; cy: number; az: number; el: number } | null = null;
  let moved = false;
  svg.addEventListener("pointerdown", (e: PointerEvent) => {
    hist.capture();
    down = { cx: e.clientX, cy: e.clientY, az: cam.az, el: cam.el }; moved = false;
    svg.setPointerCapture(e.pointerId);
  });
  svg.addEventListener("pointermove", (e: PointerEvent) => {
    if (!down) return;
    const dx = e.clientX - down.cx, dy = e.clientY - down.cy;
    if (!moved && Math.hypot(dx, dy) < 4) return;
    moved = true;
    cam.az = down.az - dx * 0.5;
    cam.el = Math.max(5, Math.min(85, down.el + dy * 0.5));
    for (const s of camSliders) s._sync?.();
    draw();
  });
  svg.addEventListener("pointerup", (e: PointerEvent) => {
    const wasDown = down; down = null;
    if (!wasDown) return;
    if (moved) { hist.commit(); return; }   // a rotate, not a click
    const [sx, sy] = fromPx(e.clientX, e.clientY);
    if (tool === "rotate") {
      selected = hit(sx, sy);
      if (selected >= 0) colorSel.value = objs[selected]!.color;
      hist.commit(); draw();
      return;
    }
    const g = unprojectGround(sx, sy, cam);
    if (!g) { hint.textContent = "仰角太低，無法定位地面點——先抬高仰角。"; return; }
    place(g); hist.commit(); syncBar(); draw();
  });
  svg.addEventListener("lostpointercapture", () => { down = null; });

  document.addEventListener("keydown", onKey);
  function onKey(e: KeyboardEvent): void {
    if (e.key === "Escape") { close(); return; }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
      e.preventDefault(); if (e.shiftKey) hist.redo(); else hist.undo(); return;
    }
    if ((e.key === "Delete" || e.key === "Backspace") && selected >= 0 && !(e.target instanceof HTMLInputElement)) {
      e.preventDefault(); hist.capture(); objs.splice(selected, 1); hist.commit(); selected = -1; draw();
    }
  }

  function draw(): void {
    svg.replaceChildren();
    // faint ground grid (z=0), a few lines each way
    for (let g = -4; g <= 4; g++) {
      for (const [a, b] of [[[g, -4, 0], [g, 4, 0]], [[-4, g, 0], [4, g, 0]]] as const) {
        const [ax, ay] = toPx(...project(a as V3, cam)), [bx, by] = toPx(...project(b as V3, cam));
        const l = document.createElementNS(NSVG, "line");
        l.setAttribute("x1", ax.toFixed(1)); l.setAttribute("y1", ay.toFixed(1)); l.setAttribute("x2", bx.toFixed(1)); l.setAttribute("y2", by.toFixed(1));
        l.setAttribute("stroke", "#1d1f23"); l.setAttribute("stroke-opacity", g === 0 ? "0.25" : "0.07");
        svg.appendChild(l);
      }
    }
    const cmds = buildScene3d(objs, cam);
    for (const c of cmds) {
      const col = SVG_COLOR[c.color];
      const dashAttr = "dash" in c && c.dash ? "6 4" : "";
      if (c.k === "line") {
        const [ax, ay] = toPx(c.x1, c.y1), [bx, by] = toPx(c.x2, c.y2);
        const ln = document.createElementNS(NSVG, "line"); ln.setAttribute("x1", ax.toFixed(1)); ln.setAttribute("y1", ay.toFixed(1)); ln.setAttribute("x2", bx.toFixed(1)); ln.setAttribute("y2", by.toFixed(1));
        ln.setAttribute("stroke", col); ln.setAttribute("stroke-width", "2"); if (dashAttr) ln.setAttribute("stroke-dasharray", dashAttr); svg.appendChild(ln);
        if (c.arrow) { const ang = Math.atan2(by - ay, bx - ax); for (const s of [-1, 1]) { const h = document.createElementNS(NSVG, "line"); h.setAttribute("x1", bx.toFixed(1)); h.setAttribute("y1", by.toFixed(1)); h.setAttribute("x2", (bx - 9 * Math.cos(ang - s * 0.42)).toFixed(1)); h.setAttribute("y2", (by - 9 * Math.sin(ang - s * 0.42)).toFixed(1)); h.setAttribute("stroke", col); h.setAttribute("stroke-width", "2"); svg.appendChild(h); } }
      } else if (c.k === "circle") {
        const [px, py] = toPx(c.x, c.y); const el = document.createElementNS(NSVG, "circle"); el.setAttribute("cx", px.toFixed(1)); el.setAttribute("cy", py.toFixed(1)); el.setAttribute("r", (c.r * PPC).toFixed(1)); el.setAttribute("fill", "none"); el.setAttribute("stroke", col); el.setAttribute("stroke-width", "2"); svg.appendChild(el);
      } else if (c.k === "poly") {
        const pl = document.createElementNS(NSVG, c.closed ? "polygon" : "polyline"); pl.setAttribute("points", c.pts.map(([x, y]) => { const [px, py] = toPx(x, y); return `${px.toFixed(1)},${py.toFixed(1)}`; }).join(" ")); pl.setAttribute("fill", "none"); pl.setAttribute("stroke", col); pl.setAttribute("stroke-width", "1.6"); if (dashAttr) pl.setAttribute("stroke-dasharray", dashAttr); svg.appendChild(pl);
      } else if (c.k === "dot") {
        const [px, py] = toPx(c.x, c.y); const el = document.createElementNS(NSVG, "circle"); el.setAttribute("cx", px.toFixed(1)); el.setAttribute("cy", py.toFixed(1)); el.setAttribute("r", "4"); el.setAttribute("fill", col); svg.appendChild(el);
      } else if (c.k === "text") {
        const [px, py] = toPx(c.x, c.y); const t = document.createElementNS(NSVG, "text"); t.setAttribute("x", (px + 4).toFixed(1)); t.setAttribute("y", (py - 4).toFixed(1)); t.setAttribute("fill", col); t.setAttribute("font-size", "14"); t.setAttribute("font-style", "italic"); t.textContent = svgLabel(c.text).text; svg.appendChild(t);
      }
    }
    // selection ring
    if (selected >= 0 && objs[selected]) {
      const o = objs[selected]!; const c = objAnchor(o);
      const [px, py] = toPx(...project(c, cam)); const ring = document.createElementNS(NSVG, "circle");
      ring.setAttribute("cx", px.toFixed(1)); ring.setAttribute("cy", py.toFixed(1)); ring.setAttribute("r", "9"); ring.setAttribute("fill", "none"); ring.setAttribute("stroke", "#4a9eff"); ring.setAttribute("stroke-width", "2"); svg.appendChild(ring);
    }
  }

  function writeBack(): void {
    const tikz = diagram3dToTikz(objs, cam);
    if (loc && editable) view.dispatch({ changes: { from: loc.innerFrom, to: loc.innerTo, insert: tikz } });
    else view.dispatch({ changes: { from: view.state.selection.main.head, insert: `\n\`\`\`tikz\n${tikz}\n\`\`\`\n` } });
    close();
  }
  function close(): void { document.removeEventListener("keydown", onKey); overlay.remove(); view.focus(); }

  overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
  document.body.appendChild(overlay);
  syncBar(); draw();
}
