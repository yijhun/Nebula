/**
 * obsidian-shim — a portable implementation of the public `obsidian` module,
 * enough to load and run real, unmodified community plugins (Spike C).
 *
 * Scope (v1): the public API surface plugins actually call — Component/Plugin
 * lifecycle, Notice/Modal/Setting UI, App/Vault/Workspace/MetadataCache,
 * file types, and common utilities. Private/internal Obsidian APIs are NOT
 * implemented; plugins that reach into internals will hit a documented gap.
 *
 * IMPORTANT: classes that plugins *extend* (Component, Plugin, Modal,
 * PluginSettingTab, MarkdownRenderChild) are defined as ES5 function
 * constructors, NOT ES6 `class`. Real plugin bundles are transpiled to ES5 and
 * chain to their superclass via `Super.call(this, …)`, which throws on an ES6
 * class ("cannot be invoked without 'new'"). Function constructors are callable.
 *
 * File I/O is delegated to an injected `VaultAdapter`.
 */
import { installDomShim } from "./dom.js";
import momentLib from "moment";

installDomShim();

// Obsidian exposes moment as a global (window.moment) and as an export.
// Plugins like Tasks rely on it for date parsing/formatting.
if (typeof window !== "undefined") {
  (window as unknown as { moment: unknown }).moment = momentLib;
}

/** Build an ES5-callable "class" (function constructor + prototype methods). */
function es5class(
  ctor: (this: Record<string, unknown>, ...args: never[]) => void,
  methods: Record<string, unknown>,
  parent?: Function,
): unknown {
  if (parent) {
    ctor.prototype = Object.create(parent.prototype);
    (ctor.prototype as Record<string, unknown>).constructor = ctor;
  }
  Object.assign(ctor.prototype, methods);
  return ctor;
}

// ---------------------------------------------------------------------------
// Events (ES6 class — never `.call`-ed by plugins; only our own types extend it)
// ---------------------------------------------------------------------------

export interface EventRef { cleanup(): void; }

export class Events {
  private _handlers: Record<string, Array<(...args: unknown[]) => unknown>> = {};
  on(name: string, cb: (...args: unknown[]) => unknown): EventRef {
    (this._handlers[name] ||= []).push(cb);
    return { cleanup: () => this.off(name, cb) };
  }
  off(name: string, cb: (...args: unknown[]) => unknown): void {
    const arr = this._handlers[name];
    if (arr) { const i = arr.indexOf(cb); if (i >= 0) arr.splice(i, 1); }
  }
  offref(ref: EventRef): void { ref?.cleanup?.(); }
  trigger(name: string, ...args: unknown[]): void {
    for (const fn of (this._handlers[name] || []).slice()) {
      try { fn(...args); } catch (e) { console.error(`[shim] event "${name}" threw`, e); }
    }
  }
}

// ---------------------------------------------------------------------------
// Component (ES5-callable)
// ---------------------------------------------------------------------------

