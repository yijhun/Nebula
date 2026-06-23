import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

/**
 * Builds the editor (index.html + src/editor) into a single self-contained
 * dist/index.html, so the WKWebView can load it from the app bundle over
 * file:// with no module/CORS issues.
 */
export default defineConfig({
  root: ".",
  // mathjax-full's version.js does `eval('require')` / `eval('__dirname')` when
  // PACKAGE_VERSION is undefined — Node-only, throws in the WKWebView and blanks
  // the app. Defining it makes that the dead branch (no eval) → MathJax loads.
  define: { PACKAGE_VERSION: '"3.2.1"' },
  plugins: [viteSingleFile()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2020",
    // Inline everything (JS + CSS) into the HTML.
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
  },
});
