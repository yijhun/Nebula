import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

/**
 * Second build: the chat panel (chat.html + src/chat) → dist/chat.html, one
 * self-contained file like the editor. Runs after the main build, so it must
 * not empty dist/.
 */
export default defineConfig({
  root: ".",
  define: { PACKAGE_VERSION: '"3.2.1"' },   // same MathJax eval guard as the editor
  plugins: [viteSingleFile()],
  build: {
    outDir: "dist",
    emptyOutDir: false,
    target: "es2020",
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    rollupOptions: { input: "chat.html" },
  },
});