export interface Component {
  _children: Component[];
  _cleanups: Array<() => void>;
  _loaded: boolean;
  onload(): void;
  onunload(): void;
  load(): void;
  unload(): void;
  addChild<T extends Component>(c: T): T;
  removeChild<T extends Component>(c: T): T;
  register(cb: () => void): void;
  registerEvent(ref: EventRef): void;
  registerDomEvent(el: EventTarget, type: string, cb: EventListenerOrEventListenerObject, opts?: AddEventListenerOptions): void;
  registerInterval(id: number): number;
}
export const Component = es5class(
  function (this: Record<string, unknown>) {
    this._children = [];
    this._cleanups = [];
    this._loaded = false;
  },
  {
    onload() {},
    onunload() {},
    load(this: Component) {
      if (this._loaded) return;
      this._loaded = true;
      this.onload();
      for (const c of this._children) c.load();
    },
    unload(this: Component) {
      if (!this._loaded) return;
      this._loaded = false;
      for (const fn of this._cleanups.splice(0)) {
        try { fn(); } catch (e) { console.error("[shim] cleanup threw", e); }
      }
      for (const c of this._children.splice(0)) c.unload();
      this.onunload();
    },
    addChild(this: Component, c: Component) {
      this._children.push(c);
      if (this._loaded) c.load();
      return c;
    },
    removeChild(this: Component, c: Component) {
      const i = this._children.indexOf(c);
      if (i >= 0) { this._children.splice(i, 1); c.unload(); }
      return c;
    },
    register(this: Component, cb: () => void) { this._cleanups.push(cb); },
    registerEvent(this: Component, ref: EventRef) {
      if (ref?.cleanup) this._cleanups.push(() => ref.cleanup());
    },
    registerDomEvent(this: Component, el: EventTarget, type: string, cb: EventListenerOrEventListenerObject, opts?: AddEventListenerOptions) {
      el.addEventListener(type, cb, opts);
      this._cleanups.push(() => el.removeEventListener(type, cb, opts));
    },
    registerInterval(this: Component, id: number) {
      this._cleanups.push(() => clearInterval(id));
      return id;
    },
  },
) as { new (): Component };

// ---------------------------------------------------------------------------
// Plugin (ES5-callable, extends Component)
// ---------------------------------------------------------------------------

export interface PluginManifest {
  id: string; name: string; version: string;
  minAppVersion?: string; author?: string; description?: string;
}
export interface Command {
  id: string; name: string;
  callback?: () => void;
  checkCallback?: (checking: boolean) => boolean | void;
  editorCallback?: (...args: unknown[]) => void;
  hotkeys?: unknown[];
}
export interface Plugin extends Component {
  app: App;
  manifest: PluginManifest;
  addCommand(cmd: Command): Command;
  addRibbonIcon(icon: string, title: string, cb: (e: MouseEvent) => void): HTMLElement;
  addStatusBarItem(): HTMLElement;
  addSettingTab(tab: PluginSettingTab): void;
  registerMarkdownPostProcessor(fn: unknown): unknown;
  registerMarkdownCodeBlockProcessor(lang: string, fn: unknown): unknown;
  registerView(type: string, ctor: unknown): void;
  registerEditorExtension(ext: unknown): void;
  registerEditorSuggest(s: unknown): void;
  registerObsidianProtocolHandler(a: string, b: unknown): void;
  registerHoverLinkSource(): void;
  loadData(): Promise<unknown>;
  saveData(data: unknown): Promise<void>;
}
export const Plugin = es5class(
  function (this: Record<string, unknown>, app: never, manifest: never) {
    (Component as unknown as Function).call(this);
    this.app = app;
    this.manifest = manifest;
  },
  {
    addCommand(this: Plugin, cmd: Command) { this.app.commands.addCommand(cmd); return cmd; },
    addRibbonIcon(this: Plugin, icon: string, title: string, cb: (e: MouseEvent) => void) {
      return this.app._ribbon.add(icon, title, cb);
    },
    addStatusBarItem(this: Plugin) { return this.app._statusBar.add(); },
    addSettingTab(this: Plugin, tab: PluginSettingTab) { this.app.setting.addTab(tab); },
    registerMarkdownPostProcessor(this: Plugin, fn: unknown) { this.app._mdPostProcessors.push(fn); return fn; },
    registerMarkdownCodeBlockProcessor(this: Plugin, lang: string, fn: unknown) { this.app._codeBlockProcessors[lang] = fn; return fn; },
    registerView(this: Plugin, type: string, ctor: unknown) { this.app._views[type] = ctor; },
    registerEditorExtension() {},
    registerEditorSuggest() {},
    registerObsidianProtocolHandler() {},
    registerHoverLinkSource() {},
    async loadData(this: Plugin) { return this.app._data.load(this.manifest.id); },
    async saveData(this: Plugin, data: unknown) { this.app._data.save(this.manifest.id, data); },
  },
  Component as unknown as Function,
) as { new (app: App, manifest: PluginManifest): Plugin };

