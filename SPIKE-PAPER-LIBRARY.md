# Spike — paper library open questions (PAPER-LIBRARY.md §12)

**Date:** 2026-11-26. **Machine:** the user's Mac.

- Throwaway scripts lived in a scratch folder and are not part of the repo.
- Zotero data was read from a **copy** of `zotero.sqlite`; nothing in
  `~/Zotero` was written.
- External calls:
  - ADS queries with the user's token
  - a few Claude Code and Codex runs on the user's subscriptions
  - HEAD requests to arxiv.org (nothing downloaded)

✅ shown, ⚠️ partly shown (limit stated), ❓ not tested, ❌ answer is no.

## Summary

| # | Question | Result |
|---|---|---|
| 1 | Zotero annotation positions → PDFKit | ✅ for image regions and highlights: use as-is (PDF points, bottom-left). ❓ ink |
| 2 | Zotero annotation type codes | ✅ 1 highlight, 2 note, 3 image, 4 ink |
| 3 | pdffigures2 speed | ✅ ~0.25 s/paper, so the whole library in about 2 min (not 10) |
| 4 | pdffigures2 quality | ⚠️ Crops are accurate; recall is roughly 80–85% by a crude measure, much worse on scans |
| 5 | Figure type tags | ⚠️ Captions give a fine type for about half the figures; `gemma4` is usable only for coarse classes |
| 6 | ADS preprint → journal link | ✅ 54 of 59 "arXiv-only" items are already published |
| 7 | ADS references for hover cards | ⚠️ ADS has full-looking lists; matching one in-text citation to one entry is untested |
| 8 | arXiv source availability | ⚠️ 15/15 sampled serve gzip source (3 checked: tarballs). ❓ Figure files inside |
| 9 | MCP tool image results | ✅ Claude Code and Codex both see a small figure image |
| 10 | `--resume` after the CLI exits | ✅ Works from another process and folder. ❓ How long sessions are kept |
| 11 | `nebula://` links in the chat | ⚠️ The renderer keeps them; nothing handles the click yet |
| 12 | Keynote scripting | ⚠️ The dictionary has slides and images; inserting a PDF is untested |
| 13 | Zotero Connector protocol | ❌ Endpoints are named in Zotero's docs; no documented request/response schema |
| 14 | Memory with many tabs | ⚠️ Open documents are cheap and one restore was fast; freeing memory must be measured in the app |
| 15 | Dark mode keeping figure colours | ⚠️ Works on a static render; a live, scrolling `PDFView` is untested |

## Details

### 1–2. Zotero annotations

**Image regions (87, tool-made, on 8 PDFs)**
- Cropped with PDFKit from `position.rects[0]` taken **as-is** (PDF user
  space, bottom-left origin), and also flipped (top-left origin).
- Each crop was compared with Zotero's own render in
  `~/Zotero/cache/library/<key>.png`. As-is was closer for **87/87**, with a
  worst mean difference of 0.02 against 0.11–0.27 for flipped. Visual check:
  identical content.
- Zotero caches a PNG for every image annotation, which gives a reference
  render for free during migration.

