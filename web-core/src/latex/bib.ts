/**
 * bib.ts — produce a .bib containing ONLY the entries actually cited.
 *
 * Two sources are supported (DESIGN: "從 [@key] + Citations 的 .bib /
 * ZoteroReference 產出只含被引用條目的 .bib"):
 *   - a raw .bib database string -> filter to cited keys
 *   - structured Reference objects (Zotero-like) -> synthesize biblatex entries
 *
 * Output entry order follows `keys` (first-cited order), so the generated .bib
 * is stable and diff-friendly.
 */
import type { BibSource, Reference } from "./types.js";

/** Parse a .bib string into a map of citation key -> full entry text.
 * Uses brace matching so nested `{...}` in fields don't terminate an entry. */
export function parseBibtex(text: string): Map<string, string> {
  const entries = new Map<string, string>();
  let i = 0;
  const n = text.length;
  while (i < n) {
    if (text[i] !== "@") {
      i++;
      continue;
    }
    const at = i;
    i++; // skip '@'
    // entry type
    let type = "";
    while (i < n && /[A-Za-z]/.test(text[i]!)) type += text[i++]!;
    // skip whitespace to '{'
    while (i < n && /\s/.test(text[i]!)) i++;
    if (text[i] !== "{") continue;
    // @string/@comment/@preamble are not reference entries
    const lowerType = type.toLowerCase();
    // find the citation key (up to first comma)
    let braceStart = i;
    i++; // skip '{'
    let key = "";
    while (i < n && text[i] !== "," && text[i] !== "}") key += text[i++]!;
    key = key.trim();
    // match braces from braceStart to find the entry end
    let depth = 0;
    let j = braceStart;
    for (; j < n; j++) {
      if (text[j] === "{") depth++;
      else if (text[j] === "}") {
        depth--;
        if (depth === 0) {
          j++;
          break;
        }
      }
    }
    const entryText = text.slice(at, j).trim();
    if (key && lowerType !== "string" && lowerType !== "comment" &&
        lowerType !== "preamble") {
      entries.set(key, entryText);
    }
    i = j;
  }
  return entries;
}

/** Filter a .bib database down to the cited keys, in cited order. */
export function filterBibtex(text: string, keys: readonly string[]): string {
  const all = parseBibtex(text);
  const out: string[] = [];
  for (const key of keys) {
    const entry = all.get(key);
    if (entry) out.push(entry);
  }
  return out.join("\n\n") + (out.length ? "\n" : "");
}

function fieldLine(name: string, value: string | number | undefined): string {
  if (value === undefined || value === "") return "";
  return `  ${name} = {${value}},\n`;
}

/** Synthesize a single biblatex entry from a structured Reference. */
export function referenceToBibtex(ref: Reference): string {
  const type = ref.entryType ?? "misc";
  let out = `@${type}{${ref.key},\n`;
  out += fieldLine("title", ref.title);
  if (ref.authors && ref.authors.length) {
    out += fieldLine("author", ref.authors.join(" and "));
  }
  out += fieldLine("year", ref.year);
  out += fieldLine("journal", ref.journal);
  out += fieldLine("url", ref.url);
  for (const [k, v] of Object.entries(ref.fields ?? {})) {
    out += fieldLine(k, v);
  }
  out += "}";
  return out;
}

/** Build cited-only entries from structured references, in cited order. */
export function referencesToBibtex(
  refs: readonly Reference[],
  keys: readonly string[],
): string {
  const byKey = new Map(refs.map((r) => [r.key, r]));
  const out: string[] = [];
  for (const key of keys) {
    const ref = byKey.get(key);
    if (ref) out.push(referenceToBibtex(ref));
  }
  return out.join("\n\n") + (out.length ? "\n" : "");
}

/** Dispatch over the configured bib source for the given cited keys. */
export function buildBib(
  source: BibSource | undefined,
  keys: readonly string[],
): string {
  if (!source || keys.length === 0) return "";
  if (source.kind === "bibtex") return filterBibtex(source.text, keys);
  return referencesToBibtex(source.entries, keys);
}
