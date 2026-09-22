/**
 * events.ts — turns the CLI's stream-json event stream into a chat transcript.
 *
 * Claude Code (`claude -p --output-format stream-json --include-partial-messages`)
 * emits one JSON object per line:
 *   system/init                 session started (model, session_id)
 *   stream_event                token-level deltas of the assistant message
 *   assistant                   the complete assistant message (authoritative)
 *   user  (tool_result blocks)  results of the tools the assistant called
 *   result                      the turn is over (is_error, duration, …)
 * The Nebula shell adds its own `{type:"nebula", event:…}` lines (notices,
 * reverts, "cleared", "exited").
 *
 * Pure: `reduce(state, event)` mutates and returns the state; no DOM here.
 */

export interface TextBlock { type: "text"; text: string }
export interface ToolBlock {
  type: "tool";
  id: string;
  name: string;
  input: Record<string, unknown>;
  inputJson: string;          // partial JSON while streaming
  result?: string;
  isError?: boolean;
  reverted?: boolean;
}
export type Block = TextBlock | ToolBlock;

export type Item =
  | { kind: "user"; text: string }
  | { kind: "assistant"; msgId: string; blocks: Block[]; streaming: boolean }
  | { kind: "notice"; text: string; level: "info" | "error" }
  | { kind: "done"; seconds: number; isError: boolean };

export interface ChatState {
  items: Item[];
  busy: boolean;
  model: string;
  sessionID: string;
  /** The last turn failed on authentication — the account needs a fresh login
   * even if `auth status` still claims it's signed in (expired token). */
  authFailed: boolean;
}

export function emptyState(): ChatState {
  return { items: [], busy: false, model: "", sessionID: "", authFailed: false };
}

type Json = Record<string, unknown>;
const obj = (v: unknown): Json => (v && typeof v === "object" ? (v as Json) : {});
const str = (v: unknown): string => (typeof v === "string" ? v : "");

/** The assistant item currently streaming (or the last one with this id). */
function assistantFor(state: ChatState, msgId: string): Extract<Item, { kind: "assistant" }> {
  for (let i = state.items.length - 1; i >= 0; i--) {
    const it = state.items[i]!;
    if (it.kind === "assistant" && (it.msgId === msgId || (!msgId && it.streaming))) return it;
    if (it.kind === "user") break;             // never reach back into an earlier turn
  }
  const fresh: Extract<Item, { kind: "assistant" }> = { kind: "assistant", msgId, blocks: [], streaming: true };
  state.items.push(fresh);
  return fresh;
}

function currentStreaming(state: ChatState): Extract<Item, { kind: "assistant" }> | undefined {
  const last = state.items[state.items.length - 1];
  return last?.kind === "assistant" && last.streaming ? last : undefined;
}

function toBlocks(content: unknown): Block[] {
  if (!Array.isArray(content)) return [];
  const out: Block[] = [];
  for (const c of content) {
    const b = obj(c);
    if (b.type === "text") out.push({ type: "text", text: str(b.text) });
    else if (b.type === "tool_use") {
      out.push({ type: "tool", id: str(b.id), name: str(b.name), input: obj(b.input), inputJson: "" });
    }
    // thinking / redacted blocks are not shown
  }
  return out;
}

/** Tool results come back as a string or a list of text parts. */
function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((p) => str(obj(p).text)).filter(Boolean).join("\n");
  }
  return "";
}

function findTool(state: ChatState, id: string): ToolBlock | undefined {
  for (let i = state.items.length - 1; i >= 0; i--) {
    const it = state.items[i]!;
    if (it.kind !== "assistant") continue;
    for (const b of it.blocks) if (b.type === "tool" && b.id === id) return b;
  }
  return undefined;
}

export function addUser(state: ChatState, text: string): ChatState {
  state.items.push({ kind: "user", text });
  state.busy = true;
  return state;
}

