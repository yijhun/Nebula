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
import { writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
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
