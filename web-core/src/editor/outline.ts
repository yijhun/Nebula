/**
 * outline.ts — parse the document structure (headings + figures/tables) for the
 * native sidebar's outline section. The host renders it and calls
 * `window.notepro.scrollToPos` to jump.
 *
 * Works for both Markdown (`#` headings) and LaTeX (`\section…`, `figure`/`table`
 * environments). For LaTeX, a figure/table whose `\label` is never `\ref`'d is
 * flagged unreferenced — a pre-submission check that every float is cited.
 */
export type Mode = "markdown" | "latex";

export interface OutlineItem {
  kind: "heading" | "figure" | "table";
  level: number;
  text: string;
  pos: number;
  label?: string;
  referenced?: boolean;
}

/** Parse headings + floats from the document, in document order. */
export function parseStructure(doc: string, mode: Mode): OutlineItem[] {
  const items: OutlineItem[] = [];
  const lineStart: number[] = [0];
  for (let i = 0; i < doc.length; i++) if (doc[i] === "\n") lineStart.push(i + 1);

  if (mode === "markdown") {
    doc.split("\n").forEach((line, i) => {
      const m = /^(#{1,6})\s+(.+?)\s*#*$/.exec(line);
      if (m) items.push({ kind: "heading", level: m[1]!.length, text: m[2]!.trim(), pos: lineStart[i]! });
    });
    return items;
  }

  // LaTeX sectioning.
  doc.split("\n").forEach((line, i) => {
    const m = /\\((?:sub)*)(section|chapter)\*?\{(.*?)\}/.exec(line);
    if (m) {
      const level = m[2] === "chapter" ? 0 : m[1]!.length / 3 + 1;
      items.push({ kind: "heading", level, text: m[3]!.trim() || m[2]!, pos: lineStart[i]! });
    }
  });

  // Which labels are referenced anywhere (\ref, \eqref, \cref, …).
  const used = new Set<string>();
  const refRe = /\\(?:eq|c|C|auto|page|name|v|f)?ref\*?\{([^}]*)\}/g;
  let r: RegExpExecArray | null;
  while ((r = refRe.exec(doc))) r[1]!.split(",").forEach((s) => used.add(s.trim()));

  // Figures / tables (float environments) with caption + label.
  const envRe = /\\begin\{(figure|table)\*?\}([\s\S]*?)\\end\{\1\*?\}/g;
  let e: RegExpExecArray | null;
  while ((e = envRe.exec(doc))) {
    const kind = e[1] as "figure" | "table";
    const block = e[2]!;
    const caption = /\\caption\{([\s\S]*?)\}/.exec(block)?.[1]?.replace(/\s+/g, " ").trim() ?? "";
    const label = /\\label\{([^}]*)\}/.exec(block)?.[1];
    items.push({
      kind, level: 0, text: caption || kind, pos: e.index,
      label, referenced: label ? used.has(label) : false,
    });
  }

  items.sort((a, b) => a.pos - b.pos);
  return items;
}

