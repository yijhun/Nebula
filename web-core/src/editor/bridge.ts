/**
 * bridge.ts — minimal JSON-RPC client over the WKWebView message bridge.
 *
 * JS → Swift: postMessage({ type:"rpc", id, method, params }).
 * Swift → JS: window.notepro._rpcResolve(id, ok, payload).
 *
 * Used for request/response calls into native services (e.g. ai.edit). The
 * fire-and-forget notifications (ready/dirty/loaded) stay as plain postMessage.
 */
interface Pending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

const pending = new Map<number, Pending>();
let nextId = 1;

function host(): { postMessage(m: unknown): void } | undefined {
  return (window as unknown as {
    webkit?: { messageHandlers?: { notepro?: { postMessage(m: unknown): void } } };
  }).webkit?.messageHandlers?.notepro;
}

/** Whether a native bridge is present (false in a plain browser). */
export function hasNativeBridge(): boolean {
  return host() !== undefined;
}

/** Call a native method and await its result. */
export function call(method: string, params: unknown): Promise<unknown> {
  const h = host();
  if (!h) return Promise.reject(new Error("no native bridge"));
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    h.postMessage({ type: "rpc", id, method, params });
  });
}

/** Called by the native side to settle a pending call. */
export function rpcResolve(id: number, ok: boolean, payload: unknown): void {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  if (ok) p.resolve(payload);
  else p.reject(new Error(typeof payload === "string" ? payload : "rpc error"));
}
