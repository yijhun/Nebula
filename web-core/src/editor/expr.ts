/**
 * expr.ts — tiny safe math-expression engine for chart function overlays.
 * Recursive-descent parser → AST → (a) JS evaluation for the SVG preview,
 * (b) pgfplots-syntax printing for chart→TikZ conversion. No eval(), no
 * Function() — a hand-rolled interpreter over a closed set of operations.
 *
 * Grammar:
 *   expr   := term (('+'|'-') term)*
 *   term   := factor (('*'|'/') factor)*
 *   factor := unary ('^' factor)?          — right-associative power
 *   unary  := '-' unary | atom
 *   atom   := number | ident '(' expr ')' | ident | '(' expr ')'
 *
 * Identifiers: known functions (sin, cos, …), constants (pi, e), the plot
 * variable x, and any other name = a free parameter (slider in the studio).
 */

export type Ast =
  | { kind: "num"; value: number }
  | { kind: "var"; name: string }
  | { kind: "neg"; arg: Ast }
  | { kind: "bin"; op: "+" | "-" | "*" | "/" | "^"; left: Ast; right: Ast }
  | { kind: "call"; fn: string; arg: Ast };

const FUNCS: Record<string, (v: number) => number> = {
  sin: Math.sin, cos: Math.cos, tan: Math.tan,
  asin: Math.asin, acos: Math.acos, atan: Math.atan,
  sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
  exp: Math.exp, ln: Math.log, log10: Math.log10, log2: Math.log2,
  sqrt: Math.sqrt, abs: Math.abs, floor: Math.floor, ceil: Math.ceil,
};
const CONSTS: Record<string, number> = { pi: Math.PI, e: Math.E };

// ── parser ────────────────────────────────────────────────────────────────

interface P { src: string; i: number }

function ws(p: P): void { while (p.i < p.src.length && /\s/.test(p.src[p.i]!)) p.i++; }
function peek(p: P): string { ws(p); return p.src[p.i] ?? ""; }
function take(p: P): string { ws(p); return p.src[p.i++] ?? ""; }

function parseExpr(p: P): Ast {
  let left = parseTerm(p);
  for (;;) {
    const c = peek(p);
    if (c !== "+" && c !== "-") return left;
    p.i++;
    left = { kind: "bin", op: c, left, right: parseTerm(p) };
  }
}

function parseTerm(p: P): Ast {
  let left = parseFactor(p);
  for (;;) {
    const c = peek(p);
    if (c !== "*" && c !== "/") return left;
    p.i++;
    left = { kind: "bin", op: c, left, right: parseFactor(p) };
  }
}

function parseFactor(p: P): Ast {
  // Unary minus binds LOOSER than ^ (math convention: -2^2 = -(2^2)).
  if (peek(p) === "-") { p.i++; return { kind: "neg", arg: parseFactor(p) }; }
  if (peek(p) === "+") { p.i++; return parseFactor(p); }
  return parsePower(p);
}

function parsePower(p: P): Ast {
  const base = parseAtom(p);
  if (peek(p) === "^") {
    p.i++;
    return { kind: "bin", op: "^", left: base, right: parseFactor(p) }; // right-assoc
  }
  return base;
}