// ---------------------------------------------------------------------------
// UI: Notice (ES6 — instantiated, not extended) / Modal (ES5) / Setting
// ---------------------------------------------------------------------------

function noticeContainer(): HTMLElement {
  let c = document.getElementById("notice-container");
  if (!c) { c = document.createElement("div"); c.id = "notice-container"; document.body.appendChild(c); }
  return c;
}

export class Notice {
  noticeEl: HTMLElement;
  constructor(message: string | DocumentFragment, timeout = 4000) {
    this.noticeEl = document.createElement("div");
    this.noticeEl.className = "notice";
    if (message instanceof Node) this.noticeEl.appendChild(message);
    else this.noticeEl.textContent = String(message);
    noticeContainer().appendChild(this.noticeEl);
    if (timeout > 0) setTimeout(() => this.hide(), timeout);
  }
  setMessage(message: string): this { this.noticeEl.textContent = message; return this; }
  hide(): void { this.noticeEl.remove(); }
}

export interface Modal {
  app: App;
  containerEl: HTMLElement;
  modalEl: HTMLElement;
  titleEl: HTMLElement;
  contentEl: HTMLElement;
  open(): void;
  close(): void;
  setTitle(title: string): this;
  onOpen(): void;
  onClose(): void;
}
export const Modal = es5class(
  function (this: Record<string, unknown>, app: never) {
    this.app = app;
    const container = document.createElement("div");
    container.className = "modal-container";
    this.containerEl = container;
    this.modalEl = container.createEl("div", { cls: "modal" });
    this.titleEl = (this.modalEl as HTMLElement).createEl("div", { cls: "modal-title" });
    this.contentEl = (this.modalEl as HTMLElement).createEl("div", { cls: "modal-content" });
  },
  {
    open(this: Modal) { document.body.appendChild(this.containerEl); this.onOpen(); },
    close(this: Modal) { this.onClose(); this.contentEl.empty(); this.containerEl.remove(); },
    setTitle(this: Modal, title: string) { this.titleEl.textContent = title; return this; },
    onOpen() {},
    onClose() {},
  },
) as { new (app: App): Modal };

// Setting + components (ES6 — instantiated with `new`, never extended)

class BaseComponent {
  disabled = false;
  setDisabled(d: boolean): this { this.disabled = d; return this; }
  then(cb: (c: this) => void): this { cb(this); return this; }
}
class TextComponent extends BaseComponent {
  inputEl: HTMLInputElement;
  private cb?: (v: string) => void;
  constructor(containerEl: HTMLElement, tag: "input" | "textarea" = "input") {
    super();
    this.inputEl = containerEl.createEl(tag as "input") as HTMLInputElement;
    if (tag === "input") this.inputEl.type = "text";
    this.inputEl.addEventListener("input", () => this.cb?.(this.inputEl.value));
  }
  getValue(): string { return this.inputEl.value; }
  setValue(v: string): this { this.inputEl.value = v; return this; }
  setPlaceholder(p: string): this { this.inputEl.placeholder = p; return this; }
  onChange(cb: (v: string) => void): this { this.cb = cb; return this; }
}
class ToggleComponent extends BaseComponent {
  toggleEl: HTMLInputElement;
  private cb?: (v: boolean) => void;
  constructor(containerEl: HTMLElement) {
    super();
    this.toggleEl = containerEl.createEl("input") as HTMLInputElement;
    this.toggleEl.type = "checkbox";
    this.toggleEl.addEventListener("change", () => this.cb?.(this.toggleEl.checked));
  }
  getValue(): boolean { return this.toggleEl.checked; }
  setValue(v: boolean): this { this.toggleEl.checked = v; return this; }
  onChange(cb: (v: boolean) => void): this { this.cb = cb; return this; }
}
class ButtonComponent extends BaseComponent {
  buttonEl: HTMLButtonElement;
  constructor(containerEl: HTMLElement) { super(); this.buttonEl = containerEl.createEl("button") as HTMLButtonElement; }
  setButtonText(t: string): this { this.buttonEl.textContent = t; return this; }
  setIcon(): this { return this; }
  setCta(): this { this.buttonEl.classList.add("mod-cta"); return this; }
  setWarning(): this { this.buttonEl.classList.add("mod-warning"); return this; }
  onClick(cb: (e: MouseEvent) => void): this { this.buttonEl.addEventListener("click", cb as EventListener); return this; }
}
class DropdownComponent extends BaseComponent {
  selectEl: HTMLSelectElement;
  private cb?: (v: string) => void;
  constructor(containerEl: HTMLElement) {
    super();
    this.selectEl = containerEl.createEl("select") as HTMLSelectElement;
    this.selectEl.addEventListener("change", () => this.cb?.(this.selectEl.value));
  }
  addOption(value: string, display: string): this {
    const o = this.selectEl.createEl("option") as HTMLOptionElement;
    o.value = value; o.textContent = display; return this;
  }
  addOptions(opts: Record<string, string>): this { for (const [v, d] of Object.entries(opts)) this.addOption(v, d); return this; }
  getValue(): string { return this.selectEl.value; }
  setValue(v: string): this { this.selectEl.value = v; return this; }
  onChange(cb: (v: string) => void): this { this.cb = cb; return this; }
}

