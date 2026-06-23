/**
 * builtin-templates.ts — templates embedded in the web core (no filesystem),
 * so both the in-webview converter and "new from template" work in the app.
 *
 * Two kinds:
 *  - CONVERTER_TEMPLATES: placeholder ({{…}}) wrappers used by convert() for
 *    Markdown→LaTeX export. The converter injects a feature-gated preamble, so
 *    these are kept minimal (article/academic) to avoid clashing with a
 *    journal class's own packages.
 *  - NEW_TEX_SKELETONS: complete, standalone .tex documents used by
 *    "New LaTeX from template" — you edit them as LaTeX and compile directly
 *    (no Markdown step, no preamble injection), so journal classes like AASTeX
 *    (ApJ) work as-is.
 */

const ARTICLE = `% Notepro template: article
\\documentclass[11pt]{article}
{{PREAMBLE}}
\\title{{{TITLE}}}
\\author{{{AUTHOR}}}
\\date{{{DATE}}}
\\begin{document}
\\maketitle
{{BODY}}
{{BIB}}
\\end{document}
`;

const ACADEMIC = `% Notepro template: academic
\\documentclass[11pt,a4paper]{article}
\\usepackage[margin=2.5cm]{geometry}
\\usepackage{setspace}
\\onehalfspacing
{{PREAMBLE}}
\\title{{{TITLE}}}
\\author{{{AUTHOR}}}
\\date{{{DATE}}}
\\begin{document}
\\maketitle
{{BODY}}
{{BIB}}
\\end{document}
`;

// AASTeX (ApJ). The class provides hyperref/natbib/amsmath itself, and title/
// author/abstract live INSIDE the document. The converter feeds natbib citations
// (\citep) + \bibliography for this template (biblatex is incompatible here).
const APJ = `% Notepro template: apj (AASTeX / ApJ)
\\documentclass{aastex631}
{{PREAMBLE}}
\\begin{document}
\\title{{{TITLE}}}
\\author{{{AUTHOR}}}
{{BODY}}
{{BIB}}
\\end{document}
`;

/** Placeholder-based templates for Markdown→LaTeX conversion. */
export const CONVERTER_TEMPLATES: Record<string, string> = {
  article: ARTICLE,
  academic: ACADEMIC,
  apj: APJ,
};

// --- standalone, ready-to-edit skeletons for "New LaTeX from template" -------

const SKELETON_ARTICLE = `\\documentclass[11pt]{article}
\\usepackage{amsmath,amssymb}
\\usepackage{graphicx}
\\usepackage{hyperref}
\\usepackage{ctex} % Chinese support (XeLaTeX/Tectonic)

\\title{標題 Title}
\\author{作者 Author}
\\date{\\today}

\\begin{document}
\\maketitle

\\section{引言 Introduction}
在這裡開始撰寫，支援數學如 $E = mc^2$。

\\end{document}
`;

const SKELETON_ACADEMIC = `\\documentclass[11pt,a4paper]{article}
\\usepackage[margin=2.5cm]{geometry}
\\usepackage{setspace}\\onehalfspacing
\\usepackage{amsmath,amssymb}
\\usepackage{graphicx}
\\usepackage{hyperref}
\\usepackage[backend=bibtex,style=numeric]{biblatex}
\\usepackage{ctex}
% \\addbibresource{references.bib}

\\title{論文標題}
\\author{作者}
\\date{\\today}

\\begin{document}
\\maketitle
\\begin{abstract}
摘要。
\\end{abstract}

\\section{引言}
內文，引用範例 \\autocite{key}。

% \\printbibliography
\\end{document}
`;

const SKELETON_APJ = `% Astrophysical Journal (ApJ) — AASTeX.
% Requires the AASTeX class from the TeX bundle. If aastex631 is unavailable,
% try \\documentclass{aastex7} or fall back to {article}.
\\documentclass{aastex631}

\\begin{document}

\\title{Title of the Paper}

\\author{First Author}
\\affiliation{Institution Name}

\\begin{abstract}
Abstract text goes here.
\\end{abstract}

\\keywords{galaxies: formation --- methods: numerical}

\\section{Introduction} \\label{sec:intro}
Your introduction, with math such as $E = mc^2$ and references
\\citep{key2024}.

% \\bibliography{references}

\\end{document}
`;

const SKELETON_BEAMER = `\\documentclass{beamer}
\\usetheme{default}
\\usepackage{ctex}

\\title{簡報標題 Presentation}
\\author{作者}
\\date{\\today}

\\begin{document}
\\frame{\\titlepage}

\\begin{frame}{第一張 Slide One}
  \\begin{itemize}
    \\item 重點一
    \\item 公式 $E = mc^2$
  \\end{itemize}
\\end{frame}

\\end{document}
`;

export interface TemplateInfo {
  id: string;
  label: string;
  /** Standalone .tex content for "New from template". */
  skeleton: string;
}

/** Templates offered by "New LaTeX from template". */
export const NEW_TEX_SKELETONS: TemplateInfo[] = [
  { id: "article", label: "Article", skeleton: SKELETON_ARTICLE },
  { id: "academic", label: "Academic (A4)", skeleton: SKELETON_ACADEMIC },
  { id: "apj", label: "ApJ (AASTeX)", skeleton: SKELETON_APJ },
  { id: "beamer", label: "Beamer (Slides)", skeleton: SKELETON_BEAMER },
];

export function skeletonFor(id: string): string {
  return (NEW_TEX_SKELETONS.find((t) => t.id === id) ?? NEW_TEX_SKELETONS[0]!).skeleton;
}
