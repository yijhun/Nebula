# Spike C — running unmodified Obsidian plugins (result: PASS)

**Question (the Hybrid bet):** can an *unmodified* Obsidian plugin load and run
against a portable shim inside our web core? If yes, the Hybrid architecture
holds; if no, we'd fall back to native rewrites.

**Result: PASS.** Two real, unmodified plugin bundles load and register against
the shim + loader, verified headlessly:

| Plugin | Size | Result |
|---|---|---|
| `obsidian-sample-plugin` 1.0.0 | 25 KB | ✅ command + ribbon + status bar + settings tab |
| **`obsidian-tasks` 8.0.0** (real, complex) | 850 KB | ✅ **7 commands** (`edit-task`, `toggle-done`, `set-status-symbol-to-*`) + settings tab; `moment` works |

This meets the plan's Spike C criterion ("unmodified Tasks plugin loads").

## Mechanism

- **`web-core/src/plugin-loader/`** — runs a plugin's CommonJS `main.js` in a
  `new Function(require, module, exports, …)` scope, routing `require()` to a
  module map, then instantiates the exported `Plugin` subclass and awaits
  `onload()`.
- **`web-core/src/obsidian-shim/`** — a portable implementation of the public
  `obsidian` module (+ DOM helper polyfills in `dom.ts`).
- **Harness:** `web-core/spike-c.html` + `src/spike-c/harness.ts` (run via
  `vite` dev server → open `/spike-c.html`; auto-loads both plugins).

## Key findings (what it took)

1. **Plugins are ES5-transpiled.** They chain to their superclass via
   `Super.call(this, …)`, which throws on an ES6 `class`
   ("cannot be invoked without 'new'"). → The base classes plugins *extend*
   (Component, Plugin, Modal, PluginSettingTab, MarkdownRenderChild,
   EditorSuggest) are defined as **ES5 function constructors**.
2. **Plugins require CodeMirror/Lezer modules**, which Obsidian bundles and
   serves. Tasks needs only `obsidian` + `@codemirror/view`. → The loader maps
   `@codemirror/{state,view,language,commands}` and `@lezer/{common,highlight}`
   to our own installed copies.
3. **Tasks' concrete API needs** (now in the shim): `EditorSuggest`,
   `MarkdownView`, `window.moment` (we bundle `moment`), `app.loadLocalStorage`,
   `app.scope.register`, and utilities `setTooltip` / `sanitizeHTMLToDom` /
   `getAllTags` / `getLinkpath` / `parseFrontMatterTags` / `prepareSimpleSearch`.

## Caveats / not yet

- Plugins **load and register** (commands, settings, ribbon). Full *functional*
  behavior — rendering `- [ ]` task queries, editor autocomplete — additionally
  requires wiring `registerMarkdownPostProcessor` into the preview pane and
  `registerEditorExtension` into the live CodeMirror instance. Those hooks are
  captured by the shim but **not yet rendered into the app UI**.
- The shim is a **public-API subset**. Plugins that reach into Obsidian
  internals will hit gaps (surfaced as clear `require`/undefined errors — the
  loader rejects unknown modules so gaps are visible).
- Not yet integrated into `Notepro.app` — Spike C is a standalone validated
  harness. Wiring the plugin runtime into the app is the next step.

## Conclusion

The Hybrid thesis is **validated**: a portable TS shim can run unmodified real
plugins. Next: integrate the runtime into the app (post-processor → preview,
editor extensions → CodeMirror) and grow the shim API as more plugins are tried.
