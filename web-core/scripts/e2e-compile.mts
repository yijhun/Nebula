/**
 * e2e-compile.mts — end-to-end regression: convert a corpus of realistic notes
 * (Markdown → LaTeX) and actually compile each with Tectonic, asserting a PDF
 * is produced. Catches "unit tests pass but the real pipeline won't compile".
 *
 * Run: npm run -w @notepro/web-core e2e   (needs the `tectonic` binary)
 */
import { convert } from "../src/latex/index.ts";
import { convertProject } from "../src/latex/project.ts";
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";

const TECTONIC = ["/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic"]
  .find((p) => existsSync(p));
if (!TECTONIC) { console.error("tectonic not found — skipping e2e"); process.exit(0); }

const BIB = `@article{balbus1991, title={A powerful local shear instability}, author={Balbus, S. and Hawley, J.}, journal={ApJ}, year={1991}, volume={376}, pages={214}}
@article{ulrich1976, title={An infall model}, author={Ulrich, R.}, journal={ApJ}, year={1976}, volume={210}, pages={377}}
`;

interface Case { name: string; md: string; opts?: Record<string, unknown>; }

const CASES: Case[] = [
  { name: "basic", md: "# Intro\n\n**Bold**, *em*, `code`, and $E=mc^2$.\n\n- a\n- b\n" },
  { name: "display-and-align", md: "# Math\n\n$$ \\nabla\\cdot\\mathbf{B}=0 $$\n\n$$\n\\begin{aligned} x &= 1 \\\\ y &= 2 \\end{aligned}\n$$\n" },
  { name: "wide-matrix", md: "# Rot\n\n$$ \\boxed{ \\mathbf{R} = \\begin{pmatrix} \\cos\\phi & -\\sin\\phi & 0 & a & b & c \\\\ \\sin\\phi & \\cos\\phi & 0 & d & e & f \\\\ 0 & 0 & 1 & g & h & i \\end{pmatrix} } $$\n" },
  { name: "cases", md: "# Cases\n\n$$\n\\cos\\theta_0 = \\begin{cases} (\\cos\\theta)^{1/3}, & r=1, \\\\[6pt] 2\\sqrt{\\alpha}\\sinh(x), & r>1. \\end{cases}\n$$\n" },
  { name: "blank-line-in-math", md: "# B\n\n$$\n\\boxed{ \\mathbf{R} =\n\n1 }\n$$\n" },
  { name: "citations-biblatex", md: "# Refs\n\nMRI matters [@balbus1991]. Infall [@ulrich1976, p. 5].\n" },
  { name: "table", md: "# T\n\n| Param | Value |\n|---|---|\n| $T_0$ | 2223 K |\n| $q$ | 1.2 |\n" },
  { name: "callout-tasklist", md: "# C\n\n> [!note] Heads up\n> body\n\n- [ ] todo\n- [x] done\n" },
  { name: "unicode", md: "# U\n\nValues: α=1, ×10⁸, M⊙, T∝r⁻², 2.5 × 10⁻³.\n" },
  { name: "cjk", md: "# 中文\n\n這是中文與數學 $E=mc^2$ 混排。\n" },
  { name: "raw-latex-env", md: "# Raw\n\n\\begin{equation}\nF = ma\n\\end{equation}\n" },
  { name: "apj-paper", md: "---\ntitle: Accretion Disk\nauthor: A. Astronomer\n---\n# Introduction\n\nWe study disks [@balbus1991] with $T(r)=T_0(r/r_0)^{-q}$.\n", opts: { defaultTemplate: "apj" } },
  // ── this-era features: charts, fits, diagram tikz, journal templates ──
  { name: "chart-auto",
    md: "# SED\n\n```chart\ntype: scatter\nlog: xy\nparam: a = 3e-23\nplot: model = a * x^0.9\nfit: powerlaw\nx, flux, flux_err\n1e11, 2.1e-12, 4e-13\n1e12, 8.5e-12, 1.2e-12\n1e13, 3.2e-11, 5e-12\n```\n" },
  { name: "diagram-tikz",
    md: "# Geometry\n\n```tikz\n% nebula-diagram: {\"v\":1,\"objs\":[]}\n\\begin{tikzpicture}[>=stealth, line cap=round]\n\\draw[->, thick] (0,0) -- (4,0);\n\\draw[->, thick] (0,0) -- (0,3);\n\\fill[blue] (2,1.5) circle (1.6pt);\n\\node[above right, blue] at (2,1.5) {$P_1$};\n\\draw[red, dashed] (0,0) -- (2,1.5);\n\\draw (0.7,0) arc[start angle=0, end angle=36.87, radius=0.7];\n\\node at (0.93,0.33) {$\\theta$};\n\\end{tikzpicture}\n```\n" },
  { name: "mnras-paper",
    md: "---\ntitle: Infall Kinematics\nauthor: Y. J.\ntemplate: mnras\n---\n# Introduction\n\nInfall [@ulrich1976] with $v_{\\rm LSR} = -17.7$ km/s.\n\n$$\\frac{dn}{dt} = -n_c k_{01}$$\n" },
  { name: "chart-fit-linear",
    md: "# Fit\n\n```chart\ntype: scatter\nfit: linear\nx, y\n0, 1.1\n1, 2.9\n2, 5.2\n3, 6.8\n```\n" },
  // The shipped feature-tour note must compile end-to-end (guards every
  // feature it demonstrates: math, chart+fit, tikz diagram, table, cites).
  { name: "feature-tour",
    md: readFileSync(new URL("../../demo-vault/功能導覽.md", import.meta.url), "utf8"),
    opts: { defaultTemplate: "apj" } },
];