export class Setting {
  settingEl: HTMLElement; infoEl: HTMLElement; nameEl: HTMLElement; descEl: HTMLElement; controlEl: HTMLElement;
  components: BaseComponent[] = [];
  constructor(containerEl: HTMLElement) {
    this.settingEl = containerEl.createEl("div", { cls: "setting-item" });
    this.infoEl = this.settingEl.createEl("div", { cls: "setting-item-info" });
    this.nameEl = this.infoEl.createEl("div", { cls: "setting-item-name" });
    this.descEl = this.infoEl.createEl("div", { cls: "setting-item-description" });
    this.controlEl = this.settingEl.createEl("div", { cls: "setting-item-control" });
  }
  setName(name: string): this { this.nameEl.textContent = name; return this; }
  setDesc(desc: string): this { this.descEl.textContent = desc; return this; }
  setHeading(): this { this.settingEl.classList.add("setting-item-heading"); return this; }
  setClass(cls: string): this { this.settingEl.classList.add(cls); return this; }
  addText(cb: (t: TextComponent) => void): this { const c = new TextComponent(this.controlEl); this.components.push(c); cb(c); return this; }
  addTextArea(cb: (t: TextComponent) => void): this { const c = new TextComponent(this.controlEl, "textarea"); this.components.push(c); cb(c); return this; }
  addToggle(cb: (t: ToggleComponent) => void): this { const c = new ToggleComponent(this.controlEl); this.components.push(c); cb(c); return this; }
  addButton(cb: (b: ButtonComponent) => void): this { const c = new ButtonComponent(this.controlEl); this.components.push(c); cb(c); return this; }
  addExtraButton(cb: (b: ButtonComponent) => void): this { const c = new ButtonComponent(this.controlEl); this.components.push(c); cb(c); return this; }
  addDropdown(cb: (d: DropdownComponent) => void): this { const c = new DropdownComponent(this.controlEl); this.components.push(c); cb(c); return this; }
  then(cb: (s: this) => void): this { cb(this); return this; }
}

export interface PluginSettingTab {
  app: App;
  plugin: Plugin;
  containerEl: HTMLElement;
  display(): void;
  hide(): void;
}
export const PluginSettingTab = es5class(
  function (this: Record<string, unknown>, app: never, plugin: never) {
    this.app = app;
    this.plugin = plugin;
    const el = document.createElement("div");
    el.className = "vertical-tab-content";
    this.containerEl = el;
  },
  {
    display() {},
    hide(this: PluginSettingTab) { this.containerEl.empty(); },
  },
) as { new (app: App, plugin: Plugin): PluginSettingTab };

