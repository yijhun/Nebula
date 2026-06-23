/**
 * lint.ts — quick math-delimiter sanity check for a document, so a single
 * unbalanced `$` / `$$` / `\begin{}` (the usual cause of LaTeX "Missing $
 * inserted" / runaway-argument errors) can be located by line instead of hunted
 * by eye through hundreds of lines.
 */
export interface LintIssue {
  line: number;        // 1-based
  message: string;
}

/** Scan for unbalanced `$`/`$$` and `\begin`/`\end`. Returns issues in order.
 * `braces` (default true) also checks `{}` and `\[ \]` — skip it for live
 * Markdown linting, where stray prose/code braces would be false positives. */
export function lintLatex(doc: string, opts: { braces?: boolean } = {}): LintIssue[] {
  const braces = opts.braces ?? true;
  const issues: LintIssue[] = [];

  // --- $ / $$ delimiter balance (a state machine, ignoring escaped \$) -------
  let inInline = false, inDisplay = false;
  let inlineLine = 0, displayLine = 0;
  let line = 1;
  for (let i = 0; i < doc.length; i++) {
    const c = doc[i]!;
    if (c === "\n") {
      // An inline `$…$` should not span a line; flag the dangling open.
      if (inInline && !inDisplay) {
        issues.push({ line: inlineLine, message: `第 ${inlineLine} 行有未配對的 $（行內公式沒有關閉）` });
        inInline = false;
      }
      line++;
      continue;
    }
    if (c === "\\") { i++; continue; } // skip escaped char (\$, \\, etc.)
    if (c === "$") {
      const dbl = doc[i + 1] === "$";
      if (inDisplay) {
        if (dbl) { inDisplay = false; i++; }   // close $$
      } else if (inInline) {
        if (!dbl) inInline = false;            // close $
        else { inDisplay = true; displayLine = line; i++; } // unusual, treat as $$ open
      } else if (dbl) {
        inDisplay = true; displayLine = line; i++;
      } else {
        inInline = true; inlineLine = line;
      }
    }
  }
  if (inDisplay) issues.push({ line: displayLine, message: `第 ${displayLine} 行有未配對的 $$（區塊公式沒有關閉）` });
  if (inInline) issues.push({ line: inlineLine, message: `第 ${inlineLine} 行有未配對的 $（行內公式沒有關閉）` });

  if (!braces) { issues.sort((a, b) => a.line - b.line); return issues; }

  // --- \[ … \] and \( … \) balance ------------------------------------------
  const open = (doc.match(/\\\[/g) || []).length, close = (doc.match(/\\\]/g) || []).length;
  if (open !== close) {
    issues.push({ line: 1, message: `\\[ 與 \\] 數量不符（${open} 個 \\[，${close} 個 \\]）— 區塊公式沒關好` });
  }

  // --- { } brace balance (skips \{ \}); pinpoints extra/unclosed braces -------
  const bstack: number[] = [];
  let bline = 1;
  for (let i = 0; i < doc.length; i++) {
    const c = doc[i]!;
    if (c === "\n") { bline++; continue; }
    if (c === "\\") { i++; continue; }          // skip escaped char (\{, \}, \\)
    if (c === "{") bstack.push(bline);
    else if (c === "}") {
      if (bstack.length === 0) {
        issues.push({ line: bline, message: `第 ${bline} 行多出 }（右大括號沒有對應的左括號）` });
      } else bstack.pop();
    }
  }
  if (bstack.length) {
    const l = bstack[bstack.length - 1]!;
    issues.push({ line: l, message: `第 ${l} 行有未關閉的 {（共 ${bstack.length} 個左大括號沒關）` });
  }

  // --- \begin{env} / \end{env} balance --------------------------------------
  const stack: Array<{ env: string; line: number }> = [];
  const lines = doc.split("\n");
  const RE = /\\(begin|end)\{([a-zA-Z*]+)\}/g;
  lines.forEach((text, idx) => {
    let m: RegExpExecArray | null;
    RE.lastIndex = 0;
    while ((m = RE.exec(text))) {
      if (m[1] === "begin") stack.push({ env: m[2]!, line: idx + 1 });
      else {
        const top = stack.pop();
        if (!top) issues.push({ line: idx + 1, message: `第 ${idx + 1} 行多出 \\end{${m[2]}}` });
        else if (top.env !== m[2]) issues.push({ line: idx + 1, message: `第 ${idx + 1} 行 \\end{${m[2]}} 與 \\begin{${top.env}}（第 ${top.line} 行）不符` });
      }
    }
  });
  for (const s of stack) issues.push({ line: s.line, message: `第 ${s.line} 行 \\begin{${s.env}} 沒有對應的 \\end` });

  issues.sort((a, b) => a.line - b.line);
  return issues;
}