**Highlights (38, the user's own, on 6 PDFs)**
- The text under each rect, read with `PDFPage.selection(for:)`, was
  compared with the text Zotero stored.
- 37/38 recovered at least 80% of the words (mean 0.96). The one miss is a
  coordinate string (`2.″0033 × 2.″0001`) where only symbols differ.

**Not tested**
- Ink (13). Its paths start slightly off the page (x ≈ −5).
- The single note.
- Pages with an offset media box or rotation. Only 6 of the 87 pages were
  printed, all with the media box at the origin.

**Type codes**, from the data:
- type 1 rows all have `text` (highlights);
- type 2 is a single 22×22 rect (a note icon);
- type 3 has rects (image);
- type 4 has `paths` (ink).

### 3–4. pdffigures2

Sample: 20 random library PDFs (45 MB).

| Run | Wall time | Peak memory | Output |
|---|---|---|---|
| `-t 2`, default heap | 3.8 s | 1.5 GB | JSON only (`-d`) |
| `-t 1 -Xmx512m` | 4.9 s | 0.7 GB | identical |

- Use `java -Xmx512m -jar pdffigures2.jar <dir> -t 1 -e -q -c -d <prefix>` for
  the background job: same output, half the memory, about 2 minutes for 415
  papers.
- Found 151 figures and 28 tables, plus 30 captions with no region. Counting
  every regionless caption as a missed figure gives about 83% recall, but that
  is crude: some regionless "captions" are table or appendix labels (one
  MNRAS paper repeats names 1–5), and one paper reports 14 figures with a
  highest number of 10, which is unexplained.
- A real measure would use labelled ground truth, e.g. the 87 zotero-figure
  regions.
- Clear failures:
  - a 1921 scan: 0 found;
  - an ADS-scanned 2002 proceedings: 2 found, 5 captions unlocated;
  - an MNRAS 2021 paper: 5 located, 14 unlocated captions;
  - a long review: 9 of 12.
- When a figure is found, the crop is accurate. Two contact sheets were
  checked visually: plots, maps, spectra, schematics and tables are all
  tight.
- Design impact:
  - Keep regionless captions (`-c`), so the gallery can show "Figure 4 — not
    located" with a one-click crop in the reader.
  - zotero-figure's layout model
    (`~/Zotero/zotero-figure/models/doclayout-yolo-…onnx`) could be a second
    detector. Its licence and speed are untested.

### 5. Figure type tags

**Caption keyword rules**, run over the 151 detected figures:
- 74 (49%) get a fine type: continuum image, spectrum, schematic, CMD,
  moment map, radial profile, SED, channel map.
- 15 of those come from inheriting "Same as Fig. N" captions; seven of the
  eight CMD figures in one paper are captioned that way.
- 64 get nothing.
- Correctness of the rule tags was not checked.

**`gemma4`** (8B, vision) through Ollama, temperature 0, no thinking. 0.3–0.5 s
per figure, so about 20 minutes for about 3000 figures. Scored against the
first 120 characters of each caption, without opening the images:
- **Fine types:** unreliable. It called schematics and a parameter plot "PV
  diagram", and colour–magnitude diagrams "scatter/line plot".
- **Coarse classes** (sky map / data plot / spectrum / schematic / other):
  12 of 16 right (14 figures from one paper, 2 from another), including
  every schematic. Maps of derived quantities were called "data plot".

**Design impact:** fine types come from captions and cover about half the
figures. `gemma4` gives every figure a coarse class. Filling the gap
(better rules, or Claude descriptions on demand) is still open.

### 6–7. ADS

**Preprints**
- 65 items have "arXiv" as their publication title, and 59 of them have an
  arXiv id.
- An `identifier:"arXiv:<id>"` query returns the canonical record. **54 are
  published** (e.g. MNRAS, Protostars and Planets VI), 5 are still preprints,
  and none were unknown.
- The migration report should offer these updates. Duplicate detection must
  run again afterwards, because a resolved preprint may duplicate an existing
  journal item.

**References.** ADS `reference` counts against a rough regex count of PDF
reference-list entries:

| Paper | PDF list (regex) | ADS `reference` |
|---|---|---|
| 2021MNRAS.504.1733S | 37 | 41 |
| 2013ApJ…766…49H | 17 | 21 |
| 2012ApJ…747…79K | 45 | 47 |
| 2020ApJ…895..142L | 106 | 109 |
| 2014prpl.conf..497E | 248 | 264 |

ADS returned more entries than the regex found in every case, so the regex
cannot prove completeness; it only shows ADS has substantial lists. The hover
card also needs a step that was not tested: matching one in-text citation
("Smith et al. 2020") to one entry. Old and scanned papers are untested.

### 8. arXiv source

HEAD requests only, with nothing downloaded.
- All 15 sampled ids returned `application/gzip`.
- The 3 whose headers were read are named `arXiv-<id>.tar.gz` (0.35–3.3 MB),
  so they are multi-file sources.
- Whether sources contain usable figure files (PDF, EPS or PNG) needs a few
  downloads, which were not done without asking.

### 9–10. CLIs

A 40-line MCP stdio server returned one figure PNG (a 100-dpi crop) as an
`image` content block.

- **Claude Code 2.1.319:** answered "x-axis V_LSR (km s⁻¹), y-axis S_ν (Jy),
  2 panels", which is correct.
- **Codex 0.155.1 (`gpt-6-sol`):** gave the same answer.
- **Not tested:** full-page or high-resolution images. Token cost and size
  limits are unknown.
- **Side finding:** `~/.codex/config.toml` sets `model = "gpt-6.1-sol"`, which
  the user's ChatGPT account rejects (`model_not_found`). Nebula's Codex chat
  fails unless another model is picked.
- **Resume:** `claude -p --resume <id>` continued the conversation from a new
  process, from the same folder, a subfolder and an unrelated folder.
  - So the CLI holds the session, not `Library/<citekey>/chat/`. Nebula must
    store the session id per paper and keep its own transcript for display.
  - How long the CLI keeps sessions is unknown.
  - Codex resume (`codex exec resume <thread>`, already used by Nebula) was
    not re-tested.

### 11. Chat links

The chat's Markdown renderer (`renderHtml` in `web-core/src/editor/preview.ts`)
keeps `nebula://paper/…?page=7&quote=…` as `<a href>`. The chat's click
handler only knows `data-open` and `data-revert`, and `ChatPane.swift` has no
navigation delegate, so a click is not handled. Needed: intercept `a[href]`
clicks in `web-core/src/chat/main.ts` and post them to Swift, which routes
`nebula://` to the reader and other URLs to the browser.

### 12. Keynote

`sdef /Applications/Keynote.app` lists `slide`, `slide layout`, `image` (with
`file`), `make` and `make image slides`. Adding a slide with an image looks
possible. Whether a **PDF** goes in as a vector image was not tested, because
it would drive the user's Keynote.

### 13. Zotero Connector protocol

Zotero's developer page [Connector HTTP Server](https://www.zotero.org/support/dev/client_coding/connector_http_server)
names the endpoints (`/connector/ping`, `saveItems`, `saveSnapshot`, …). The
request and response schema is defined by the source
([zotero-connectors](https://github.com/zotero/zotero-connectors)), not by a
spec. Emulating it stays not planned.

### 14. Memory

A standalone PDFKit script (not the app) opened 20 papers and rendered three
pages of each through the thumbnail API at Retina reader size.

- Opening the 20 documents: 7 → 20 MB, so about 0.65 MB per paper.
- Rendering three pages each: 295 MB. Rendered pixels are the cost.
- Opening one fresh paper and rendering its first page took 16 ms. That is
  one paper, one page, not a `PDFView` restoring a scroll position.
- Releasing 15 papers' renders did not lower resident memory in the script.

Whether the app's `PDFView` frees a suspended tab, and how fast a real restore
is, must be measured in the app with Instruments, as part of the perf
self-test (§10).

### 15. Dark mode

- One page was rendered to a bitmap, inverted with Core Image and lifted to a
  dark grey. The pdffigures2 figure regions were then composited back from
  the original.
- Result, on a 2020 ApJ page: dark text and background, and the ALMA figure
  in its true colours on its white panel.
- Not tested: doing this inside a live, scrolling `PDFView` within the
  performance budget.
- Figures that detection missed get inverted, so the reader needs a
  per-figure "keep colours" toggle. A dimming option for white figure panels
  may help.