export function reduce(state: ChatState, ev: Json): ChatState {
  // Sub-agent traffic (nested inside a Task tool) isn't shown inline.
  if (ev.parent_tool_use_id) return state;
  const t0 = str(ev.type);
  if (t0.startsWith("thread.") || t0.startsWith("turn.") || t0.startsWith("item.") || t0 === "error") {
    return reduceCodex(state, ev);
  }

  switch (ev.type) {
    case "system": {
      if (ev.subtype === "init") {
        state.model = str(ev.model);
        state.sessionID = str(ev.session_id);
      }
      return state;
    }

    case "stream_event": {
      const e = obj(ev.event);
      if (e.type === "message_start") {
        assistantFor(state, str(obj(e.message).id));
      } else if (e.type === "content_block_start") {
        const a = currentStreaming(state) ?? assistantFor(state, "");
        const cb = obj(e.content_block);
        if (cb.type === "text") a.blocks.push({ type: "text", text: str(cb.text) });
        else if (cb.type === "tool_use") {
          a.blocks.push({ type: "tool", id: str(cb.id), name: str(cb.name), input: {}, inputJson: "" });
        } else {
          a.blocks.push({ type: "text", text: "" });   // placeholder keeps indexes aligned
        }
      } else if (e.type === "content_block_delta") {
        const a = currentStreaming(state);
        const idx = typeof e.index === "number" ? e.index : -1;
        const blk = a && idx >= 0 ? a.blocks[idx] : a?.blocks[a.blocks.length - 1];
        const d = obj(e.delta);
        if (blk?.type === "text" && d.type === "text_delta") blk.text += str(d.text);
        else if (blk?.type === "tool" && d.type === "input_json_delta") blk.inputJson += str(d.partial_json);
      }
      return state;
    }

    case "assistant": {
      const m = obj(ev.message);
      const a = assistantFor(state, str(m.id));
      // The complete message is authoritative — but keep results/reverts that
      // already arrived for its tool blocks.
      const prev = new Map(a.blocks.filter((b): b is ToolBlock => b.type === "tool").map((b) => [b.id, b]));
      a.blocks = toBlocks(m.content).map((b) => {
        if (b.type !== "tool") return b;
        const old = prev.get(b.id);
        return old ? { ...b, result: old.result, isError: old.isError, reverted: old.reverted } : b;
      });
      a.streaming = false;
      return state;
    }

    case "user": {
      const content = obj(ev.message).content;
      if (!Array.isArray(content)) return state;
      for (const c of content) {
        const b = obj(c);
        if (b.type !== "tool_result") continue;
        const t = findTool(state, str(b.tool_use_id));
        if (t) { t.result = resultText(b.content); t.isError = b.is_error === true; }
      }
      return state;
    }

    case "result": {
      for (const it of state.items) if (it.kind === "assistant") it.streaming = false;
      const secs = typeof ev.duration_ms === "number" ? ev.duration_ms / 1000 : 0;
      const isError = ev.is_error === true;
      if (isError) {
        // The CLI also echoes the raw error as an assistant "reply" — drop that
        // so only the friendly notice shows.
        const raw = str(ev.result);
        const last = state.items[state.items.length - 1];
        if (last?.kind === "assistant" && last.blocks.length === 1 &&
            last.blocks[0]!.type === "text" && last.blocks[0]!.text.trim() === raw.trim()) {
          state.items.pop();
        }
        state.items.push({ kind: "notice", level: "error", text: friendlyError(raw) });
        if (isAuthError(raw)) state.authFailed = true;
      }
      const denials = Array.isArray(ev.permission_denials) ? ev.permission_denials.length : 0;
      if (denials > 0) {
        state.items.push({
          kind: "notice", level: "info",
          text: `有 ${denials} 個動作需要權限而被略過（目前模式不允許）。`,
        });
      }
      state.items.push({ kind: "done", seconds: secs, isError });
      if (!isError) state.authFailed = false;          // a good turn proves the login
      state.busy = false;
      return state;
    }

    case "nebula": {
      const e = str(ev.event);
      if (e === "notice") state.items.push({ kind: "notice", level: "error", text: str(ev.text) });
      else if (e === "cleared") {
        state.items = []; state.busy = false; state.sessionID = ""; state.authFailed = false;
      }
      else if (e === "reverted") {
        const t = findTool(state, str(ev.editID));
        if (t) t.reverted = true;
      } else if (e === "exited") {
        if (state.busy) {
          state.busy = false;
          for (const it of state.items) if (it.kind === "assistant") it.streaming = false;
          const err = str(ev.stderr).trim();
          state.items.push({
            kind: "notice", level: "info",
            text: err ? `已停止。${err.slice(-200)}` : "已停止。",
          });
        }
      }
      return state;
    }
  }
  return state;
}

/**
 * Codex (`codex exec --json`) speaks a different, simpler stream:
 *   thread.started {thread_id} · turn.started
 *   item.completed {item:{type: agent_message | reasoning | command_execution
 *                          | file_change | error, …}}
 *   turn.completed {usage} · turn.failed {error} · error {message}
 * Normalised into the same transcript items as Claude's.
 */
