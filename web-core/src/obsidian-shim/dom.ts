/**
 * dom.ts — Obsidian's HTMLElement extensions.
 *
 * Obsidian augments the DOM prototype with helpers (`createEl`, `empty`,
 * `setText`, `addClass`, …) that virtually every plugin uses for its UI.
 * We polyfill the common subset onto HTMLElement/Document so unmodified plugin
 * code that calls `containerEl.createEl("div", { text })` just works.
 */

export interface DomElementInfo {
  cls?: string | string[];
  text?: string;
  title?: string;
  attr?: Record<string, string | number | boolean | null>;
  href?: string;
  type?: string;
  placeholder?: string;
  value?: string;
}

// Tell TypeScript about the methods installDomShim() adds at runtime.
declare global {
  interface HTMLElement {
    createEl<K extends keyof HTMLElementTagNameMap>(
      tag: K, info?: DomElementInfo | string, cb?: (el: HTMLElementTagNameMap[K]) => void,
    ): HTMLElementTagNameMap[K];
    createEl(tag: string, info?: DomElementInfo | string, cb?: (el: HTMLElement) => void): HTMLElement;
    createDiv(info?: DomElementInfo | string, cb?: (el: HTMLDivElement) => void): HTMLDivElement;
    createSpan(info?: DomElementInfo | string, cb?: (el: HTMLSpanElement) => void): HTMLSpanElement;
    empty(): this;
    setText(text: string): this;
    appendText(text: string): this;
    addClass(...cls: string[]): this;
    removeClass(...cls: string[]): this;
    toggleClass(cls: string, on?: boolean): this;
    setAttr(k: string, v: string | number | boolean | null): this;
    onClickEvent(listener: (e: MouseEvent) => void): this;
  }
  interface Document {
    createEl(tag: string, info?: DomElementInfo | string, cb?: (el: HTMLElement) => void): HTMLElement;
  }
}

function applyInfo(el: HTMLElement, info?: DomElementInfo | string): void {
  if (info == null) return;
  if (typeof info === "string") {
    el.className = info;
    return;
  }
  if (info.cls) {
    el.classList.add(...(Array.isArray(info.cls) ? info.cls : [info.cls]));
  }
  if (info.text != null) el.textContent = info.text;
  if (info.title != null) el.title = info.title;
  if (info.href != null) el.setAttribute("href", info.href);
  if (info.type != null) el.setAttribute("type", info.type);
  if (info.placeholder != null) el.setAttribute("placeholder", info.placeholder);
  if (info.value != null) (el as HTMLInputElement).value = info.value;
  if (info.attr) {
    for (const [k, v] of Object.entries(info.attr)) {
      if (v == null || v === false) continue;
      el.setAttribute(k, v === true ? "" : String(v));
    }
  }
}

type Creator = (
  tag: string,
  info?: DomElementInfo | string,
  callback?: (el: HTMLElement) => void,
) => HTMLElement;

let installed = false;

/** Install the Obsidian DOM helpers (idempotent). Safe to call at boot. */
export function installDomShim(): void {
  if (installed || typeof HTMLElement === "undefined") return;
  installed = true;

  const proto = HTMLElement.prototype as unknown as Record<string, unknown>;

  const createEl: Creator = function (this: HTMLElement, tag, info, cb) {
    const el = document.createElement(tag);
    applyInfo(el, info);
    this.appendChild(el);
    cb?.(el);
    return el;
  };

  proto.createEl = createEl;
  proto.createDiv = function (this: HTMLElement, info?: DomElementInfo | string, cb?: (el: HTMLElement) => void) {
    return createEl.call(this, "div", info, cb);
  };
  proto.createSpan = function (this: HTMLElement, info?: DomElementInfo | string, cb?: (el: HTMLElement) => void) {
    return createEl.call(this, "span", info, cb);
  };
  proto.empty = function (this: HTMLElement) {
    while (this.firstChild) this.removeChild(this.firstChild);
    return this;
  };
  proto.setText = function (this: HTMLElement, text: string) {
    this.textContent = text;
    return this;
  };
  proto.appendText = function (this: HTMLElement, text: string) {
    this.appendChild(document.createTextNode(text));
    return this;
  };
  proto.addClass = function (this: HTMLElement, ...cls: string[]) {
    this.classList.add(...cls);
    return this;
  };
  proto.removeClass = function (this: HTMLElement, ...cls: string[]) {
    this.classList.remove(...cls);
    return this;
  };
  proto.toggleClass = function (this: HTMLElement, cls: string, on?: boolean) {
    this.classList.toggle(cls, on);
    return this;
  };
  proto.setAttr = function (this: HTMLElement, k: string, v: string | number | boolean | null) {
    if (v == null || v === false) this.removeAttribute(k);
    else this.setAttribute(k, v === true ? "" : String(v));
    return this;
  };
  proto.onClickEvent = function (this: HTMLElement, listener: (e: MouseEvent) => void) {
    this.addEventListener("click", listener as EventListener);
    return this;
  };

  // Document.createEl / createDiv (some plugins use the global form).
  const docProto = Document.prototype as unknown as Record<string, unknown>;
  docProto.createEl = function (this: Document, tag: string, info?: DomElementInfo | string, cb?: (el: HTMLElement) => void) {
    const el = document.createElement(tag);
    applyInfo(el, info);
    cb?.(el);
    return el;
  };
}