// ---------------------------------------------------------------------------
// File model
// ---------------------------------------------------------------------------

export class TAbstractFile {
  path = ""; name = ""; parent: TFolder | null = null; vault!: Vault;
}
export class TFile extends TAbstractFile {
  basename = ""; extension = ""; stat = { ctime: 0, mtime: 0, size: 0 };
}
export class TFolder extends TAbstractFile {
  children: TAbstractFile[] = [];
  isRoot(): boolean { return this.parent === null; }
}

// ---------------------------------------------------------------------------
// Vault / MetadataCache / Workspace / App
// ---------------------------------------------------------------------------

export interface VaultAdapter {
  read(path: string): Promise<string>;
  write(path: string, data: string): Promise<void>;
  list(): Promise<string[]>;
  exists(path: string): Promise<boolean>;
}

export class Vault extends Events {
  adapter: VaultAdapter;
  configDir = ".obsidian";
  private _files = new Map<string, TFile>();
  constructor(adapter: VaultAdapter) { super(); this.adapter = adapter; }
  async _index(): Promise<void> {
    const paths = await this.adapter.list();
    this._files.clear();
    for (const p of paths) this._files.set(p, this._makeFile(p));
  }
  private _makeFile(path: string): TFile {
    const f = new TFile();
    f.path = path;
    f.name = path.split("/").pop() || path;
    const dot = f.name.lastIndexOf(".");
    f.basename = dot >= 0 ? f.name.slice(0, dot) : f.name;
    f.extension = dot >= 0 ? f.name.slice(dot + 1) : "";
    f.vault = this;
    return f;
  }
  getName(): string { return "vault"; }
  getRoot(): TFolder { const r = new TFolder(); r.path = "/"; r.vault = this; return r; }
  getFiles(): TFile[] { return [...this._files.values()]; }
  getMarkdownFiles(): TFile[] { return this.getFiles().filter((f) => f.extension === "md"); }
  getAllLoadedFiles(): TFile[] { return this.getFiles(); }
  getAbstractFileByPath(path: string): TFile | null { return this._files.get(path) ?? null; }
  async read(file: TFile): Promise<string> { return this.adapter.read(file.path); }
  async cachedRead(file: TFile): Promise<string> { return this.read(file); }
  async modify(file: TFile, data: string): Promise<void> { await this.adapter.write(file.path, data); this.trigger("modify", file); }
  async create(path: string, data: string): Promise<TFile> {
    await this.adapter.write(path, data);
    const f = this._makeFile(path); this._files.set(path, f); this.trigger("create", f); return f;
  }
}

export interface CachedMetadata {
  frontmatter?: Record<string, unknown>;
  tags?: Array<{ tag: string }>;
  links?: unknown[]; headings?: unknown[]; listItems?: unknown[];
}
export class MetadataCache extends Events {
  resolvedLinks: Record<string, Record<string, number>> = {};
  private _cache = new Map<string, CachedMetadata>();
  getFileCache(file: TFile): CachedMetadata | null { return this._cache.get(file.path) ?? null; }
  getCache(path: string): CachedMetadata | null { return this._cache.get(path) ?? null; }
  setCache(path: string, c: CachedMetadata): void { this._cache.set(path, c); }
  getFirstLinkpathDest(): TFile | null { return null; }
}

export class WorkspaceLeaf extends Events {
  view: unknown = null;
  getViewState(): unknown { return {}; }
  async setViewState(): Promise<void> {}
  detach(): void {}
}
export class Workspace extends Events {
  activeLeaf: WorkspaceLeaf | null = null;
  containerEl: HTMLElement = document.createElement("div");
  private _layoutReady: Array<() => void> = [];
  onLayoutReady(cb: () => void): void { this._layoutReady.push(cb); }
  _fireLayoutReady(): void {
    this.trigger("layout-ready");
    for (const cb of this._layoutReady.splice(0)) { try { cb(); } catch (e) { console.error(e); } }
  }
  getActiveFile(): TFile | null { return null; }
  getActiveViewOfType(): unknown { return null; }
  getLeavesOfType(): WorkspaceLeaf[] { return []; }
  getLeaf(): WorkspaceLeaf { return new WorkspaceLeaf(); }
  iterateAllLeaves(): void {}
}

