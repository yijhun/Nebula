/**
 * e2e-compile.mts — end-to-end regression: convert a corpus of realistic notes
 * (Markdown → LaTeX) and actually compile each with Tectonic, asserting a PDF
 * is produced. Catches "unit tests pass but the real pipeline won't compile".
 *
 * Run: npm run -w @notepro/web-core e2e   (needs the `tectonic` binary)
 */
import { convert } from "../src/latex/index.ts";
import { convertProject } from "../src/latex/project.ts";
import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, mkdirSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";

const TECTONIC = ["/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic"]
  .find((p) => existsSync(p));
if (!TECTONIC) { console.error("tectonic not found — skipping e2e"); process.exit(0); }

const OFFLINE = "http://127.0.0.1:1";
// E2E_ONLINE=1 lets Tectonic download what it lacks (CI does this when its
// Tectonic cache is cold). Default stays cache-only, see compile().
const ONLINE = process.env.E2E_ONLINE === "1";

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

// Per-case limit. On CI the `cjk` case once stalled until the job was
// cancelled, and a stalled Tectonic can ignore SIGKILL for minutes (blocked in
// a system call), so this never waits on the process past the limit: it
// samples where Tectonic is stuck (macOS `sample`), kills it, fails the case
// with that and Tectonic's last output, and moves on to the next case.
const CASE_TIMEOUT_S = Number(process.env.E2E_CASE_TIMEOUT ?? 180);

function tail(text: string, n: number): string {
  return text.split("\n").map((l) => l.trim()).filter(Boolean).slice(-n).join(" | ");
}

/** The heaviest stack of a stuck process, innermost frames last, or "". */
function stuckAt(pid: number): string {
  const r = spawnSync("/usr/bin/sample", [String(pid), "2"], { encoding: "utf8", timeout: 30_000 });
  const graph = (r.stdout ?? "").split("Call graph:")[1]?.split("Total number in stack")[0] ?? "";
  // Follow the first (heaviest) branch down the tree.
  const frames: string[] = [];
  let depth = -1;
  for (const line of graph.split("\n")) {
    const m = line.match(/^(\s*[+!:|\s]*)\d+\s+(.+?)\s+\(in ([^)]+)\)/);
    if (!m) continue;
    const d = m[1].length;
    if (d <= depth) break;
    depth = d;
    frames.push(`${m[2]} (${m[3]})`);
  }
  return frames.slice(-8).join(" > ");
}

function compile(dir: string, stem: string): Promise<string | null> {
  // Cache-only, with HTTP pointed at a closed port. Tectonic contacts its
  // bundle server on every run, and when that host is unreachable each case
  // pays the full connect timeout (~30s, or minutes with pgfplots) before
  // typesetting starts. The suite's packages are all cached. See the same
  // treatment in PDFExporter.runTectonicOnce.
  const child = spawn(TECTONIC!, ONLINE ? [`${stem}.tex`] : ["--only-cached", `${stem}.tex`], {
    cwd: dir, stdio: ["ignore", "pipe", "pipe"],
    env: ONLINE ? process.env
      : { ...process.env, http_proxy: OFFLINE, https_proxy: OFFLINE, ALL_PROXY: OFFLINE, NO_PROXY: "" },
  });
  let out = "", err = "";
  child.stdout.on("data", (d) => { out += d; });
  child.stderr.on("data", (d) => { err += d; });
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      const where = child.pid ? stuckAt(child.pid) : "";
      child.kill("SIGKILL");
      resolve(`timed out after ${CASE_TIMEOUT_S}s` +
        `; stuck in: ${where || "(no sample)"}` +
        `; last stderr: ${tail(err, 6) || "(none)"}; last stdout: ${tail(out, 4) || "(none)"}`);
    }, CASE_TIMEOUT_S * 1000);
    child.on("error", (e) => { clearTimeout(timer); resolve(`could not run tectonic: ${e.message}`); });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) { resolve(existsSync(`${dir}/${stem}.pdf`) ? null : "no PDF produced"); return; }
      const errors = err.split("\n").filter((l) => /error:/i.test(l)).slice(0, 3).join(" | ");
      resolve(errors || `compile failed (exit ${code})`);
    });
  });
}

for (const c of CASES) {
  const dir = `${base}/${c.name}`;
  mkdirSync(dir, { recursive: true });
  const r = convert(c.md, { bibBackend: "bibtex", ...(c.opts ?? {}) });
  writeFileSync(`${dir}/${c.name}.tex`, r.tex);
  writeFileSync(`${dir}/references.bib`, BIB);
  const t0 = Date.now();
  const err = await compile(dir, c.name);
  const secs = `(${((Date.now() - t0) / 1000).toFixed(1)}s)`;
  if (err) { fail++; console.log(`✗ ${c.name} ${secs}: ${err}`); }
  else { pass++; console.log(`✓ ${c.name} ${secs}`); }
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
  const t0 = Date.now();
  const err = await compile(dir, "paper");
  const secs = `(${((Date.now() - t0) / 1000).toFixed(1)}s)`;
  if (err) { fail++; console.log(`✗ project ${secs}: ${err}`); }
  else { pass++; console.log(`✓ project ${secs}`); }
}

console.log(`\n${pass} passed, ${fail} failed (of ${pass + fail})`);
rmSync(base, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
