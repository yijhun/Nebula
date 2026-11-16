import { describe, expect, it, vi } from "vitest";
import { createCiteLookup } from "../citeLookup.js";

const flush = () => new Promise((r) => setTimeout(r, 0));

/** A preview that re-renders on onLabels and asks again on every render —
 * the shape that used to loop. */
function harness(answer: (keys: string[]) => Promise<unknown>) {
  let t = 0;
  const fetch = vi.fn(answer);
  let renders = 0;
  const lookup = createCiteLookup({
    fetch,
    onLabels: () => { renders++; lookup.ensure(["known", "missing"]); },
    now: () => t,
    retryMs: 60_000,
  });
  return { lookup, fetch, renders: () => renders, advance: (ms: number) => { t += ms; } };
}

describe("cite label lookup", () => {
  it("doesn't keep asking for a key Zotero doesn't have", async () => {
    const h = harness(async (keys) => Object.fromEntries(keys.filter((k) => k === "known").map((k) => [k, "Known (2020)"])));
    h.lookup.ensure(["known", "missing"]);
    for (let i = 0; i < 10; i++) await flush();
    expect(h.fetch).toHaveBeenCalledTimes(1);
    expect(h.renders()).toBe(1);
    expect(h.lookup.label("known")).toBe("Known (2020)");
    expect(h.lookup.label("missing")).toBeUndefined();
  });

  it("doesn't re-render when no label arrived", async () => {
    const h = harness(async () => ({}));
    h.lookup.ensure(["missing"]);
    await flush();
    expect(h.renders()).toBe(0);
    h.lookup.ensure(["missing"]);                 // e.g. the next keystroke's render
    await flush();
    expect(h.fetch).toHaveBeenCalledTimes(1);
  });

  it("asks again for a missed key after the retry interval", async () => {
    const h = harness(async () => ({}));
    h.lookup.ensure(["missing"]);
    await flush();
    h.advance(59_000);
    h.lookup.ensure(["missing"]);
    expect(h.fetch).toHaveBeenCalledTimes(1);
    h.advance(2_000);
    h.lookup.ensure(["missing"]);
    expect(h.fetch).toHaveBeenCalledTimes(2);
  });

  it("backs off after a failed lookup too", async () => {
    const h = harness(async () => { throw new Error("Zotero closed"); });
    h.lookup.ensure(["a"]);
    await flush();
    h.lookup.ensure(["a"]);
    expect(h.fetch).toHaveBeenCalledTimes(1);
  });

  it("still fetches new keys while others are backing off", async () => {
    const h = harness(async () => ({}));
    h.lookup.ensure(["missing"]);
    await flush();
    h.lookup.ensure(["missing", "fresh"]);
    expect(h.fetch).toHaveBeenLastCalledWith(["fresh"]);
  });
});