let pass = 0, fail = 0;
const base = `${tmpdir()}/np-e2e`;
rmSync(base, { recursive: true, force: true });

function compile(dir: string, stem: string): string | null {
  try {
    execFileSync(TECTONIC!, [`${stem}.tex`], { cwd: dir, stdio: "pipe" });
    return existsSync(`${dir}/${stem}.pdf`) ? null : "no PDF produced";
  } catch (e: any) {
    const log = (e.stderr?.toString() || e.message || "").split("\n").filter((l: string) => /error:/i.test(l)).slice(0, 3).join(" | ");
    return log || "compile failed";
  }
}

for (const c of CASES) {
  const dir = `${base}/${c.name}`;
  mkdirSync(dir, { recursive: true });
  const r = convert(c.md, { bibBackend: "bibtex", ...(c.opts ?? {}) });
  writeFileSync(`${dir}/${c.name}.tex`, r.tex);
  writeFileSync(`${dir}/references.bib`, BIB);
  const err = compile(dir, c.name);
  if (err) { fail++; console.log(`✗ ${c.name}: ${err}`); }
  else { pass++; console.log(`✓ ${c.name}`); }
}

// Project (multi-md → one paper).
{
  const dir = `${base}/project`;
  mkdirSync(`${dir}/chapters`, { recursive: true });
  const r = convertProject([
    { name: "01-intro.md", md: "# Introduction\n\nDisks [@balbus1991]. $E=mc^2$.\n" },
    { name: "02-method.md", md: "# Method\n\nHLLD with $\\rho(r)$. See [@ulrich1976].\n" },
  ], { template: "apj" });
  for (const ch of r.chapters) writeFileSync(`${dir}/chapters/${ch.name}`, ch.body);
  writeFileSync(`${dir}/paper.tex`, r.master);
  writeFileSync(`${dir}/references.bib`, BIB);
  const err = compile(dir, "paper");
  if (err) { fail++; console.log(`✗ project: ${err}`); }
  else { pass++; console.log(`✓ project`); }
}

console.log(`\n${pass} passed, ${fail} failed (of ${pass + fail})`);
rmSync(base, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
