/**
 * chartStudio.ts — the interactive chart editor ("圖表工作室"). A GeoGebra-like
 * panel, but native: live SVG preview on the left, controls on the right —
 * type/axes/labels, a data textarea, function rows, and PARAMETER SLIDERS
 * (every free variable in a plot expression gets one; drag → curve updates
 * live). Writes back to the ```chart block in the note, and can insert the
 * publication-grade ```tikz translation below it.
 */
import type { EditorView } from "@codemirror/view";
import {
  parseChartSource, serializeChart, renderChart, undeclaredParams,
  defaultParamRange, type ChartSpec,
} from "./chart.js";
import { chartToTikz } from "./chartTikz.js";

interface BlockLoc { innerFrom: number; innerTo: number; fenceEnd: number }

/** Locate the ```chart fenced block around the cursor. */
export function findChartBlock(view: EditorView): BlockLoc | null {
  const doc = view.state.doc;
  const cur = doc.lineAt(view.state.selection.main.head).number;
  // Scan up for the opening fence (```chart) without crossing another fence.
  let open = -1;
  for (let n = cur; n >= 1; n--) {
    const t = doc.line(n).text.trim();
    if (/^```chart\s*$/.test(t)) { open = n; break; }
    if (/^```/.test(t) && n !== cur) break;   // some other fence → not inside
  }
  if (open === -1) return null;
  let close = -1;
  for (let n = Math.max(cur, open + 1); n <= doc.lines; n++) {
    const t = doc.line(n).text.trim();
    if (n > open && /^```\s*$/.test(t)) { close = n; break; }
  }
  if (close === -1 || cur > close) return null;
  return {
    innerFrom: doc.line(open).to + 1,
    innerTo: doc.line(close).from > doc.line(open).to + 1 ? doc.line(close).from - 1 : doc.line(open).to + 1,
    fenceEnd: doc.line(close).to,
  };
}

/** Menu command: translate the chart block at the cursor into a ```tikz block
 * inserted below it (keeps the draft). Returns "ok" | "no-chart" | "error". */
export function insertTikzBelow(view: EditorView): string {
  const loc = findChartBlock(view);
  if (!loc) return "no-chart";
  const src = view.state.sliceDoc(loc.innerFrom, loc.innerTo);
  const tikz = chartToTikz(src);
  if (tikz.startsWith("error:")) return tikz;
  view.dispatch({
    changes: { from: loc.fenceEnd, insert: `\n\n\`\`\`tikz\n${tikz}\n\`\`\`\n` },
    scrollIntoView: true,
  });
  return "ok";
}

const DEFAULT_SRC = `type: scatter
x, y
0, 1
1, 2.2
2, 2.8
plot: a * sqrt(x)
param: a = 2 [0, 5]`;

/** Open the interactive editor for the chart block at the cursor (or start a
 * new block that will be inserted at the cursor on save). */
export function openChartStudio(view: EditorView): void {
  if (document.querySelector(".np-chart-studio")) return;   // one at a time
  const loc = findChartBlock(view);
  const src = loc ? view.state.sliceDoc(loc.innerFrom, loc.innerTo) : DEFAULT_SRC;
  const parsed = parseChartSource(src);
  const spec: ChartSpec = typeof parsed === "string"
    ? (parseChartSource(DEFAULT_SRC) as ChartSpec)
    : parsed;
  // Promote every free variable in the plots to a slider parameter.
  for (const name of undeclaredParams(spec)) {
    const [min, max] = defaultParamRange(1);
    spec.params.push({ name, value: 1, min, max });
  }

  // ── overlay scaffolding — panel follows the app theme; the chart preview
  // sits on a WHITE paper card (dark ink ticks stay readable in dark mode,
  // and it matches how the chart looks in the preview pane / PDF). ──
  const light = document.body.classList.contains("np-light");
  const overlay = document.createElement("div");
  overlay.className = "np-chart-studio";
  overlay.style.cssText =
    "position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.35);display:flex;" +
    "align-items:center;justify-content:center;";
  const panel = document.createElement("div");
  panel.style.cssText =
    `background:${light ? "#ffffff" : "#23252b"};color:${light ? "#1d1f23" : "#dddddd"};` +
    "border-radius:10px;padding:14px;" +
    "width:min(960px,94vw);max-height:90vh;overflow:auto;display:flex;gap:14px;" +
    "box-shadow:0 12px 40px rgba(0,0,0,0.45);font-size:13px;";
  overlay.appendChild(panel);

  const left = document.createElement("div");
  left.style.cssText = "flex:1 1 55%;min-width:320px;";
  const right = document.createElement("div");
  right.style.cssText = "flex:1 1 45%;min-width:280px;display:flex;flex-direction:column;gap:8px;";
  panel.appendChild(left); panel.appendChild(right);

  const chartBox = document.createElement("div");
  // White paper card: the SVG's currentColor ticks/axes resolve to dark ink.
  chartBox.style.cssText =
    "background:#ffffff;color:#1d1f23;border:1px solid rgba(127,127,127,0.45);" +
    "border-radius:6px;padding:8px;";
  left.appendChild(chartBox);
  const errBox = document.createElement("div");
  errBox.style.cssText = "color:#dc2626;font-size:12px;min-height:16px;margin-top:6px;";
  left.appendChild(errBox);

  const row = (label: string, el: HTMLElement): HTMLElement => {
    const r = document.createElement("label");
    r.style.cssText = "display:flex;align-items:center;gap:6px;";
    const s = document.createElement("span");
    s.textContent = label;
    s.style.cssText = "opacity:.7;min-width:52px;flex:none;";
    r.appendChild(s); r.appendChild(el);
    return r;
  };
  const textInput = (value: string, onInput: (v: string) => void): HTMLInputElement => {
    const i = document.createElement("input");
    i.type = "text"; i.value = value;
    i.style.cssText = "flex:1;background:rgba(127,127,127,0.12);border:1px solid rgba(127,127,127,0.3);" +
      "border-radius:5px;padding:3px 7px;color:inherit;font:inherit;min-width:0;";
    i.addEventListener("input", () => { onInput(i.value); refresh(); });
    return i;
  };

  // type + log toggles
  const typeSel = document.createElement("select");
  typeSel.style.cssText = "background:rgba(127,127,127,0.12);color:inherit;border-radius:5px;padding:3px;";
  for (const t of ["line", "scatter", "bar"]) {
    const o = document.createElement("option");
    o.value = t; o.textContent = t; if (spec.type === t) o.selected = true;
    typeSel.appendChild(o);
  }
  typeSel.addEventListener("change", () => { spec.type = typeSel.value as ChartSpec["type"]; refresh(); });

  const check = (label: string, get: () => boolean, set: (v: boolean) => void): HTMLElement => {
    const l = document.createElement("label");
    l.style.cssText = "display:inline-flex;align-items:center;gap:4px;margin-right:10px;cursor:pointer;";
    const c = document.createElement("input");
    c.type = "checkbox"; c.checked = get();
    c.addEventListener("change", () => { set(c.checked); refresh(); });
    l.appendChild(c); l.appendChild(document.createTextNode(label));
    return l;
  };

  const toggles = document.createElement("div");
  toggles.appendChild(check("log x", () => spec.xlog, (v) => { spec.xlog = v; }));
  toggles.appendChild(check("log y", () => spec.ylog, (v) => { spec.ylog = v; }));
  toggles.appendChild(check("y 反轉", () => spec.yflip, (v) => { spec.yflip = v; }));

  const head = document.createElement("div");
  head.style.cssText = "display:flex;align-items:center;gap:8px;";
  const headTitle = document.createElement("b");
  headTitle.textContent = "圖表工作室";
  head.appendChild(headTitle);
  head.appendChild(typeSel);
  head.appendChild(toggles);
  right.appendChild(head);

  right.appendChild(row("標題", textInput(spec.title, (v) => { spec.title = v; })));
  right.appendChild(row("x 標籤", textInput(spec.xLabel, (v) => { spec.xLabel = v; })));
  right.appendChild(row("y 標籤", textInput(spec.yLabel, (v) => { spec.yLabel = v; })));

  // data textarea
  const dataLabel = document.createElement("div");
  dataLabel.textContent = "數據（表頭 + 數列；欄名以 err 結尾 = 誤差棒）";
  dataLabel.style.cssText = "opacity:.7;margin-top:2px;";
  right.appendChild(dataLabel);
  const dataTa = document.createElement("textarea");
  dataTa.value = spec.dataLines.join("\n");
  dataTa.rows = 6;
  dataTa.style.cssText = "width:100%;box-sizing:border-box;background:rgba(127,127,127,0.12);" +
    "border:1px solid rgba(127,127,127,0.3);border-radius:5px;padding:6px;color:inherit;" +
    "font:12px ui-monospace,monospace;resize:vertical;";
  dataTa.addEventListener("input", () => {
    spec.dataLines = dataTa.value.split("\n").map((l) => l.trim()).filter(Boolean);
    refresh();
  });
  right.appendChild(dataTa);

  // plots
  const plotsBox = document.createElement("div");
  plotsBox.style.cssText = "display:flex;flex-direction:column;gap:4px;";
  right.appendChild(plotsBox);
  const paramsBox = document.createElement("div");
  paramsBox.style.cssText = "display:flex;flex-direction:column;gap:4px;";
  right.appendChild(paramsBox);

  const rebuildPlots = (): void => {
    plotsBox.replaceChildren();
    const lbl = document.createElement("div");
    lbl.textContent = "函數疊加（用 x；其他變數自動變滑桿參數）";
    lbl.style.cssText = "opacity:.7;";
    plotsBox.appendChild(lbl);
    spec.plots.forEach((pl, i) => {
      const r = document.createElement("div");
      r.style.cssText = "display:flex;gap:4px;align-items:center;";
      const e = textInput(pl.exprSrc, (v) => { pl.exprSrc = v; syncParams(); });
      e.placeholder = "a * x^0.9";
      const x = document.createElement("button");
      x.textContent = "✕";
      x.style.cssText = "border:none;background:transparent;color:inherit;opacity:.6;cursor:pointer;";
      x.addEventListener("click", () => { spec.plots.splice(i, 1); rebuildPlots(); syncParams(); });
      r.appendChild(e); r.appendChild(x);
      plotsBox.appendChild(r);
    });
    const add = document.createElement("button");
    add.textContent = "＋ 新增函數";
    add.style.cssText = "align-self:flex-start;border:1px dashed rgba(127,127,127,0.5);" +
      "background:transparent;color:inherit;border-radius:5px;padding:2px 8px;cursor:pointer;";
    add.addEventListener("click", () => {
      spec.plots.push({ name: "", exprSrc: "a * x" });
      rebuildPlots(); syncParams();
    });
    plotsBox.appendChild(add);
  };

  const rebuildParams = (): void => {
    paramsBox.replaceChildren();
    if (!spec.params.length) return;
    const lbl = document.createElement("div");
    lbl.textContent = "參數滑桿";
    lbl.style.cssText = "opacity:.7;";
    paramsBox.appendChild(lbl);
    for (const prm of spec.params) {
      const r = document.createElement("div");
      r.style.cssText = "display:flex;gap:6px;align-items:center;";
      const name = document.createElement("code");
      name.textContent = prm.name;
      name.style.cssText = "min-width:24px;";
      const slider = document.createElement("input");
      slider.type = "range";
      slider.min = String(prm.min); slider.max = String(prm.max);
      slider.step = String((prm.max - prm.min) / 200 || 0.01);
      slider.value = String(prm.value);
      slider.style.cssText = "flex:1;";
      const val = document.createElement("input");
      val.type = "text"; val.value = String(prm.value);
      val.style.cssText = "width:76px;background:rgba(127,127,127,0.12);border:1px solid " +
        "rgba(127,127,127,0.3);border-radius:5px;padding:2px 5px;color:inherit;font:inherit;";
      slider.addEventListener("input", () => {
        prm.value = Number(slider.value);
        val.value = String(prm.value);
        refresh();
      });
      val.addEventListener("change", () => {
        const n = Number(val.value);
        if (Number.isFinite(n)) {
          prm.value = n;
          const [dmin, dmax] = defaultParamRange(n);
          if (n < prm.min || n > prm.max) { prm.min = dmin; prm.max = dmax; slider.min = String(dmin); slider.max = String(dmax); slider.step = String((dmax - dmin) / 200 || 0.01); }
          slider.value = String(n);
          refresh();
        }
      });
      r.appendChild(name); r.appendChild(slider); r.appendChild(val);
      paramsBox.appendChild(r);
    }
  };

  /** Keep the param list in sync with the free variables used by the plots. */
  const syncParams = (): void => {
    const used = new Set(undeclaredParams({ ...spec, params: [] }));
    spec.params = spec.params.filter((p0) => used.has(p0.name));
    const have = new Set(spec.params.map((p0) => p0.name));
    for (const n of used) {
      if (!have.has(n)) {
        const [min, max] = defaultParamRange(1);
        spec.params.push({ name: n, value: 1, min, max });
      }
    }
    rebuildParams();
    refresh();
  };

  const refresh = (): void => {
    const src2 = serializeChart(spec);
    const html = renderChart(src2);
    chartBox.innerHTML = html;
    errBox.textContent = html.includes("np-chart-error")
      ? chartBox.textContent ?? "" : "";
  };

  // ── action buttons ──
  const actions = document.createElement("div");
  actions.style.cssText = "display:flex;gap:8px;margin-top:auto;justify-content:flex-end;";
  const btn = (label: string, primary: boolean, onClick: () => void): HTMLButtonElement => {
    const b = document.createElement("button");
    b.textContent = label;
    b.style.cssText = primary
      ? "background:#4a9eff;color:#fff;border:none;border-radius:6px;padding:6px 14px;cursor:pointer;"
      : "background:rgba(127,127,127,0.15);color:inherit;border:none;border-radius:6px;padding:6px 14px;cursor:pointer;";
    b.addEventListener("click", onClick);
    return b;
  };

  const writeBack = (alsoTikz: boolean): void => {
    const out = serializeChart(spec);
    if (loc) {
      view.dispatch({ changes: { from: loc.innerFrom, to: loc.innerTo, insert: out } });
    } else {
      const pos = view.state.selection.main.head;
      view.dispatch({
        changes: { from: pos, insert: `\n\`\`\`chart\n${out}\n\`\`\`\n` },
      });
    }
    if (alsoTikz) {
      // Re-locate (positions moved after the first dispatch), then insert.
      const fresh = findChartBlock(view);
      if (fresh) {
        const tikz = chartToTikz(view.state.sliceDoc(fresh.innerFrom, fresh.innerTo));
        if (!tikz.startsWith("error:")) {
          view.dispatch({
            changes: { from: fresh.fenceEnd, insert: `\n\n\`\`\`tikz\n${tikz}\n\`\`\`\n` },
          });
        }
      }
    }
    close();
  };

  const close = (): void => { overlay.remove(); view.focus(); };

  actions.appendChild(btn("取消", false, close));
  actions.appendChild(btn("寫回筆記＋TikZ 版", false, () => writeBack(true)));
  actions.appendChild(btn("寫回筆記", true, () => writeBack(false)));
  right.appendChild(actions);

  overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
  document.addEventListener("keydown", function esc(e) {
    if (e.key === "Escape") { close(); document.removeEventListener("keydown", esc); }
  });

  document.body.appendChild(overlay);
  rebuildPlots();
  rebuildParams();
  refresh();
}
