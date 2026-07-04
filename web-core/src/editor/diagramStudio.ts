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

// ── model ─────────────────────────────────────────────────────────────────

type Color = "black" | "blue" | "red" | "green";

type Obj =
  | { t: "pt"; x: number; y: number; label: string; color: Color }
  | { t: "seg" | "arr"; x1: number; y1: number; x2: number; y2: number; dash: boolean; color: Color }
  | { t: "circ"; x: number; y: number; r: number; dash: boolean; color: Color }
  | { t: "ell"; x: number; y: number; rx: number; ry: number; dash: boolean; color: Color }
  | { t: "lbl"; x: number; y: number; text: string; color: Color };

const TIKZ_COLOR: Record<Color, string> = {
  black: "", blue: "blue", red: "red", green: "green!60!black",
};
const SVG_COLOR: Record<Color, string> = {
  black: "currentColor", blue: "#4a9eff", red: "#ff6b6b", green: "#37b24d",
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

  let tool: "select" | "pt" | "seg" | "arr" | "circ" | "ell" | "lbl" = objs.length ? "select" : "arr";
  let color: Color = "black";
  let dashed = false;
  let pending: { x: number; y: number } | null = null;   // first click of 2-click tools
  let selected = -1;
  let dragOff: { dx: number; dy: number } | null = null;

  // overlay scaffolding
  const overlay = document.createElement("div");
  overlay.className = "np-diagram-studio";
  overlay.style.cssText =
    "position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.35);display:flex;" +
    "align-items:center;justify-content:center;";
  const panel = document.createElement("div");
  panel.style.cssText =
    "background:var(--np-bg, #23252b);color:inherit;border-radius:10px;padding:12px;" +
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
    b.addEventListener("click", () => { tool = id; pending = null; syncBar(); });
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

  const delBtn = document.createElement("button");
  delBtn.textContent = "刪除選取";
  delBtn.style.cssText = "border:none;background:rgba(220,38,38,0.18);color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;";
  delBtn.addEventListener("click", deleteSelected);
  bar.appendChild(delBtn);

  const hint = document.createElement("div");
  hint.style.cssText = "opacity:.65;font-size:12px;min-height:16px;";
  panel.appendChild(hint);

  // canvas
  const NSVG = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NSVG, "svg");
  svg.setAttribute("width", String(WCM * PPC));
  svg.setAttribute("height", String(HCM * PPC));
  svg.style.cssText = "background:rgba(127,127,127,0.06);border:1px solid rgba(127,127,127,0.3);" +
    "border-radius:6px;cursor:crosshair;touch-action:none;";
  panel.appendChild(svg);

  // actions
  const actions = document.createElement("div");
  actions.style.cssText = "display:flex;gap:8px;justify-content:flex-end;";
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
      }
    }
    return -1;
  }

  function objCenter(o: Obj): [number, number] {
    switch (o.t) {
      case "pt": case "lbl": case "circ": case "ell": return [o.x, o.y];
      case "seg": case "arr": return [(o.x1 + o.x2) / 2, (o.y1 + o.y2) / 2];
    }
  }

  function moveObj(o: Obj, dx: number, dy: number): void {
    switch (o.t) {
      case "pt": case "lbl": case "circ": case "ell": o.x += dx; o.y += dy; break;
      case "seg": case "arr": o.x1 += dx; o.y1 += dy; o.x2 += dx; o.y2 += dy; break;
    }
  }

  function deleteSelected(): void {
    if (selected >= 0) { objs.splice(selected, 1); selected = -1; draw(); }
  }

  // pointer interaction
  svg.addEventListener("pointerdown", (e: PointerEvent) => {
    const [x, y] = toWorld(e);
    if (tool === "select") {
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
    // 2-click tools
    if (!pending) { pending = { x, y }; syncBar(); draw(); return; }
    const a = pending; pending = null;
    if (tool === "seg" || tool === "arr") {
      objs.push({ t: tool, x1: a.x, y1: a.y, x2: x, y2: y, dash: dashed, color });
    } else if (tool === "circ") {
      objs.push({ t: "circ", x: a.x, y: a.y, r: Math.max(SNAP, Math.hypot(x - a.x, y - a.y)), dash: dashed, color });
    } else if (tool === "ell") {
      objs.push({ t: "ell", x: a.x, y: a.y, rx: Math.max(SNAP, Math.abs(x - a.x)), ry: Math.max(SNAP, Math.abs(y - a.y)), dash: dashed, color });
    }
    syncBar();
    draw();
  });
  svg.addEventListener("pointermove", (e: PointerEvent) => {
    if (tool === "select" && dragOff && selected >= 0) {
      const [x, y] = toWorld(e);
      const o = objs[selected]!;
      const [cx, cy] = objCenter(o);
      moveObj(o, x + dragOff.dx - cx, y + dragOff.dy - cy);
      draw();
    }
  });
  svg.addEventListener("pointerup", () => { dragOff = null; });
  svg.addEventListener("dblclick", (e: MouseEvent) => {
    const [x, y] = toWorld(e);
    const i = hitTest(x, y);
    const o = i >= 0 ? objs[i] : undefined;
    if (o && (o.t === "lbl" || o.t === "pt")) {
      const cur = o.t === "lbl" ? o.text : o.label;
      const next = window.prompt("編輯文字", cur);
      if (next !== null) {
        if (o.t === "lbl") o.text = next; else o.label = next;
        draw();
      }
    }
  });
  document.addEventListener("keydown", onKey);
  function onKey(e: KeyboardEvent): void {
    if (e.key === "Escape") { close(); return; }
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
    for (let gx = Math.ceil(X0); gx <= X0 + WCM; gx++) {
      const [px] = toPx(gx, 0);
      const l = document.createElementNS(NSVG, "line");
      l.setAttribute("x1", String(px)); l.setAttribute("x2", String(px));
      l.setAttribute("y1", "0"); l.setAttribute("y2", String(HCM * PPC));
      l.setAttribute("stroke", "currentColor");
      l.setAttribute("stroke-opacity", gx === 0 ? "0.35" : "0.08");
      svg.appendChild(l);
    }
    for (let gy = Math.ceil(Y1 - HCM); gy <= Y1; gy++) {
      const [, py] = toPx(0, gy);
      const l = document.createElementNS(NSVG, "line");
      l.setAttribute("y1", String(py)); l.setAttribute("y2", String(py));
      l.setAttribute("x1", "0"); l.setAttribute("x2", String(WCM * PPC));
      l.setAttribute("stroke", "currentColor");
      l.setAttribute("stroke-opacity", gy === 0 ? "0.35" : "0.08");
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
      }
    });
    // pending first-click marker
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
