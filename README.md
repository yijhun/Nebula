# Nebula

> **N**ot**e** **Bu**i**l**t in **A**stronomy — a note app built for astronomers.

A macOS hybrid note app for academic & astronomy research: draft in **Markdown**,
publish in **LaTeX**. Obsidian-compatible vault, live preview, in-place
Markdown ⇄ LaTeX, one-click PDF (AASTeX/ApJ by default), Zotero + arXiv/ADS
citations, local-AI assists, and lecture transcription — all local-first.

> Status: **v0.1** (first public release). macOS only.

## Features

- **Hybrid editing** — write plain Markdown, switch any note to a real LaTeX
  `.tex` in place; edits sync both ways. CodeMirror 6 editor.
- **Live preview** (Obsidian-style) — inline math, images (drag-resizable),
  wikilinks, checkboxes, tables; heading folding; inline title rename.
- **Markdown → LaTeX** — in-process converter with MathJax, wide-math
  auto-fit, `\newunicodechar` only for characters actually used. Default
  template is **AASTeX / ApJ** (`\citep` + natbib); Academic / Article also
  built in.
- **Projects** — a folder of `.md` chapters compiles to one paper (or each to
  its own `.tex`); plain quick notes still work with no build.
- **One-click PDF** — compiles with [Tectonic](https://tectonic-typesetting.github.io/);
  pre-compile delimiter/brace lint gate with jump-to-issue.
- **Submission bundle** — flatten to a single `.tex`, gather the cited-only
  `references.bib` and every figure into a self-contained, zipped folder ready
  for arXiv / a journal.
- **Citations** — Zotero (Better BibTeX) search/insert + cited-only `.bib`;
  **arXiv / NASA ADS** search → import BibTeX + literature note, merged into the
  bib at compile so imported keys resolve without round-tripping through Zotero.
- **Knowledge base** — backlinks, graph view, database/board views, semantic
  search ("ask your notes") over a local index.
- **PDF reader** — open papers, highlight, turn annotations into a literature note.
- **Lecture transcription** — record or import audio → local
  [whisper.cpp](https://github.com/ggerganov/whisper.cpp) transcript + chunked
  local-AI (Ollama) summary, with live progress.
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
