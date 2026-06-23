/**
 * harness.ts — Spike C test harness.
 *
 * Loads real, unmodified Obsidian plugin bundles against the shim + loader in a
 * headless-friendly page, and reports what registered (commands / ribbon /
 * status bar / settings) or exactly where it failed. The whole point of the
 * spike: find out if the Hybrid bet (run unmodified plugins) holds, and if not,
 * which APIs are missing.
 */
import { App, type VaultAdapter, type PluginManifest } from "../obsidian-shim/index.js";
import { loadPlugin } from "../plugin-loader/index.js";

// A tiny in-memory vault so Vault/MetadataCache calls have something to chew on.
const files: Record<string, string> = {
  "Welcome.md": "# Welcome\n\n- [ ] a task #todo\n- [x] done ✅ 2024-01-01\n",
  "Projects/Alpha.md": "# Alpha\n\n- [ ] ship #project/alpha 📅 2024-12-31\n",
};
const adapter: VaultAdapter = {
  async read(p) { return files[p] ?? ""; },
  async write(p, d) { files[p] = d; },
  async list() { return Object.keys(files); },
  async exists(p) { return p in files; },
};

export interface SpikeReport {
  id: string;
  ok: boolean;
  commands?: string[];
  ribbon?: string[];
  statusBarItems?: number;
  settingTabs?: number;
  error?: string;
}

async function tryLoad(id: string, name: string, url: string): Promise<SpikeReport> {
  try {
    const code = await (await fetch(url)).text();
    const app = new App(adapter);
    await app.vault._index();
    const manifest: PluginManifest = { id, name, version: "0.0.0", minAppVersion: "1.0.0" };
    const { instance } = await loadPlugin(manifest, code, app);
    void instance;
    app.workspace._fireLayoutReady();
    return {
      id,
      ok: true,
      commands: app.commands.listCommands().map((c) => c.id),
      ribbon: app._ribbon.items.map((i) => i.title),
      statusBarItems: app._statusBar.items.length,
      settingTabs: app.setting.tabs.length,
    };
  } catch (e) {
    const err = e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e);
    return { id, ok: false, error: err };
  }
}

function show(report: SpikeReport): void {
  const out = document.getElementById("out");
  if (out) out.textContent = JSON.stringify(report, null, 2);
}

// Exposed for headless driving (Preview MCP eval).
(window as unknown as Record<string, unknown>).spikeC = {
  loadSample: async () => {
    const r = await tryLoad("sample-plugin", "Sample Plugin", "/spike-c-plugins/sample-main.js");
    show(r);
    (window as unknown as Record<string, unknown>).sampleReport = r;
    return r;
  },
  loadTasks: async () => {
    const r = await tryLoad("obsidian-tasks-plugin", "Tasks", "/spike-c-plugins/tasks-main.js");
    show(r);
    (window as unknown as Record<string, unknown>).tasksReport = r;
    return r;
  },
};

// Auto-run both plugins on load.
(async () => {
  const sample = await tryLoad("sample-plugin", "Sample Plugin", "/spike-c-plugins/sample-main.js");
  const tasks = await tryLoad("obsidian-tasks-plugin", "Tasks", "/spike-c-plugins/tasks-main.js");
  (window as unknown as Record<string, unknown>).sampleReport = sample;
  (window as unknown as Record<string, unknown>).tasksReport = tasks;
  const out = document.getElementById("out");
  if (out) {
    out.textContent =
      "✅ Sample plugin:\n" + JSON.stringify(sample, null, 2) +
      "\n\n✅ Tasks plugin (real, unmodified, v8.0.0):\n" + JSON.stringify(tasks, null, 2);
  }
})();
