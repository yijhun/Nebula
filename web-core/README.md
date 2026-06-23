# @notepro/web-core

Portable TS web core. **M1 scope:** Obsidian-flavored Markdown → LaTeX converter
+ CLI. No Apple/Swift assumptions — runs on any OS with Node.

## Layout

```
src/latex/
  types.ts      custom mdast nodes (wikiLink/embed/citation/callout) + public types
  parser.ts     remark (gfm+math+frontmatter) + Obsidian transformer → mdast
  emitter.ts    mdast → LaTeX body (the mapping; see MAPPING.md)
  preamble.ts   feature-gated \usepackage assembly (math/graphicx/ulem/biblatex/ctex)
  templates.ts  {{KEY}} placeholder fill + built-in fallback
  bib.ts        cited-only .bib (filter a database OR synthesize from references)
  index.ts      convert() — ties the pipeline together
  cli.ts        md2tex command-line driver
  MAPPING.md    Markdown→LaTeX mapping table (source of truth)
```

## Use

```bash
npm install                 # from repo root (npm workspaces)

# Library
import { convert } from "@notepro/web-core";
const { tex, bib, assets, citationKeys } = convert(markdown, { template: "academic" });

# CLI (md → .tex, + references.bib next to output)
npm run -w @notepro/web-core md2tex -- sample.md -o out.tex --bib refs.bib
#   options: -o/--out, -t/--template, --templates-dir, --bib, --title, --author, --date, --cjk
```

## Test / typecheck

```bash
npm run -w @notepro/web-core test        # vitest (30 cases)
npm run -w @notepro/web-core typecheck    # tsc --noEmit
```

## PDF (desktop end-to-end) — ✅ verified with Tectonic

`verify.md` (academic template + Chinese + a display formula + two citations)
compiles to a correct PDF via Tectonic (XeLaTeX). ctex picks up a system CJK
font automatically.

```bash
brew install tectonic
npm run -w @notepro/web-core md2tex -- verify.md -o verify.tex \
  --bib verify-refs.bib --bib-backend bibtex
tectonic verify.tex          # → verify.pdf
```

### `--bib-backend` (biber vs bibtex)

The converter defaults to **biber** (the plan's choice; best output, full
Unicode). But Tectonic shells out to the *system* `biber`, and a very new biber
(e.g. TeX Live 2026's 2.21) can be incompatible with the biblatex inside
Tectonic's bundle ("control file version" mismatch). For local Tectonic builds,
pass `--bib-backend bibtex` (or `bibBackend: "bibtex"`): bibtex ships inside the
bundle, so there is no external-tool version skew. ASCII .bib entries compile
identically either way.

> Note: STHeiti (the auto-selected bold CJK font) triggers a harmless
> "ToUnicode CMap" warning — the PDF renders correctly; only text *copy-paste*
> of bold CJK headings is affected. Bundling a known CJK font (fonts/, Phase 3)
> resolves it.
