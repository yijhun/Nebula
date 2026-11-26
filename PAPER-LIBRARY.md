# Paper library & reader — design

**Status:** design agreed, nothing built. Written 2026-11-26 from a design
discussion. Items marked **(verify)** are assumptions to test before relying on
them.

## 1. Goal

Nebula replaces Zotero as the paper library. It is a better reader than Zotero
because Claude can see what you are reading, and it makes it fast to take
figures from papers into your own Keynote slides.

The user scenarios that drive this design:

1. **Reading with Claude.** Ask about the selected text or a figure without
   copying it anywhere. Every answer points at the page it came from.
2. **Figures into Keynote.** Crop or pick a figure from a paper and paste it
   into Keynote as PDF. The user builds the slides; Nebula supplies the figures.
3. **Finding figures across the library**, e.g. "every PV diagram from ALMA
   since 2020", then compare them side by side.
4. **Opening a paper from a link.** A reference in a PDF, or a paper Claude
   suggests, opens a preview. The user checks it before it joins the library.
5. **Adding from the browser**, like the Zotero Connector.
6. **Many open tabs at once** without Nebula using much CPU or memory.

### Non-goals

- iPad, iPhone and multi-device sync. The user reads only on the Mac, so
  Time Machine backup is enough.
- Generated slide decks (beamer, pptx). Slides stay in Keynote and the user
  builds them.
- A Word or Google Docs citation plugin. The writing is LaTeX.

### Language

All content Nebula writes is in English: literature notes, figure cards,
Claude's highlights and comments, title suggestions, citation captions. UI
strings keep following the app language setting (`Localization.swift`).

## 2. Decisions

| Area | Decision |
|---|---|
| Library | Nebula owns the library; Zotero is retired after a verified migration |
| Platform | macOS only; Time Machine backup, optional iCloud Drive copy as backup (not sync) |
| Where | Inside Nebula, as a separate module, so it can be split out later |
| Library location | Outside the vault (§4.1) |
| Reader tabs | Nebula's own tab bar in one reader window, not native window tabs |
| Chat | A sidebar inside the reader window; one conversation per paper |
| Claude highlights | Only on request ("Suggest highlights"), never automatic |
| Figure gallery | Its own window |
| Figure metadata | Extracted for **all** papers up front; images cropped on demand |
| Object index | In the plan, last phase |
| Performance | A hard requirement with a budget and an automated check (§10) |

## 3. What exists today

| Piece | File | Notes |
|---|---|---|
| PDF reader | `apple/Notepro/PDFReader.swift` | Yellow highlight, save annotations into the PDF, highlights → literature note, rubber-band capture, Zotero citekey lookup |
| Figure capture | `PDFController.captureRegion` | Saves a 2x PNG and a cropped PDF to `Assets/`, inserts Markdown into the open note, **puts only the Markdown text on the clipboard** |
| Figure detection | `FigureExtractor.swift`, `FigurePickerView.swift` | zotero-figure plugin cache first, then `~/Zotero/pdffigures2.jar` |
| Vector PDF copy | `EditorModel.copyVectorPDF` | Puts PDF data on the pasteboard for Keynote; used only for TikZ figures today |
| MCP tools | `NebulaMCP.swift` | `zotero_search/get/bibtex/fulltext/add`, `ads_search`, `arxiv_search`. Runs as a **separate process** (`Nebula --mcp`) started by the CLI |
| Chat | `ChatPane.swift`, `AgentSession.swift` | WKWebView UI over Claude Code / Codex CLI; context = open note, selection, dropped files |
| Zotero access | `ZoteroService.swift`, `ZoteroWeb.swift` | Better BibTeX JSON-RPC, Web API fallback, connector import |
| Embeddings | `EmbeddingService.swift` | Local Ollama, `nomic-embed-text` |

## 4. Library

### 4.1 Storage

Plain files, one folder per paper, outside the vault (`~/Zotero/storage` is
1.7 GB today).
Notes link to papers by citekey and `nebula://` links.

