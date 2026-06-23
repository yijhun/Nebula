# Markdown → LaTeX mapping (Nebula M1)

This is the **source of truth** for how the converter emits LaTeX. (The plan
referenced `DESIGN.md §4.5`, which was not present in the repo; this table was
defined for M1 and should be reconciled with DESIGN.md when it lands.)

Target engine: **XeLaTeX** (what Tectonic runs). CJK relies on `ctex`.

## Block constructs

| Markdown | LaTeX | Notes |
|---|---|---|
| `# H1` … `###### H6` | `\section` → `\subparagraph` | depths 5–6 both map to `\subparagraph` |
| paragraph | text + blank line | |
| `> quote` | `\begin{quote}…\end{quote}` | |
| `> [!type] Title` callout | `\begin{quote}\textbf{[Type: Title]}\par …\end{quote}` | M1 renders callouts as a titled quote (no extra package). `+`/`-` fold marker parsed but not rendered |
| ` ```code``` ` | `\begin{verbatim}…\end{verbatim}` | language emitted as a comment; no syntax highlighting in M1 |
| `- a` / `1. a` | `itemize` / `enumerate` | ordered `start` ≠ 1 sets `enumi` |
| `- [ ]` / `- [x]` | `\item[$\square$]` / `\item[$\boxtimes$]` | requires amssymb |
| GFM table | `center` + `tabular` with `l/c/r` from alignment | `\hline` header rule |
| `---` (thematic break) | centered `\rule` | |
| `$$ … $$` (block) | `\[ … \]` | |

## Inline constructs

| Markdown | LaTeX | Notes |
|---|---|---|
| `*em*` | `\emph{…}` | |
| `**strong**` | `\textbf{…}` | |
| `~~del~~` | `\sout{…}` | requires `ulem` |
| `` `code` `` | `\texttt{…}` | content escaped |
| `[txt](url)` | `\href{url}{txt}` | requires `hyperref` |
| `![alt](url)` | `\includegraphics[width=\linewidth]{url}` | requires `graphicx`; recorded as image asset |
| `$x$` (inline) | `$x$` | |
| `[[Note]]` / `[[Note\|alias]]` | display text (`alias` or `Note`) | internal links have no PDF target; `#heading` stripped |
| `![[img.png]]` | centered `\includegraphics` | image extensions → resolved image asset |
| `![[Note]]` (non-image) | `\texttt{[[Note]]}` placeholder | recorded as unresolved embed asset |
| `[@key]` | `\autocite{key}` | requires `biblatex` |
| `[@key, p. 5]` | `\autocite[p. 5]{key}` | locator suffix |
| `[@a; @b]` | `\autocite{a,b}` | multiple keys |
| `[@a, p.1; @b]` | `\autocites[p.1]{a}[]{b}` | mixed suffixes |
| `[^1]` footnote | `\footnote{…}` | definition inlined at reference |

## Text escaping

Special characters in plain text are escaped: `\ & % $ # _ { } ~ ^`
(`~`→`\textasciitilde{}`, `^`→`\textasciicircum{}`, `\`→`\textbackslash{}`).
Content inside math, `verbatim`, and citation keys is **not** escaped.

## Frontmatter

| YAML key | Effect |
|---|---|
| `title` | `\title{…}` (escaped) |
| `author` | `\author{…}`; arrays joined with `\and` |
| `date` | `\date{…}`; default `\today`; explicit `""` omits |
| `template` | selects `templates/<id>.tex` (fallback `article`) |
| `bibliography` | bib database path (recorded; resolution is host's job) |

## Preamble (feature-gated)

Packages are loaded only when the corresponding construct appears:
`amsmath`/`amssymb` (math, task boxes), `graphicx` (images), `ulem` (strike),
`biblatex`+`\addbibresource` (citations), `hyperref` (links, loaded late),
`ctex` (when CJK detected or `--cjk`).
