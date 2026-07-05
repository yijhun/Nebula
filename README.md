# Nebula

> Notes Bred in Astronomy — a note app built for astronomers.

A macOS hybrid note app for academic & astronomy research: draft in **Markdown**,
publish in **LaTeX**. Obsidian-compatible vault, live preview, in-place
Markdown ⇄ LaTeX, one-click PDF (AASTeX/ApJ by default), Zotero + arXiv/ADS
citations, local-AI assists, and lecture transcription — all local-first.

> Status: **v0.2**. macOS only.

## Features

- **Hybrid editing** — write plain Markdown, switch any note to a real LaTeX
  `.tex` in place; edits sync both ways. CodeMirror 6 editor with smart `$`
  pairing, instant red on unmatched brackets, same-document recall
  autocomplete, ~55 astronomy aliases (`\sun`→`\odot`, `\kms`, `\vlsr`, …).
- **Live preview** (Obsidian-style) — inline math, images (drag-resizable),
  wikilinks, checkboxes, tables; heading folding; inline title rename;
  pop-out live preview windows with dblclick-to-source jump.
- **Charts** (```` ```chart ````) — inline SVG plots while drafting: log axes,
  error bars, magnitude flip, `plot:` function overlays with `param:`
  sliders, least-squares `fit:` (linear/powerlaw/exp/log), external
  `data: obs.csv`. An interactive **chart studio** edits it all live, and
  charts auto-promote to publication pgfplots on export.
- **Diagram studio** — click-to-draw geometry figures (points, arrows,
  circles, angle arcs, `$math$` labels) that emit editable TikZ blocks;
  rendered inline in the Markdown preview, real TikZ in the paper.
- **Markdown → LaTeX** — in-process converter with MathJax, wide-math
  auto-fit, `\newunicodechar` only for characters actually used. Journal
  templates: **ApJ (AASTeX)** default, **MNRAS**, **A&A**, Academic, Article.
- **Projects** — a folder of `.md` chapters compiles to one paper (or each to
  its own `.tex`); plain quick notes still work with no build.
- **One-click PDF** — compiles with [Tectonic](https://tectonic-typesetting.github.io/);
  live compiled-PDF preview (Markdown too) with **SyncTeX** two-way jump;
  pre-compile lint gate with jump-to-issue.
- **Submission-ready** — pre-submission check (missing title/abstract,
  unresolved citations, missing figures), then a one-click bundle: flat
  `.tex` + cited-only `references.bib` + every figure, zipped for arXiv.
- **Citations** — Zotero (Better BibTeX, with Web-API fallback when the app
  is closed) search/insert + cited-only `.bib`; **arXiv / NASA ADS** search →
  import BibTeX + literature note; click a citation to open it in Zotero;
  a literature library panel with read/unread tracking.
- **Knowledge base** — backlinks, graph view, database/board views, semantic
  search ("ask your notes") over a local index; vault-wide search & replace
  (regex, per-match preview, auto history snapshot).
- **PDF reader** — open papers, highlight, turn annotations into a literature note.
- **Lecture transcription** — record or import audio → local
  [whisper.cpp](https://github.com/ggerganov/whisper.cpp) transcript + chunked
  local-AI (Ollama) summary, with live progress.
- **Cowork with Claude** — send a selection/section/note with a task preset
  to claude.ai via your subscription (no API key).
- **Local-first** — your notes are plain files in a normal folder; AI is local
  (Ollama); no account required.

## Architecture

A thin native shell hosting a portable web core:

```
SwiftUI + WKWebView  ──  window.notepro.{getContent,setContent,toLatex,…}  (Swift → JS)
                     ──  webkit.messageHandlers.notepro {ready,dirty,outline,…}  (JS → Swift)

Swift owns:  vault file I/O, PDF export (Process → tectonic), menus/toolbar,
             Zotero/ADS/arXiv networking, whisper.cpp transcription.
Web owns:    editing + Markdown↔LaTeX conversion (no platform assumptions).
```

- `apple/Notepro/` — the macOS app (SwiftUI). (Folder name preserved from the
  project's original `Notepro` codename; the built app is `Nebula.app`.)
- `web-core/` — portable TypeScript core (CodeMirror 6 editor + unified/remark
  Markdown→LaTeX), bundled to one `dist/index.html` via Vite.
- `crates/pdf-compiler/` — experimental Rust compile helper (spike).
- `demo-vault/` — sample notes to try the explorer.

## Requirements

- macOS 14+ with Xcode toolchain
- [Node.js](https://nodejs.org/) 18+ and npm
- [`xcodegen`](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`)
- [`tectonic`](https://tectonic-typesetting.github.io/) for PDF export (`brew install tectonic`)
- Optional: [Ollama](https://ollama.com/) (local AI), Zotero + Better BibTeX
  (citations), `ffmpeg` + a whisper.cpp model (transcription)

## Build & run

```bash
npm install            # installs the web-core workspace deps
apple/build-app.sh     # vite build → xcodegen → xcodebuild → ad-hoc sign
open Nebula.app
```

To work on the web core alone:

```bash
cd web-core
npm test               # vitest unit tests
npm run typecheck      # tsc --noEmit
npm run e2e            # convert→tectonic compile regression
npm run md2tex -- file.md   # Markdown → LaTeX on the CLI
```

## License

[Apache License 2.0](LICENSE) © 2026 yijhun.
