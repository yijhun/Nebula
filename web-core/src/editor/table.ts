/**
 * table.ts — Markdown table editing commands. Finds the pipe-table around the
 * cursor, transforms it (insert/delete row/column, cycle alignment, pretty
 * format), and replaces the block in one dispatch. Exposed to the native menu
 * via `window.notepro.tableOp(op)`.
 */
import type { EditorView } from "@codemirror/view";

export type TableOp =
  | "format" | "insertRowBelow" | "insertColRight"
  | "deleteRow" | "deleteCol" | "cycleAlign";

interface Table {
  fromLine: number;          // 1-based first line of the block
  toLine: number;            // 1-based last line
  rows: string[][];          // cell text (trimmed), header = rows[0]
  aligns: string[];          // ":--" / ":-:" / "--:" / "---" per column
  cursorRow: number;         // row index the cursor is on (delimiter row → 0)
  cursorCol: number;         // column index the cursor is in
}

const DELIM = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;

function splitCells(line: string): string[] {
  // Strip one leading/trailing pipe, then split on unescaped |.
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|")) s = s.slice(0, -1);
  const cells: string[] = [];
  let cur = "";
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && s[i + 1] === "|") { cur += "\\|"; i++; continue; }
    if (s[i] === "|") { cells.push(cur.trim()); cur = ""; continue; }
    cur += s[i];
  }
  cells.push(cur.trim());
  return cells;
}

function parseAlign(cell: string): string {
  const c = cell.trim();
  const left = c.startsWith(":");
  const right = c.endsWith(":");
  return left && right ? ":-:" : right ? "--:" : left ? ":--" : "---";
}

/** Locate + parse the table around the cursor; null when not in a table. */
function tableAtCursor(view: EditorView): Table | null {
  const doc = view.state.doc;
  const pos = view.state.selection.main.head;
  const curLine = doc.lineAt(pos);
  if (!/^\s*\|/.test(curLine.text) && !DELIM.test(curLine.text)) return null;

  let first = curLine.number;
  while (first > 1 && /^\s*\|/.test(doc.line(first - 1).text)) first--;
  let last = curLine.number;
  while (last < doc.lines && /^\s*\|/.test(doc.line(last + 1).text)) last++;
  if (last - first < 1) return null;   // need at least header + delimiter

  const lines: string[] = [];
  for (let n = first; n <= last; n++) lines.push(doc.line(n).text);
  if (!DELIM.test(lines[1] ?? "")) return null;

  const header = splitCells(lines[0]!);
  const aligns = splitCells(lines[1]!).map(parseAlign);
  const rows: string[][] = [header];
  for (let i = 2; i < lines.length; i++) rows.push(splitCells(lines[i]!));

  // Cursor cell: count unescaped pipes before the cursor on its line.
  const upto = curLine.text.slice(0, pos - curLine.from);
  let col = 0;
  for (let i = 0; i < upto.length; i++) {
    if (upto[i] === "\\" && upto[i + 1] === "|") { i++; continue; }
    if (upto[i] === "|") col++;
  }
  col = Math.max(0, Math.min(col - 1, header.length - 1));
  const lineIdx = curLine.number - first;
  const cursorRow = lineIdx === 1 ? 0 : lineIdx > 1 ? lineIdx - 1 : 0;

  return { fromLine: first, toLine: last, rows, aligns, cursorRow, cursorCol: col };
}

/** Render rows+aligns back to pretty-printed Markdown (padded columns). */
function render(rows: string[][], aligns: string[]): string {
  const cols = Math.max(aligns.length, ...rows.map((r) => r.length));
  const norm = rows.map((r) => Array.from({ length: cols }, (_, i) => r[i] ?? ""));
  const width = (i: number) => Math.max(3, ...norm.map((r) => r[i]!.length));
  const widths = Array.from({ length: cols }, (_, i) => width(i));
  const pad = (s: string, w: number) => s + " ".repeat(w - s.length);
  const line = (r: string[]) => "| " + r.map((c, i) => pad(c, widths[i]!)).join(" | ") + " |";
  const delim = "| " + widths.map((w, i) => {
    const a = aligns[i] ?? "---";
    const dashes = (n: number) => "-".repeat(Math.max(2, n));
    if (a === ":-:") return ":" + dashes(w - 2) + ":";
    if (a === "--:") return dashes(w - 1) + ":";
    if (a === ":--") return ":" + dashes(w - 1);
    return dashes(w);
  }).join(" | ") + " |";
  return [line(norm[0]!), delim, ...norm.slice(1).map(line)].join("\n");
}

/** Apply a table operation at the cursor. Returns false when not in a table. */
export function tableOp(view: EditorView, op: TableOp): boolean {
  const t = tableAtCursor(view);
  if (!t) return false;
  const { rows, aligns, cursorRow, cursorCol } = t;
  const cols = rows[0]!.length;

  switch (op) {
    case "format":
      break; // render() below pretty-prints
    case "insertRowBelow": {
      const at = Math.max(1, cursorRow + 1); // never above the header
      rows.splice(at, 0, Array.from({ length: cols }, () => ""));
      break;
    }
    case "insertColRight": {
      for (const r of rows) r.splice(cursorCol + 1, 0, "");
      aligns.splice(cursorCol + 1, 0, "---");
      break;
    }
    case "deleteRow": {
      if (cursorRow === 0 || rows.length <= 2) return false; // keep header + 1
      rows.splice(cursorRow, 1);
      break;
    }
    case "deleteCol": {
      if (cols <= 1) return false;
      for (const r of rows) r.splice(cursorCol, 1);
      aligns.splice(cursorCol, 1);
      break;
    }
    case "cycleAlign": {
      const order = ["---", ":--", ":-:", "--:"];
      const cur = aligns[cursorCol] ?? "---";
      aligns[cursorCol] = order[(order.indexOf(cur) + 1) % order.length]!;
      break;
    }
  }

  const doc = view.state.doc;
  const from = doc.line(t.fromLine).from;
  const to = doc.line(t.toLine).to;
  view.dispatch({
    changes: { from, to, insert: render(rows, aligns) },
    scrollIntoView: true,
  });
  view.focus();
  return true;
}
