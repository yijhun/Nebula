/** Fallback label for a citekey Zotero couldn't resolve, e.g.
 *  "sandellNGC7538IRS1an2020a" → "Sandell (2020)".
 *
 * Better BibTeX keys end with the year, plus an optional a/b/c that tells
 * same-year papers apart, so the year is read from the END. The first
 * 4-digit run is often part of the title — "NGC7538", "12C13C" — and taking
 * it gave "Sandell (7538)". */
export function guessCiteLabel(key: string): string {
  const a = /^([A-Za-z][a-z]+)/.exec(key);
  const author = a ? a[1]!.charAt(0).toUpperCase() + a[1]!.slice(1) : key;
  const year = /((?:1[5-9]|20)\d\d)[a-z]?$/.exec(key)?.[1]
    // Not at the end: the last plausible year anywhere in the key.
    ?? [...key.matchAll(/(?<!\d)((?:1[5-9]|20)\d\d)(?!\d)/g)].pop()?.[1];
  return year ? `${author} (${year})` : key;
}