export class CommandRegistry {
  commands: Record<string, Command> = {};
  addCommand(cmd: Command): void { this.commands[cmd.id] = cmd; }
  listCommands(): Command[] { return Object.values(this.commands); }
  executeCommandById(id: string): boolean { const c = this.commands[id]; if (!c) return false; c.callback?.(); return true; }
}
class RibbonRegistry {
  items: Array<{ icon: string; title: string; el: HTMLElement }> = [];
  add(icon: string, title: string, cb: (e: MouseEvent) => void): HTMLElement {
    const el = document.createElement("div");
    el.className = "side-dock-ribbon-action";
    el.setAttribute("aria-label", title);
    el.addEventListener("click", cb as EventListener);
    this.items.push({ icon, title, el });
    return el;
  }
}
class StatusBarRegistry {
  items: HTMLElement[] = [];
  add(): HTMLElement { const el = document.createElement("div"); el.className = "status-bar-item"; this.items.push(el); return el; }
}
class SettingRegistry {
  tabs: PluginSettingTab[] = [];
  addTab(tab: PluginSettingTab): void { this.tabs.push(tab); }
}
class DataStore {
  private store: Record<string, unknown> = {};
  load(id: string): unknown { return this.store[id] ?? null; }
  save(id: string, data: unknown): void { this.store[id] = data; }
}

export class App {
  vault: Vault;
  workspace = new Workspace();
  metadataCache = new MetadataCache();
  commands = new CommandRegistry();
  setting = new SettingRegistry();
  keymap = { pushScope() {}, popScope() {} };
  scope = { register: () => ({}), unregister: () => {} };
  _ribbon = new RibbonRegistry();
  _statusBar = new StatusBarRegistry();
  _data = new DataStore();
  _mdPostProcessors: unknown[] = [];
  _codeBlockProcessors: Record<string, unknown> = {};
  _views: Record<string, unknown> = {};
  constructor(adapter: VaultAdapter) { this.vault = new Vault(adapter); }

  loadLocalStorage(key: string): unknown {
    try {
      const v = localStorage.getItem(`notepro:${key}`);
      return v == null ? null : JSON.parse(v);
    } catch { return null; }
  }
  saveLocalStorage(key: string, value: unknown): void {
    try { localStorage.setItem(`notepro:${key}`, JSON.stringify(value)); } catch { /* ignore */ }
  }
}

// ---------------------------------------------------------------------------
// MarkdownRenderChild (ES5, extends Component) + misc view/util exports
// ---------------------------------------------------------------------------

export interface MarkdownRenderChild extends Component { containerEl: HTMLElement; }
export const MarkdownRenderChild = es5class(
  function (this: Record<string, unknown>, containerEl: never) {
    (Component as unknown as Function).call(this);
    this.containerEl = containerEl;
  },
  {},
  Component as unknown as Function,
) as { new (containerEl: HTMLElement): MarkdownRenderChild };

export class MarkdownRenderer {
  static async renderMarkdown(): Promise<void> {}
  static async render(): Promise<void> {}
}
export class Menu {
  addItem(cb: (item: MenuItem) => void): this { cb(new MenuItem()); return this; }
  addSeparator(): this { return this; }
  showAtMouseEvent(): void {}
  showAtPosition(): void {}
}
export class MenuItem {
  setTitle(): this { return this; }
  setIcon(): this { return this; }
  onClick(): this { return this; }
  setChecked(): this { return this; }
}

