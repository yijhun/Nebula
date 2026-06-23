/**
 * plugin-loader — load an unmodified Obsidian plugin bundle (Spike C).
 *
 * An Obsidian plugin is a CommonJS bundle (`main.js`) that does
 * `require("obsidian")` and `module.exports` a `Plugin` subclass. We execute it
 * in a function scope with `require`/`module`/`exports` injected, route
 * `require("obsidian")` to our shim, instantiate the exported class, and run
 * its lifecycle (`load()` → `onload()`).
 *
 * Security note: this uses `new Function` to run third-party code. In the app
 * this runs inside the WKWebView sandbox; do not feed it untrusted plugins
 * without review. For Spike C we load known community bundles.
 */
import * as obsidianShim from "../obsidian-shim/index.js";
import type { App, Plugin, PluginManifest } from "../obsidian-shim/index.js";

// CodeMirror / Lezer modules that Obsidian exposes to plugins (it bundles these
// and serves them via require). We route plugin requires to our own copies so
// editor-integrating plugins (e.g. Tasks) resolve them.
import * as cmState from "@codemirror/state";
import * as cmView from "@codemirror/view";
import * as cmLanguage from "@codemirror/language";
import * as cmCommands from "@codemirror/commands";
import * as lezerCommon from "@lezer/common";
import * as lezerHighlight from "@lezer/highlight";

export interface LoadedPlugin {
  instance: Plugin;
  manifest: PluginManifest;
}

const MODULE_MAP: Record<string, unknown> = {
  obsidian: obsidianShim,
  "@codemirror/state": cmState,
  "@codemirror/view": cmView,
  "@codemirror/language": cmLanguage,
  "@codemirror/commands": cmCommands,
  "@lezer/common": lezerCommon,
  "@lezer/highlight": lezerHighlight,
};

/** Modules a plugin may `require`. Known modules resolve; unknown ones throw
 * (so we SEE what else a plugin expects — part of the spike's gap report). */
function makeRequire(): (id: string) => unknown {
  return (id: string) => {
    if (id in MODULE_MAP) return MODULE_MAP[id];
    throw new Error(`[plugin-loader] plugin required unsupported module "${id}"`);
  };
}

/** Execute a plugin bundle and start it against `app`. Resolves after the
 * plugin's (possibly async) `onload()` settles, so registrations are visible. */
export async function loadPlugin(
  manifest: PluginManifest,
  code: string,
  app: App,
): Promise<LoadedPlugin> {
  const module: { exports: Record<string, unknown> } = { exports: {} };
  const require = makeRequire();

  // CommonJS scope. `globalThis` is the page window (DOM is available).
  const runner = new Function("require", "module", "exports", `"use strict";\n${code}`);
  runner(require, module, module.exports);

  const exported = module.exports as Record<string, unknown>;
  const PluginClass = (exported.default ?? exported) as unknown;
  if (typeof PluginClass !== "function") {
    throw new Error("[plugin-loader] bundle did not export a Plugin class");
  }

  const instance = new (PluginClass as new (app: App, m: PluginManifest) => Plugin)(
    app,
    manifest,
  );
  instance._loaded = true;
  await Promise.resolve(instance.onload()); // await async onload
  return { instance, manifest };
}
