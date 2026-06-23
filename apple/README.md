# Notepro — macOS shell (Spike B)

A thin SwiftUI + WKWebView app that hosts the portable web core (CodeMirror
editor + in-process Markdown→LaTeX) and adds native file I/O + PDF export.

## What works

- **Graphical editor**: CodeMirror 6 (markdown highlighting, line numbers,
  undo/redo, wrapping) in a WKWebView.
- **Live preview**: split "編輯 | 並排 | 預覽" modes; Markdown→HTML rendered as
  you type, with **KaTeX** math and GFM task lists/tables.
- **Vault file explorer** (Obsidian-style): open a folder, browse its `.md`
  tree in a native sidebar (`NavigationSplitView`), click to open. New note
  (⇧⌘N), refresh.
- **Multi-window** (⌘N): multiple windows share the vault, each with its own
  open file + view mode.
- **Open / Save / Save As** real `.md` files; **Export PDF** (⌘E): the web core
  converts to LaTeX in-process, the native side compiles with **Tectonic** and
  opens the PDF. Handles CJK + math + (bibtex-backed) citations.

A small `demo-vault/` (CJK + math notes) sits at the repo root to try the
explorer: launch, click **資料夾**, choose `demo-vault`.

## Architecture (thin-shell discipline)

```
WKWebView  ── window.notepro.{getContent,setContent,toLatex}  (Swift → JS)
           ── webkit.messageHandlers.notepro {ready,dirty,...}  (JS → Swift)
Swift owns: file open/save, PDF export (Process → tectonic), menus/toolbar.
Web owns:   editing + Markdown→LaTeX (no Apple assumptions).
```

Files: `NoteproApp` (menus), `ContentView` (toolbar), `WebView`
(NSViewRepresentable + bridge), `EditorModel` (state + file/PDF ops),
`PDFExporter` (Tectonic).

## Build

```bash
apple/build-app.sh          # one shot: vite build + xcodegen + xcodebuild + sign
open Notepro.app            # at the repo root
```

Or manually:
```bash
cd web-core && npx vite build && cd ../apple
xcodegen generate
xcodebuild -project Notepro.xcodeproj -scheme Notepro -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO
codesign --force --deep -s - build/Build/Products/Release/Notepro.app
```

## Requirements / notes

- **Xcode** (full) + **xcodegen** (`brew install xcodegen`).
- **Tectonic** on PATH for PDF export (`brew install tectonic`); the exporter
  looks in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`.
- App is **unsandboxed** (so it can shell out to Tectonic and read/write files)
  and **ad-hoc signed** (so it launches on Apple Silicon). Not for distribution
  as-is — real signing/notarization + sandbox design come later.
- PDF export currently shells to the `tectonic` binary. Linking the offline
  `crates/pdf-compiler` XCFramework (no external binary) is a later increment.

## Not yet

Obsidian-style inline (WYSIWYG) preview, plugin runtime (Spike C), file
watching/auto-reload, wikilink/callout rendering in preview, iOS target, AI,
integrations.