export function normalizePath(path: string): string {
  return path.replace(/\\/g, "/").replace(/\/+/g, "/").replace(/^\.\//, "").replace(/\/$/, "") || "/";
}
export function setIcon(el: HTMLElement, icon: string): void { (el as HTMLElement & { dataset: DOMStringMap }).dataset.icon = icon; }
export function addIcon(): void {}
export function debounce<T extends (...a: never[]) => unknown>(fn: T, timeout = 0): T {
  let h: ReturnType<typeof setTimeout> | undefined;
  return ((...args: never[]) => { clearTimeout(h); h = setTimeout(() => fn(...args), timeout); }) as T;
}
export const Platform = {
  isDesktop: true, isMobile: false, isMacOS: true, isWin: false, isLinux: false,
  isDesktopApp: true, isMobileApp: false,
};

/** moment — Obsidian bundles it and re-exports it. */
export const moment = momentLib;

// ---------------------------------------------------------------------------
// View hierarchy + EditorSuggest + more utilities (added for the Tasks plugin)
// ---------------------------------------------------------------------------

export class View {
  app: App | null = null;
  containerEl: HTMLElement = document.createElement("div");
  getViewType(): string { return ""; }
  getDisplayText(): string { return ""; }
}
export class ItemView extends View {}
export class MarkdownView extends View {
  file: TFile | null = null;
  editor: unknown = null;
  getMode(): string { return "source"; }
}
export class MarkdownPreviewView {}

export interface EditorSuggest extends Component {
  app: App;
  limit: number;
  onTrigger(...args: unknown[]): unknown;
  getSuggestions(...args: unknown[]): unknown[];
  renderSuggestion(...args: unknown[]): void;
  selectSuggestion(...args: unknown[]): void;
  close(): void;
}
export const EditorSuggest = es5class(
  function (this: Record<string, unknown>, app: never) {
    (Component as unknown as Function).call(this);
    this.app = app;
    this.limit = 0;
  },
  {
    onTrigger() { return null; },
    getSuggestions() { return []; },
    renderSuggestion() {},
    selectSuggestion() {},
    setInstructions() {},
    open() {},
    close() {},
  },
  Component as unknown as Function,
) as { new (app: App): EditorSuggest };

export const Keymap = {
  isModifier(): boolean { return false; },
  isModEvent(): string { return "click"; },
};

export function setTooltip(el: HTMLElement, tooltip: string): void {
  el.setAttribute("aria-label", tooltip);
}
export function sanitizeHTMLToDom(html: string): DocumentFragment {
  const t = document.createElement("template");
  t.innerHTML = html;
  return t.content;
}
export function getLinkpath(link: string): string {
  return link.split("#")[0]!.split("|")[0]!;
}
export function getAllTags(cache: CachedMetadata | null): string[] {
  return (cache?.tags ?? []).map((t) => t.tag);
}
export function parseFrontMatterTags(frontmatter: Record<string, unknown> | null): string[] | null {
  if (!frontmatter) return null;
  const t = (frontmatter.tags ?? frontmatter.tag) as unknown;
  if (t == null) return null;
  const arr = Array.isArray(t) ? t.map(String) : String(t).split(/[,\s]+/).filter(Boolean);
  return arr.map((x) => (x.startsWith("#") ? x : `#${x}`));
}
export function parseFrontMatterAliases(): string[] | null { return null; }
export function parseFrontMatterEntry(frontmatter: Record<string, unknown> | null, key: string): unknown {
  return frontmatter?.[key] ?? null;
}
type SearchResult = { score: number; matches: number[][] } | null;
export function prepareSimpleSearch(query: string): (text: string) => SearchResult {
  const q = query.toLowerCase();
  return (text: string) => (text.toLowerCase().includes(q) ? { score: 0, matches: [] } : null);
}
export function prepareFuzzySearch(query: string): (text: string) => SearchResult {
  return prepareSimpleSearch(query);
}
export function requireApiVersion(_v: string): boolean { return true; }
