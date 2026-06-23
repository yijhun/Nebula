/**
 * notes.ts — the vault's note list, pushed from the native side. Shared by the
 * `[[` autocomplete (complete.ts) and the wikilink renderer (preview.ts) so
 * links can resolve / be flagged broken.
 */
let names: string[] = [];
let nameSet = new Set<string>();

export function setNoteNames(list: string[]): void {
  names = list;
  nameSet = new Set(list.map((n) => n.toLowerCase()));
}

export function getNoteNames(): string[] {
  return names;
}

/** Does a `[[target]]` resolve to a known note? (basename, case-insensitive) */
export function noteExists(target: string): boolean {
  const base = target.split(/[\\/]/).pop()!.replace(/\.md$/i, "").trim().toLowerCase();
  return nameSet.has(base);
}