```
Library/
  beutherFragmentationDiskFormation2018/   folder name = citekey
    paper.pdf
    meta.json            bibliographic data + identifiers
    annotations.json     highlights, notes, ink
    figures.json         figure regions: detected, or image annotations from Zotero (§7)
    notes/               Zotero child notes, converted to Markdown
    objects.json         astronomical objects mentioned (§9)
    chat/                reader chat sessions for this paper
  _files/                files that are not papers (files.json lists them)
  .import/               the last import's plan, collection mapping and result
  .index.sqlite          search index; a cache, rebuildable from the folders
```

Implemented in `apple/Notepro/Library/` (`PaperLibrary.swift`,
`LibraryImporter.swift`); the default root is `~/Nebula Library`.

The PDF is never modified. Annotations live in `annotations.json`.

### 4.2 `meta.json`

`bibliographic` keeps Zotero's data losslessly: its item type, every field,
and the creators with their roles. `.bib` and CSL output are mapped from it.
Plus:

- `ids`: `doi`, `bibcode`, `arxiv`
- `citekey` and `aliases` (keys of duplicates merged into this one)
- `status`: `unread` / `reading` / `read`
- `tags` (the user's own), `keywords` (journal keywords, case-normalised)
- `projects` (see 4.5)
- `added`, `lastOpened`, `lastPage`
- `version`: `preprint` / `published`, with the ADS-reported link between them

### 4.3 Citekeys

- Every existing key is kept unchanged. Notes and papers cite them.
- New keys use the same Better BibTeX style (`authorTitleYear`, `a`/`b` suffix
  on clashes), but with the title words normalised to title case. This avoids
  keys like `zhuSUBARCSECONDOBSERVATIONSNGC2013a`. Existing keys are not renamed.
- Merged duplicates keep the removed key in `aliases`. The `.bib` export emits
  an entry for every key that is actually cited, aliases included, so old notes
  still compile.

### 4.4 Identity, duplicates and versions

- A new paper is matched against the library by DOI, ADS bibcode and arXiv id
  before it is added. The same paper is never added twice.
- **Preprint → published.** ADS links arXiv preprints to their journal
  versions. Nebula offers to update the metadata to the journal version,
  keeping the citekey. The PDF stays the arXiv one unless the user downloads
  the journal PDF themselves. The check runs at migration, then periodically
  (e.g. weekly) and when a preprint is opened. ADS answers an
  `identifier:"arXiv:<id>"` query with the journal record. The spike found
  54 of the 59 arXiv-only items already published.
- **Missing PDFs.** If arXiv has the paper, Nebula offers to download it, and
  downloads only after the user confirms. A journal-only PDF opens the
  publisher page in the browser for the user to download; Nebula never logs in.

### 4.5 Organisation

| Zotero today | Nebula |
|---|---|
| Project collections (`ngc7538_project`, `G240_project`, `ALMA proposal`, `10stage_paper` and its children, …) | **Projects**, linked to the vault note project of the same name |
| Topic collections (`magnetic`, `infall`, `reviews`, `Textbook`) | Tags |
| `old_papers` (308 of 415 live items) | Dropped |
| `unread` tag | `status` field |
| Journal keyword tags (inconsistent case) | `keywords` field, normalised, searchable, not shown as tags |
| `Figure N` / `Table N` tags | Not tags. They are on image annotations, see 5.3 |
| Trash | Not migrated |

### 4.6 Adding papers

Zotero is retired after phase 2 (§11), so these add paths must exist from
phase 1:

- **Add by identifier:** paste a DOI, arXiv id, ADS bibcode, or a URL that
  contains one (an arXiv, ADS or journal page). Metadata comes from ADS, then
  doi.org / arXiv.
- **Drop a PDF:** identify it from its DOI or arXiv id in the text, else ask.
- **Search inside Nebula:** ADS and arXiv search, add from the results.
- **Claude:** `library_add`, after the user confirms.

Each path shows what will be added and checks for duplicates (§4.4) first.
Until the browser extension (§8.7) ships, adding from the browser means
copying the page URL and pasting it into Add by identifier.

### 4.7 What changes in Nebula

- `ZoteroService`, `ZoteroWeb` and the Better BibTeX JSON-RPC calls are
  replaced by a `LibraryService` over §4.1.
- The MCP tools `zotero_*` become `library_search/get/bibtex/fulltext/add`.
  `library_add` still shows the user what will be added and waits for
  confirmation.
- `.bib` generation reads `meta.json` directly (cited entries only, as now).
- The literature library panel reads `status` instead of Zotero.

## 5. Migration from Zotero

### 5.1 Inventory (2026-11-26, from a copy of `zotero.sqlite`)

| | Count |
|---|---|
| Live items (not in trash) | 415 (473 including trash) |
| Items with a `citationKey` | all |
| Citekeys with an `a`/`b` suffix | 53 |
| PDF attachments on live items | 326 (408 counting trash; `storage/` is 1.7 GB including trashed files) |
| Live items without a PDF | 89 |
| arXiv-only items (publication title contains "arXiv") | 65 |
| Duplicate groups by DOI / by title | 32 / 39 |
| Annotations | 139: 38 highlight, 1 note, 87 image, 13 ink |
| Notes (Better Notes) | 14 |
| Collections / tags | 16 / 176 |
| Libraries / groups | 1 / 0 |
| zotero-figure cache | 2 papers only (72 images) |

### 5.2 Importer

1. Copy `zotero.sqlite` (Zotero locks the live one) and read only the copy.
   The Zotero folder is never written to.
2. **Dry run → report.** For every item, list what will happen: its folder and
   citekey, duplicates found, missing PDF, annotations that could not be
   converted, preprints that ADS says are published. Nothing is written.
3. The user reviews the report: merges duplicates, approves PDF downloads and
   metadata updates.
4. Import: create `Library/<citekey>/`, copy each PDF, write `meta.json` and
   `annotations.json`, `figures.json`, and Zotero child notes as Markdown in
   the paper's `notes/` folder. Duplicates are imported as separate papers and
   merged afterwards (merging keeps the removed key as an alias). Trashed
   items the vault still cites can be restored (`--restore-cited`).
   Parentless PDFs go to `_files/`; ones named like an ADS bibcode are marked
   to be looked up and turned into papers.
5. A background job builds the search index (§10 rules apply).
   `figures.json` and `objects.json` are built for the whole library when
   phases 4 and 7 land, under the same rules.
6. Run Zotero and Nebula side by side for a while. Zotero stays the backup.
   Cut over when the criteria in 5.4 are met. Zotero sync can then be turned
   off, leaving the server copy as a last backup.

### 5.3 Annotation mapping

| Zotero | Count | Nebula |
|---|---|---|
| Image (area) | 87 | Not user annotations: a tool generated them (confirmed by the user). Imported into `figures.json` as detected figures with their `Figure N`/`Table N` label, source `zotero-figure`; not into `annotations.json` |
| Highlight | 38 | Highlight, author = user, colour and comment kept |
| Ink | 13 | Ink paths, drawn as before |
| Note | 1 | Text note on the page |

The 87 image annotations sit on only 8 papers (up to 24 on one), each tagged
`Figure N` or `Table N`; 5 have `zoterofigure` as author, 82 have none. The
user confirmed a tool generated them, so they are figure detections, not
reading marks. For those 8 papers they are used in place of a pdffigures2 run
when their regions look right.

Zotero stores annotation positions as JSON in `itemAnnotations.position`,
e.g. `{"pageIndex":4,"rects":[[x1,y1,x2,y2]]}`. These are PDF points with a
bottom-left origin and map onto PDFKit page space as-is: verified on all 87
image annotations against Zotero's cached renders. Ink uses `paths` instead
of `rects`. The type codes (1 highlight, 2 note, 3 image, 4 ink) were
confirmed from the data. Pages with an offset media box or rotation are still
untested.

### 5.4 Cut-over criteria

- Every live item imported; the report has no unresolved errors.
- All add paths in §4.6 work.
- Every citekey used in the vault resolves (keys and aliases).
- A full vault build produces the same `.bib` entries as before.
- Reader tier 1 (§6.1) is complete.

## 6. Reader

### 6.1 Tier 1 — Zotero parity (required before cut-over)

- Find in document (⌘F) with all matches marked
- Sidebar: page thumbnails, outline, annotation list (click to jump)
- Highlight colours, with a comment on any highlight
- Text notes and ink
- Remember the page, scroll position and zoom per paper
- **Tab bar** (§6.4)
- Zoom, single or two-page layout, fit width
- Split view of one paper (two places at once)
- Dark mode that darkens text and background but keeps images in their true
  colours. Simple inversion makes astronomical images unreadable. Shown on a
  static render: invert the page, then composite the `figures.json` regions
  back from the original. Doing it in a live, scrolling `PDFView` is untested. Figures that detection missed get a per-figure "keep
  colours" toggle.

### 6.2 Tier 2 — better than Zotero

- **Citation hover card.** Hovering "(Smith et al. 2020)" or a reference-list
  entry shows title, authors, abstract and whether the paper is in the library.
  It is resolved through the ADS reference list of the current paper, not by
  parsing text. ADS has substantial reference lists for modern papers;
  matching one in-text citation to one entry, and old or scanned papers, are
  untested.
- **Figure reference preview.** Hovering "Fig. 3", "Table 2" or an equation
  number shows a thumbnail from `figures.json`.
- **Pin a figure.** Turn a figure into a small floating window to keep it in
  view while reading the text about it.

### 6.3 Tier 3 — astronomical object index

See §9.

### 6.4 Tabs

- One reader window, Nebula's own tab bar, **one** chat sidebar per window.
  Switching tabs swaps the sidebar's conversation; it does not create another
  web view.
- Dragging a tab out makes a second reader window (for side-by-side), with its
  own single chat sidebar.
- A suspended tab looks dimmed; a dot shows when Claude is answering in it.
- Shortcuts (check for clashes first): ⌘T open from library, ⌘W close,
  ⌘⇧T reopen closed, ⌃Tab next tab.
- On relaunch every tab is restored suspended and loads only when selected.

## 7. Figures

### 7.1 Extraction

- Run pdffigures2 over **every** paper once, at migration, then for each new
  paper. It has a batch mode over a directory, `-t` for the thread count, and
  `-d` for JSON-only output with no images. Measured: about 0.25 s per paper
  with `-t 1 -Xmx512m` (0.7 GB peak), so about 2 minutes for the library.
  About 1 in 6 figures is missed, mostly in scanned and some modern papers.
  Missed captions are kept (`-c`) and shown as "not located" with a one-click
  crop (see `SPIKE-PAPER-LIBRARY.md`).
- Import the zotero-figure cache where it exists (2 papers), and the 87
  tool-generated image annotations on 8 papers (§5.3).
- Store only `figures.json` (a few KB per paper). Do **not** store images up
  front: the plugin cache uses about 3.7 MB per paper, which would be about
  1.5 GB for the library.
- Images are cropped from the PDF on demand. Thumbnails go in a disposable
  cache. Image files are written only when the user uses a figure: a Keynote
  copy, or an insert into a note (`Assets/`, as now).
- Fix-ups in the reader: adjust a crop, mark a missed figure, delete a wrong
  one. Splitting multi-panel figures into (a)(b)(c) comes later.
- arXiv source files can supply the original figure files where they exist,
  which beats any crop. 15 of 15 sampled papers have a source tarball; whether
  it holds usable figure files is still open. Later phase.

### 7.2 `figures.json`

Per figure: label (`Figure 3`, `Table 1`), caption (cleaned), page, region in
PDF points, source (`pdffigures2` / `zotero-figure` / `user` / `arxiv-source`),
type tags, instruments and bands parsed from the caption (e.g. `ALMA`, `SMA`,
`JWST/NIRCam`, `1.3 mm`), a `capturedByUser` flag (captured in Nebula), and
an optional Claude description.

**Type tags:** continuum image, moment map, channel map, PV diagram, spectrum,
SED, light curve, CMD/HR diagram, radial profile, corner plot, model
schematic, table. They come from caption keywords, including inheriting
"Same as Fig. N" captions; in the spike that gave a fine type for about half
the figures. The local vision model (`gemma4`) was unreliable for fine types,
so it gives every figure only a coarse class (sky map / data plot / spectrum /
schematic / other) at 0.3–0.5 s per figure. How to tag the other half is still
open.

Claude descriptions are written only on demand: when the user asks about a
figure, captures it, or adds it to a compare board. A description is stored
once written. Describing every figure (about 3000) would use too much of the
subscription.

### 7.3 Figures into Keynote

- **Gap to fix first:** after a capture, put the cropped PDF on the pasteboard
  (PDF data and a file URL), reusing the approach in
  `EditorModel.copyVectorPDF`, so ⌘V in Keynote pastes the figure. Do the same
  for figures chosen in the gallery or in `FigurePickerView`, and allow
  dragging them out as PDF.
- A separate "Copy citation" gives text such as "Beuther et al. 2018".
- Caveats: if the journal embedded the figure as a bitmap, the PDF still
  contains that bitmap, at its original resolution. The crop sets the crop box,
  so content outside it is still in the file. A clean crop is possible if file
  size matters.
- Later: "Send to Keynote", which adds a slide to the open presentation with
  the figure, a title and the citation, through AppleScript **(verify)**.

### 7.4 Gallery window

- Its own window, opened with a shortcut (e.g. ⇧⌘F, check for clashes). Only
  one instance; the shortcut brings it to the front.
- Opened from a reader tab, it starts filtered to that paper; clearing the
  filter searches the whole library.
- Search: caption text, semantic search over captions (`nomic-embed-text`),
  type tags. Filters: type, instrument, band, year, author, tag, project,
  captured by the user.
- Each figure: open in the reader at its page, copy PDF, drag into Keynote,
  ask Claude, add to compare board.
- **Compare board** (right side of the gallery): figures from different papers
  side by side, each with its citation. Claude can be asked to compare them,
  and sees all of them. A board can be saved as a note (English, citations
  and page links).

## 8. Claude in the reader

### 8.1 Architecture

`Nebula --mcp` is a separate process started by the CLI. It cannot see the
running app's reader windows. Add a local channel:

- The app runs a Unix-domain socket server, local only. It answers queries
  and runs commands against the reader.
- **Tools are bound to the conversation's paper, not to the focused tab.**
  Each reader chat session is started with its citekey, and its MCP server
  passes that citekey on every call. Claude answering in a background tab, or
  in a second reader window, still reads its own paper. If that tab is
  suspended, page text and figures are served from the files, and the
  selection is whatever was saved when the tab was suspended.
- The MCP process forwards reader tool calls over the socket.
- The same command path serves `nebula://` links (§8.6).
- The channel is event-driven. Nothing polls (§10).

### 8.2 Tools

| Tool | Purpose |
|---|---|
| `reader_context` | Open paper (citekey), page, selection text and position, focused figure |
| `reader_page_text` | Text of a page range, each paragraph tagged with its page |
| `reader_figure` | One figure's image and caption |
| `reader_capture` | Image of an arbitrary page region, for figures pdffigures2 missed |
| `reader_goto` | Jump to a page, figure or quoted passage |
| `reader_suggest_highlights` | Propose highlights; they show as pending until the user accepts |

- Claude reads page ranges, not whole papers, to save quota and keep answers
  grounded.
- Claude locates text by **quote**, not coordinates. The app finds the quote
  with PDFKit search to place highlights and jumps.
- An MCP tool can return the image itself (an `image` content block): verified
  in Claude Code 2.1.319 and Codex 0.155.1. Both read the axes and panels
  correctly.

### 8.3 Chat sidebar

- In the reader window, toggled with ⌥⌘I as in the main window, resizable.
- A context strip shows what Claude has: e.g.
  `Reading: beutherFragmentationDiskFormation2018 · p.7 · selection`.
- One conversation per paper, stored in `Library/<citekey>/chat/` and resumed
  with `--resume`.
- Right-click a selection or a figure → "Ask Claude" / "Ask about this
  figure".
- Cross-paper questions use the library tools; both papers' sources are linked.
- **Send to note.** Each answer can be sent to the note open in the main
  window, in English, keeping `[@citekey]` citations and page links.
- The main-window chat stays for writing; same account and model settings,
  separate conversations.

### 8.4 Grounded answers

- Claims about the paper must carry a link with page and quote:
  `nebula://paper/<citekey>?page=7&quote=...`.
- The chat shows it as a chip (`p.7`). Clicking it jumps there and flashes the
  passage.
- The app checks that the quote is on that page. If it is not, the chip turns
  red ("not verified").

### 8.5 Highlights and briefing

**Suggest highlights** runs only when the user asks. They pick:

- Scope: this page, this section, whole paper.
- Categories:

| Category | Marks |
|---|---|
| Result | Main conclusions |
| Numbers | Key quantities with units and errors (mass, distance, temperature, …) |
| Data & Method | Telescope, instrument, program, resolution, sensitivity; models, codes, fitting |
| Caveat | Limitations the authors state; assumptions that drive the result |
| Relevant to me | Passages related to the user's own work, judged from their vault notes |

- At most 8 per request.
- Shown with a dashed outline in the category colour, each with a one-line
  English reason. The user accepts (✓) or rejects (✗) each. Accepted ones go
  into `annotations.json` with author = Claude.
- Accepted highlights flow into the literature note under `## Key results`
  etc., and Numbers build a **Key numbers** table (quantity, value, page), so
  several papers' values can be compared later.

**Brief me** runs only on request. It gives a three-line summary, the 2–3 key
figures with links, and related papers in the library (semantic index).

### 8.6 Links and the preview card

- Register the `nebula://` URL scheme (none exists today):
  `nebula://paper/<citekey|bibcode|doi|arxiv>?page=&fig=&quote=`.
- If the paper is in the library, open it in the reader at that place.
- If not, show a **preview card**: title, authors, year, abstract, with
  "Open PDF to check", "Add to library", "Open in ADS".
- Claude's paper suggestions carry these links, so the user opens and checks
  before adding. The chat's Markdown renderer keeps these links, but nothing
  handles the click yet. Add a link handler in `web-core/src/chat/main.ts`
  that posts to Swift: `nebula://` goes to the reader, other URLs open in the
  browser.
- Citation hover cards in the reader (§6.2) use the same card.

### 8.7 Browser

- Phase 1: no extension. Papers come in through links and search.
- Later: a small Safari/Chrome extension or bookmarklet that finds a DOI,
  arXiv id or bibcode on the page and sends `nebula://paper/...`. Metadata
  comes from ADS, so no Zotero-style translators are needed.
- Alternative, not planned: implementing the Zotero Connector's local protocol
  so the official extension saves into Nebula. Zotero's docs name the
  endpoints, but the request and response schema is defined only by its
  source, and it would clash with Zotero on the same port while both are
  installed.

## 9. Astronomical object index

- Find candidate object names with rules (catalogue designations like
  NGC 7538, IRAS 16293-2422; coordinate names like G240.31+0.07; sub-sources
  like IRS 1, MM1). Keep a candidate only if SIMBAD resolves it.
- Group aliases under SIMBAD's main identifier.
- Built for all papers in the background, like figures. Stores names, pages
  and the SIMBAD identifier in `objects.json`. SIMBAD results are cached
  locally.
- In the reader, hovering a name shows SIMBAD position and type, plus the
  other library papers that mention it.
- The gallery can filter by object ("every figure of NGC 7538").
- Projects named after objects (`ngc7538_project`) link to their papers and
  notes.

## 10. Performance budget

The user keeps many tabs open. Nebula must stay light.

| Resource | Rule |
|---|---|
| Background tabs | Suspended after a while: the PDF view is released; page, scroll and zoom are kept. Restored on selection |
| Live PDF views | Capped, e.g. the 5 most recent; the number is set after measuring |
| Chat web view | Created on first open; one per reader window |
| Claude Code processes | Started on the first message, never on tab switch. At most 2 at once. Shut down after 10 minutes idle; resumed with `--resume` |
| Idle | Near 0% CPU. No polling anywhere. Commit `841c3ec` fixed a lookup loop that cost ~45% CPU while idle; the reader channel and lookups must be event-driven with backoff |
| Background jobs | One at a time, low QoS, with progress and pause. pdffigures2 with limited threads and JSON-only output |
| Gallery | Thumbnails only for visible cells; capped memory cache; disk cache |
| Hover cards | Debounced, results cached |

**Perf self-test**, alongside the existing save self-test in CI: open 30
papers in tabs, switch between them, then idle. Fail if idle CPU or memory
goes over set thresholds.

**Resources panel** (debug): live and suspended tabs, CLI processes, running
background jobs.

## 11. Phases

1. **Library and migration** (§4, §5): storage format, importer with dry-run
   report, duplicates, preprint check, missing-PDF fetching, add paths
   (§4.6), `LibraryService` replacing the Zotero integration, `library_*`
   MCP tools.
2. **Reader tier 1** (§6.1, §6.4) and the performance rules (§10). After this,
   Zotero can be retired (§5.4).
3. **Claude in the reader** (§8.1–8.5): socket channel, reader tools, chat
   sidebar, Suggest highlights, Brief me, Send to note, and the `nebula://`
   scheme for papers already in the library, which grounded answers (§8.4)
   need.
4. **Figures** (§7): extraction for all papers, gallery window, compare board.
5. **Reader tier 2 and the preview card** (§6.2, §8.6): citation hover card,
   figure reference preview, pinned figures, and `nebula://` links to papers
   not yet in the library.
6. **Browser extension** (§8.7).
7. **Object index** (§9).

The Keynote pasteboard fix (§7.3) is small, depends on nothing, and can ship
at any time.

## 12. To verify

The first round of checks ran on 2026-11-26; results and method are in
`SPIKE-PAPER-LIBRARY.md`. Settled there:

- coordinates for image regions and highlights, and the annotation type codes
- the ADS preprint → journal link
- pdffigures2 speed
- `gemma4` only for coarse classes
- MCP image results in both CLIs (small images)
- Claude `--resume` across processes
- link rendering in the chat
- the Connector protocol (stays not planned)

Still open:

- Ink and note annotations, and pages with an offset media box or rotation
  (§5.3)
- Figure detection recall measured against labelled ground truth, e.g. the
  87 zotero-figure regions (§7.1)
- Fine type tags for the half of figures whose caption names no type (§7.2)
- Matching an in-text citation to one ADS reference (§6.2)
- Duplicate detection again after preprints resolve to journal records
  (§4.4)
- How long Claude Code keeps a session resumable. The CLI holds it, so
  Nebula stores only the session id and its own transcript per paper (§8.3)
- MCP image results at full-page size: token cost and limits (§8.2)
- Dark mode inside a live `PDFView`, within the performance budget (§6.1)
- Reference coverage for old and scanned papers (§6.2)
- What arXiv source tarballs contain: usable figure files or not (§7.1).
  Needs a few downloads.
- Licence and speed of zotero-figure's layout model as a second figure
  detector (§7.1)
- Inserting a PDF as a vector image through Keynote AppleScript (§7.3). Needs
  a run against Keynote.
- Whether a suspended tab's `PDFView` really frees memory, measured in the app
  (§10)
- Codex's default model (`gpt-6.1-sol` in `~/.codex/config.toml`) is rejected
  for the user's ChatGPT account. Nebula's Codex chat needs a model the
  account accepts (§8).
