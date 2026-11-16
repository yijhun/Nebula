/** Citation labels ("Sandell et al. (2020)") fetched from Zotero and cached.
 *
 * A key Zotero doesn't have used to loop: the lookup came back without it,
 * the preview re-rendered anyway, the render asked for the still-missing key
 * again, and so on — a full preview render plus a round of Zotero exports
 * every few hundred ms while the note just sat there (≈45% CPU, idle).
 * So a key Zotero answered without, or a lookup that failed, isn't asked for
 * again until `retryMs` has passed, and the preview is only re-rendered when
 * a label actually arrived. */
export interface CiteLookupDeps {
  /** Ask the host for labels; resolves to citekey → label for the keys it knows. */
  fetch: (keys: string[]) => Promise<unknown>;
  /** Called once new labels are in, so the preview can show them. */
  onLabels: () => void;
  now?: () => number;
  retryMs?: number;
}

export function createCiteLookup(deps: CiteLookupDeps) {
  const now = deps.now ?? (() => Date.now());
  const retryMs = deps.retryMs ?? 60_000;
  const labels = new Map<string, string>();
  const pending = new Set<string>();
  const missedAt = new Map<string, number>();

  const recentlyMissed = (k: string, t: number) => {
    const at = missedAt.get(k);
    return at !== undefined && t - at < retryMs;
  };

  /** Fetch labels for any keys not yet known, pending, or recently missed. */
  function ensure(keys: string[]): void {
    const t = now();
    const missing = [...new Set(keys)].filter(
      (k) => k && !labels.has(k) && !pending.has(k) && !recentlyMissed(k, t),
    );
    if (!missing.length) return;
    missing.forEach((k) => pending.add(k));
    deps.fetch(missing)
      .then((res) => {
        const map = (res ?? {}) as Record<string, unknown>;
        const at = now();
        let added = false;
        for (const k of missing) {
          pending.delete(k);
          const label = map[k];
          if (typeof label === "string" && label) {
            labels.set(k, label);
            missedAt.delete(k);
            added = true;
          } else {
            missedAt.set(k, at);
          }
        }
        if (added) deps.onLabels();
      })
      .catch(() => {
        const at = now();
        missing.forEach((k) => { pending.delete(k); missedAt.set(k, at); });
      });
  }

  return { ensure, label: (k: string) => labels.get(k) };
}