function reduceCodex(state: ChatState, ev: Json): ChatState {
  const type = str(ev.type);
  if (type === "thread.started") { state.sessionID = str(ev.thread_id); return state; }
  if (type === "turn.started") { state.busy = true; return state; }
  if (type === "error") {                       // stand-alone error line
    const msg = str(ev.message);
    state.items.push({ kind: "notice", level: "error", text: friendlyError(msg) });
    if (isAuthError(msg)) state.authFailed = true;
    return state;
  }

  if (type === "item.completed" || type === "item.started") {
    const item = obj(ev.item);
    const kind = str(item.type);
    if (kind === "reasoning") return state;                    // thinking isn't shown
    const a = assistantFor(state, "codex");
    if (kind === "agent_message") {
      const text = str(item.text);
      const existing = a.blocks.find((b) => b.type === "text" && b.text === text);
      if (!existing) a.blocks.push({ type: "text", text });
      return state;
    }
    if (kind === "error") {
      state.items.push({ kind: "notice", level: "error", text: friendlyError(str(item.message)) });
      if (isAuthError(str(item.message))) state.authFailed = true;
      return state;
    }
    // Everything else becomes a tool card, mapped onto the same shape.
    const id = str(item.id) || `${kind}-${a.blocks.length}`;
    const done = type === "item.completed";
    let name = kind, input: Json = {}, result: string | undefined;
    if (kind === "command_execution") {
      name = "Bash";
      input = { command: str(item.command) };
      if (done) result = str(item.aggregated_output);
    } else if (kind === "file_change") {
      const changes = Array.isArray(item.changes) ? item.changes.map((c) => obj(c)) : [];
      name = "Write";
      input = { file_path: str(changes[0]?.path), content: "" };
      if (done) result = changes.map((c) => `${str(c.kind)} ${str(c.path)}`).join("\n");
    } else {
      input = item;
      if (done) result = str(item.text) || undefined;
    }
    const prior = a.blocks.find((b): b is ToolBlock => b.type === "tool" && b.id === id);
    if (prior) { prior.result = result ?? prior.result; }
    else a.blocks.push({ type: "tool", id, name, input, inputJson: "", result });
    return state;
  }

  if (type === "turn.completed" || type === "turn.failed") {
    for (const it of state.items) if (it.kind === "assistant") it.streaming = false;
    const failed = type === "turn.failed";
    if (failed) {
      const msg = str(obj(ev.error).message);
      state.items.push({ kind: "notice", level: "error", text: friendlyError(msg) });
      if (isAuthError(msg)) state.authFailed = true;
    } else {
      state.authFailed = false;
    }
    state.items.push({ kind: "done", seconds: 0, isError: failed });
    state.busy = false;
    return state;
  }
  return state;
}

export function isAuthError(raw: string): boolean {
  return /token has expired|Not logged in|\/login|401|Failed to authenticate/i.test(raw);
}

/** Turn raw CLI/API errors into something actionable. */
export function friendlyError(raw: string): string {
  if (isAuthError(raw)) {
    return "這個帳號的登入已過期或尚未登入 — 按帳號選單的「登入」重新授權。";
  }
  if (/rate.?limit|usage limit|429/i.test(raw)) {
    return "已達訂閱的使用上限，稍後再試或切換到其他帳號。";
  }
  return raw || "發生錯誤";
}

/** The file an editing tool touches, and the before/after text for a diff. */
export interface EditView {
  path: string;
  kind: "edit" | "write";
  pairs: Array<{ old: string; new: string }>;
  content?: string;
}

export function editView(t: ToolBlock): EditView | null {
  const inp = t.input;
  const path = str(inp.file_path);
  if (!path) return null;
  if (t.name === "Edit") {
    return { path, kind: "edit", pairs: [{ old: str(inp.old_string), new: str(inp.new_string) }] };
  }
  if (t.name === "MultiEdit" && Array.isArray(inp.edits)) {
    return {
      path, kind: "edit",
      pairs: inp.edits.map((e) => ({ old: str(obj(e).old_string), new: str(obj(e).new_string) })),
    };
  }
  if (t.name === "Write") return { path, kind: "write", pairs: [], content: str(inp.content) };
  return null;
}

/** One-line summary for a non-edit tool call ("Read notes/a.md", "Grep 'dust'"). */
export function toolSummary(t: ToolBlock): string {
  const inp = t.input;
  const p = str(inp.file_path) || str(inp.path) || str(inp.notebook_path);
  switch (t.name) {
    case "Read": return `讀取 ${shortPath(p)}`;
    case "Glob": return `找檔案 ${str(inp.pattern)}`;
    case "Grep": return `搜尋「${str(inp.pattern)}」`;
    case "Bash": return `執行 ${str(inp.command).slice(0, 80)}`;
    case "WebFetch": return `讀網頁 ${str(inp.url)}`;
    case "WebSearch": return `網路搜尋「${str(inp.query)}」`;
    case "TodoWrite": return "更新待辦清單";
    case "Task": return `子任務：${str(inp.description)}`;
    default: return p ? `${t.name} ${shortPath(p)}` : t.name;
  }
}

export function shortPath(p: string): string {
  const parts = p.split("/");
  return parts.length > 3 ? "…/" + parts.slice(-2).join("/") : p;
}
