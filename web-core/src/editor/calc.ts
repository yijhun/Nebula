/**
 * calc.ts — inline & block arithmetic for the preview, on top of the safe
 * expression engine used by chart overlays (expr.ts, no eval()).
 *
 *   L1 inline:  `= 3*(4+2)`      → "3*(4+2) = 18"
 *   L2 block:   ```calc
 *               m = 5
 *               v = 10
 *               p = m*v          → p = m*v = 50
 *               ```
 *
 * Assignments (`name = expr`, LHS a bare identifier) accumulate into a variable
 * environment reused by later lines. Bare expressions just evaluate. Errors are
 * reported per line (block) or leave the source untouched (inline).
 */
import { parse as parseExpr, evaluate } from "./expr.js";

/** Format a number for display: integers as-is, else ~6 sig figs, trailing
 * zeros trimmed, exponential kept for very large/small magnitudes. */
export function fmtNum(v: number): string {
  if (!Number.isFinite(v)) return String(v);
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v);
  const s = v.toPrecision(6);
  return s.includes("e")
    ? s.replace(/\.?0+e/, "e")
    : s.replace(/\.?0+$/, "");
}

const IDENT_ASSIGN = /^([a-zA-Z_]\w*)\s*=\s*(.+)$/;

/** Evaluate one calc line against (and possibly mutating) `vars`. */
export interface CalcLine {
  kind: "comment" | "result" | "error";
  name?: string;      // assignment target, if any
  expr?: string;      // the expression source
  value?: string;     // formatted result
  text: string;       // comment text / error message
}

export function evalCalcLine(line: string, vars: Record<string, number>): CalcLine | null {
  const t = line.trim();
  if (!t) return null;
  if (t.startsWith("#") || t.startsWith("//")) {
    return { kind: "comment", text: t.replace(/^(#|\/\/)\s?/, "") };
  }
  // `name = expr` only when the left of the first '=' is a bare identifier
  // (so `x^2 = 4` is NOT treated as assignment — it just fails to parse).
  const asg = IDENT_ASSIGN.exec(t);
  const name = asg ? asg[1]! : "";
  const exprSrc = asg ? asg[2]! : t;
  try {
    const v = evaluate(parseExpr(exprSrc), vars);
    if (!Number.isFinite(v)) {
      return { kind: "error", expr: exprSrc, name, text: "結果不是有限數（可能用了未定義變數）" };
    }
    if (name) vars[name] = v;
    return { kind: "result", name, expr: exprSrc, value: fmtNum(v), text: "" };
  } catch (e) {
    return { kind: "error", name, expr: exprSrc, text: e instanceof Error ? e.message : String(e) };
  }
}

function esc(s: string): string {
  return s.replace(/[&<>"]/g, (c) =>
    c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;");
}

/** Render a ```calc block to an HTML string (a table of expr = value rows). */
export function renderCalcBlock(src: string): string {
  const vars: Record<string, number> = {};
  const rows: string[] = [];
  for (const raw of src.split("\n")) {
    const r = evalCalcLine(raw, vars);
    if (!r) continue;
    if (r.kind === "comment") {
      rows.push(`<div class="np-calc-comment">${esc(r.text)}</div>`);
      continue;
    }
    const label = r.name ? `${esc(r.name)} = ${esc(r.expr ?? "")}` : esc(r.expr ?? "");
    if (r.kind === "error") {
      rows.push(
        `<div class="np-calc-row np-calc-err"><span class="np-calc-expr">${label}</span>` +
        `<span class="np-calc-eq">⚠</span><span class="np-calc-val">${esc(r.text)}</span></div>`);
    } else {
      rows.push(
        `<div class="np-calc-row"><span class="np-calc-expr">${label}</span>` +
        `<span class="np-calc-eq">=</span><span class="np-calc-val">${esc(r.value ?? "")}</span></div>`);
    }
  }
  return `<div class="np-calc-block">${rows.join("")}</div>`;
}

/** Evaluate an inline `= expr`. Returns the display text, or null to leave the
 * source untouched (so ``= operator``-style code isn't mangled). */
export function evalInline(exprSrc: string): string | null {
  try {
    const v = evaluate(parseExpr(exprSrc), {});
    if (!Number.isFinite(v)) return null;
    return `${exprSrc.trim()} = ${fmtNum(v)}`;
  } catch {
    return null;
  }
}
