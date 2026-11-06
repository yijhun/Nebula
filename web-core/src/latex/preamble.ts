/**
 * preamble.ts — assemble the LaTeX preamble (\usepackage lines) from the
 * feature set the emitter collected, plus an optional CJK block.
 *
 * Target engine: XeLaTeX (Tectonic). The CJK block uses `ctex`, which on
 * XeLaTeX maps to xeCJK + a CJK font; at compile time the bundled CJK font
 * (Source Han / Noto CJK, see fonts/) must be discoverable. M1 emits the
 * package directives; font discovery is a Phase 3 concern.
 */
import type { Feature } from "./emitter.js";

/** Map common scientific/Greek/sub-superscript Unicode → LaTeX, so pasted text
 * (×, −, Å, M⊙, αβγ, 10⁸…) compiles under XeLaTeX instead of "missing character". */
const UNICODE_MAP: Array<[string, string]> = [
  ["×", "\\times"], ["−", "-"], ["≈", "\\approx"], ["≃", "\\simeq"], ["≤", "\\le"],
  ["≥", "\\ge"], ["≠", "\\neq"], ["∼", "\\sim"], ["∝", "\\propto"], ["·", "\\cdot"],
  ["→", "\\to"], ["←", "\\leftarrow"], ["↔", "\\leftrightarrow"], ["⇒", "\\Rightarrow"],
  ["±", "\\pm"], ["∓", "\\mp"], ["∞", "\\infty"], ["∇", "\\nabla"], ["∂", "\\partial"],
  ["∫", "\\int"], ["∑", "\\sum"], ["∏", "\\prod"], ["√", "\\surd"], ["⊙", "\\odot"],
  ["′", "'"], ["″", "''"], ["°", "^\\circ"], ["≡", "\\equiv"],
  ["α", "\\alpha"], ["β", "\\beta"], ["γ", "\\gamma"], ["δ", "\\delta"], ["ε", "\\epsilon"],
  ["ζ", "\\zeta"], ["η", "\\eta"], ["θ", "\\theta"], ["κ", "\\kappa"], ["λ", "\\lambda"],
  ["μ", "\\mu"], ["ν", "\\nu"], ["ξ", "\\xi"], ["π", "\\pi"], ["ρ", "\\rho"],
  ["σ", "\\sigma"], ["τ", "\\tau"], ["φ", "\\phi"], ["χ", "\\chi"], ["ψ", "\\psi"], ["ω", "\\omega"],
  ["Γ", "\\Gamma"], ["Δ", "\\Delta"], ["Θ", "\\Theta"], ["Λ", "\\Lambda"], ["Π", "\\Pi"],
  ["Σ", "\\Sigma"], ["Φ", "\\Phi"], ["Ψ", "\\Psi"], ["Ω", "\\Omega"],
  ["⁰", "^0"], ["¹", "^1"], ["²", "^2"], ["³", "^3"], ["⁴", "^4"], ["⁵", "^5"],
  ["⁶", "^6"], ["⁷", "^7"], ["⁸", "^8"], ["⁹", "^9"], ["⁻", "^-"], ["⁺", "^+"],
  ["₀", "_0"], ["₁", "_1"], ["₂", "_2"], ["₃", "_3"], ["₄", "_4"], ["₅", "_5"],
  ["₆", "_6"], ["₇", "_7"], ["₈", "_8"], ["₉", "_9"],
];

export interface PreambleOptions {
  cjk: boolean;
  /** biblatex style, default "numeric". */
  bibStyle?: string;
  /** bibliography resource filename for \addbibresource. */
  bibResource?: string;
  /** biblatex backend, default "biber". */
  bibBackend?: "biber" | "bibtex";
  /** Source text — only Unicode chars present here get a \newunicodechar line
   * (keeps the preamble short). Omit to emit the whole map. */
  unicodeText?: string;
  /** "natbib" (AASTeX/ApJ) suppresses biblatex + hyperref, which the class
   * already provides / conflicts with. Default "biblatex". */
  bibMode?: "biblatex" | "natbib";
  /** natbib mode in a plain class (article): load natbib ourselves, ApJ
   * punctuation, and keep hyperref (the .bst links DOIs with \\href). */
  loadNatbib?: boolean;
}

export function buildPreamble(
  features: ReadonlySet<Feature>,
  opts: PreambleOptions,
): string {
  const lines: string[] = [];

  // Math is cheap and frequently implied; load when used.
  if (features.has("math")) {
    lines.push("\\usepackage{amsmath}");
    lines.push("\\usepackage{amssymb}");
  }
  if (features.has("graphicx")) {
    lines.push("\\usepackage{graphicx}");
  }
  if (features.has("ulem")) {
    lines.push("\\usepackage[normalem]{ulem}");
  }
  if (features.has("tikz")) {
    lines.push("\\usepackage{tikz}");
  }
  if (features.has("pgfplots")) {
    lines.push("\\usepackage{pgfplots}");
    lines.push("\\pgfplotsset{compat=1.18}");
  }

  if (opts.cjk) {
    lines.push("% --- CJK (XeLaTeX) ---");
    lines.push("\\usepackage{ctex}");
  }

  // Make pasted scientific/Greek Unicode compile (XeLaTeX) instead of failing.
  // Only emit mappings for characters that actually appear (keeps it short).
  const used = opts.unicodeText === undefined
    ? UNICODE_MAP
    : UNICODE_MAP.filter(([c]) => opts.unicodeText!.includes(c));
  if (used.length) {
    lines.push("\\usepackage{newunicodechar}");
    lines.push(
      used.map(([c, tex]) => `\\newunicodechar{${c}}{\\ensuremath{${tex}}}`).join(" "),
    );
  }

  if (features.has("biblatex")) {
    const style = opts.bibStyle ?? "numeric";
    const backend = opts.bibBackend ?? "biber";
    lines.push(`\\usepackage[backend=${backend},style=${style}]{biblatex}`);
    lines.push(`\\addbibresource{${opts.bibResource ?? "references.bib"}}`);
  }

  if (opts.loadNatbib && features.has("natbib")) {
    lines.push("\\usepackage{natbib}");
    // ApJ punctuation: "(Sandell et al. 2020)", no comma before the year.
    lines.push("\\setcitestyle{aysep={}}");
    // The reference list as ApJ sets it: entries packed with no gap between
    // them (natbib's default \\bibsep left a blank half-line after each).
    lines.push("\\setlength{\\bibsep}{0pt}");
    // aasjournal.bst only \\providecommand's these, so ours win: arXiv / ASCL
    // entries are named compactly ("arXiv:…") instead of spelling out the URL.
    // (\\dodoi stays: ApJ does print "doi: …", and the .bst writes the comma
    // before it, so blanking it left "ApJ, 904, 139," on every entry.)
    lines.push("\\newcommand{\\doarXiv}[1]{\\href{https://arxiv.org/abs/#1}{arXiv:#1}}");
    lines.push("\\newcommand{\\doeprint}[1]{\\href{https://ascl.net/#1}{ascl:#1}}");
  }

  // hyperref should be loaded late (after most packages). Skip when a journal
  // class supplies natbib — it already loads hyperref (and clashes if reloaded).
  const classHasHyperref = opts.bibMode === "natbib" && !opts.loadNatbib;
  const wantHyperref = features.has("hyperref") || (opts.loadNatbib && features.has("natbib"));
  if (wantHyperref && !classHasHyperref) {
    // Coloured link text like the journals, not hyperref's default boxes.
    lines.push("\\usepackage[colorlinks=true,allcolors=blue]{hyperref}");
  }

  return lines.join("\n");
}