const NUM_RE = /^(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/;
const IDENT_RE = /^[a-zA-Z_][a-zA-Z0-9_]*/;

function parseAtom(p: P): Ast {
  ws(p);
  const rest = p.src.slice(p.i);
  const num = NUM_RE.exec(rest);
  if (num) { p.i += num[0].length; return { kind: "num", value: Number(num[0]) }; }
  const id = IDENT_RE.exec(rest);
  if (id) {
    p.i += id[0].length;
    const name = id[0];
    if (peek(p) === "(") {
      if (!(name in FUNCS)) throw new Error(`未知函數 ${name}()`);
      p.i++;
      const arg = parseExpr(p);
      if (take(p) !== ")") throw new Error("缺少 )");
      return { kind: "call", fn: name, arg };
    }
    return { kind: "var", name };
  }
  if (peek(p) === "(") {
    p.i++;
    const inner = parseExpr(p);
    if (take(p) !== ")") throw new Error("缺少 )");
    return inner;
  }
  throw new Error(`無法解析：「${rest.slice(0, 12)}」`);
}

/** Parse an expression; throws Error with a readable message on bad input. */
export function parse(src: string): Ast {
  const p: P = { src, i: 0 };
  const ast = parseExpr(p);
  ws(p);
  if (p.i < p.src.length) throw new Error(`多餘的內容：「${p.src.slice(p.i, p.i + 12)}」`);
  return ast;
}

// ── evaluation ────────────────────────────────────────────────────────────

/** Evaluate with variable bindings (e.g. {x: 2, a: 3e-23}). NaN on unknown. */
export function evaluate(ast: Ast, vars: Record<string, number>): number {
  switch (ast.kind) {
    case "num": return ast.value;
    case "var":
      if (ast.name in vars) return vars[ast.name]!;
      if (ast.name in CONSTS) return CONSTS[ast.name]!;
      return NaN;
    case "neg": return -evaluate(ast.arg, vars);
    case "call": return FUNCS[ast.fn]!(evaluate(ast.arg, vars));
    case "bin": {
      const l = evaluate(ast.left, vars), r = evaluate(ast.right, vars);
      switch (ast.op) {
        case "+": return l + r;
        case "-": return l - r;
        case "*": return l * r;
        case "/": return l / r;
        case "^": return Math.pow(l, r);
      }
    }
  }
}

/** Free parameter names: variables that aren't `x` or a constant. */
export function freeParams(ast: Ast): string[] {
  const out = new Set<string>();
  const walk = (n: Ast): void => {
    switch (n.kind) {
      case "var": if (n.name !== "x" && !(n.name in CONSTS)) out.add(n.name); break;
      case "neg": walk(n.arg); break;
      case "call": walk(n.arg); break;
      case "bin": walk(n.left); walk(n.right); break;
      case "num": break;
    }
  };
  walk(ast);
  return [...out].sort();
}

// ── pgfplots printing ─────────────────────────────────────────────────────

/** pgfmath trig is degree-based; wrap radian args in deg()/rad() to keep the
 * math identical to the preview. Bound params are baked in as numbers. */
const PGF_FN: Record<string, (a: string) => string> = {
  sin: (a) => `sin(deg(${a}))`, cos: (a) => `cos(deg(${a}))`, tan: (a) => `tan(deg(${a}))`,
  asin: (a) => `rad(asin(${a}))`, acos: (a) => `rad(acos(${a}))`, atan: (a) => `rad(atan(${a}))`,
  sinh: (a) => `sinh(${a})`, cosh: (a) => `cosh(${a})`, tanh: (a) => `tanh(${a})`,
  exp: (a) => `exp(${a})`, ln: (a) => `ln(${a})`, log10: (a) => `log10(${a})`,
  log2: (a) => `log2(${a})`, sqrt: (a) => `sqrt(${a})`, abs: (a) => `abs(${a})`,
  floor: (a) => `floor(${a})`, ceil: (a) => `ceil(${a})`,
};

export function toPgf(ast: Ast, bindings: Record<string, number> = {}): string {
  const prec = (n: Ast): number =>
    n.kind === "bin" ? ({ "+": 1, "-": 1, "*": 2, "/": 2, "^": 3 } as const)[n.op]
    : n.kind === "neg" ? 1.5 : 9;
  const wrap = (child: Ast, parentPrec: number): string => {
    const s = toPgf(child, bindings);
    return prec(child) < parentPrec ? `(${s})` : s;
  };
  switch (ast.kind) {
    case "num": return String(ast.value);
    case "var":
      if (ast.name in bindings) return String(bindings[ast.name]!);
      if (ast.name === "pi") return "pi";
      if (ast.name === "e") return "exp(1)";
      return ast.name;   // x (or an unbound param — pgfplots will error visibly)
    case "neg": return `-${wrap(ast.arg, 2)}`;
    case "call": return PGF_FN[ast.fn]!(toPgf(ast.arg, bindings));
    case "bin": {
      const p0 = prec(ast);
      const l = wrap(ast.left, p0);
      // right side needs a paren when equal precedence on - / ^ subtleties;
      // keep it simple and always paren the right side of - and /.
      const r = ast.op === "-" || ast.op === "/" ? wrap(ast.right, p0 + 1) : wrap(ast.right, p0);
      return `${l}${ast.op}${r}`;
    }
  }
}
