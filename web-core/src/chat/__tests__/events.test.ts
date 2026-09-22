import { describe, expect, it } from "vitest";
import { emptyState, reduce, addUser, editView, toolSummary, friendlyError, type ChatState } from "../events.js";

const feed = (s: ChatState, evs: Record<string, unknown>[]) => { evs.forEach((e) => reduce(s, e)); return s; };
const se = (event: Record<string, unknown>) => ({ type: "stream_event", event });

describe("chat event reducer", () => {
  it("streams text deltas, then the full message replaces them", () => {
    const s = addUser(emptyState(), "hi");
    feed(s, [
      { type: "system", subtype: "init", model: "claude-opus-5", session_id: "S1" },
      se({ type: "message_start", message: { id: "m1" } }),
      se({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hel" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "lo" } }),
    ]);
    expect(s.model).toBe("claude-opus-5");
    expect(s.sessionID).toBe("S1");
    const a = s.items[1]!;
    expect(a.kind).toBe("assistant");
    if (a.kind !== "assistant") return;
    expect(a.streaming).toBe(true);
    expect(a.blocks).toEqual([{ type: "text", text: "Hello" }]);

    reduce(s, { type: "assistant", message: { id: "m1", content: [{ type: "text", text: "Hello!" }] } });
    expect(s.items.length).toBe(2);                     // same item, not a duplicate
    expect(a.blocks).toEqual([{ type: "text", text: "Hello!" }]);
    expect(a.streaming).toBe(false);
  });

  it("attaches tool results and keeps them across the authoritative message", () => {
    const s = addUser(emptyState(), "read it");
    feed(s, [
      se({ type: "message_start", message: { id: "m1" } }),
      se({ type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "t1", name: "Read" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "{\"file" } }),
      { type: "assistant", message: { id: "m1", content: [
        { type: "tool_use", id: "t1", name: "Read", input: { file_path: "/v/notes/a.md" } }] } },
      { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: "file body" }] }] } },
      { type: "result", subtype: "success", is_error: false, duration_ms: 2300 },
    ]);
    const a = s.items[1]!;
    if (a.kind !== "assistant") throw new Error("no assistant");
    const t = a.blocks[0]!;
    if (t.type !== "tool") throw new Error("no tool");
    expect(t.result).toBe("file body");
    expect(toolSummary(t)).toBe("讀取 …/notes/a.md");   // long paths are shortened
    expect(s.busy).toBe(false);
    expect(s.items[s.items.length - 1]).toEqual({ kind: "done", seconds: 2.3, isError: false });
  });

  it("a second assistant message in the same turn becomes its own item", () => {
    const s = addUser(emptyState(), "q");
    feed(s, [
      { type: "assistant", message: { id: "m1", content: [{ type: "tool_use", id: "t1", name: "Grep", input: { pattern: "dust" } }] } },
      { type: "assistant", message: { id: "m2", content: [{ type: "text", text: "Found it." }] } },
    ]);
    expect(s.items.map((i) => i.kind)).toEqual(["user", "assistant", "assistant"]);
  });

  it("errors become a friendly notice; auth failures point at login", () => {
    const s = addUser(emptyState(), "q");
    reduce(s, { type: "result", is_error: true,
      result: "Failed to authenticate. API Error: 401 OAuth access token has expired." });
    const n = s.items.find((i) => i.kind === "notice");
    expect(n && n.kind === "notice" && n.text).toMatch(/登入/);
    expect(s.authFailed).toBe(true);
    expect(friendlyError("usage limit reached")).toMatch(/上限/);
  });

  it("drops the CLI's echo of the raw error (the real event sequence)", () => {
    // Recorded from `claude -p … --output-format stream-json` with an expired login.
    const raw = "Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue.";
    const s = addUser(emptyState(), "q");
    feed(s, [
      { type: "system", subtype: "init", model: "claude-opus-5[1m]", session_id: "f9c5" },
      { type: "assistant", message: { id: "a1", content: [{ type: "text", text: raw }] } },
      { type: "result", subtype: "success", is_error: true, result: raw, duration_ms: 2177 },
    ]);
    expect(s.items.map((i) => i.kind)).toEqual(["user", "notice", "done"]);
    // A later successful turn clears the flag.
    feed(s, [{ type: "result", is_error: false, duration_ms: 900 }]);
    expect(s.authFailed).toBe(false);
  });

  it("ignores sub-agent traffic and handles shell events", () => {
    const s = addUser(emptyState(), "q");
    reduce(s, { type: "assistant", parent_tool_use_id: "task1", message: { id: "x", content: [{ type: "text", text: "inner" }] } });
    expect(s.items.length).toBe(1);
    reduce(s, { type: "nebula", event: "exited", code: 130, stderr: "" });
    expect(s.busy).toBe(false);
    reduce(s, { type: "nebula", event: "cleared" });
    expect(s.items).toEqual([]);
  });

  it("marks an edit reverted", () => {
    const s = addUser(emptyState(), "fix");
    reduce(s, { type: "assistant", message: { id: "m", content: [
      { type: "tool_use", id: "e1", name: "Edit", input: { file_path: "a.md", old_string: "x", new_string: "y" } }] } });
    reduce(s, { type: "nebula", event: "reverted", editID: "e1" });
    const a = s.items[1]!;
    if (a.kind !== "assistant" || a.blocks[0]!.type !== "tool") throw new Error();
    expect(a.blocks[0]!.reverted).toBe(true);
  });
});

describe("editView", () => {
  const tool = (name: string, input: Record<string, unknown>) =>
    ({ type: "tool" as const, id: "t", name, input, inputJson: "" });
  it("Edit / MultiEdit / Write", () => {
    expect(editView(tool("Edit", { file_path: "a.md", old_string: "a", new_string: "b" })))
      .toEqual({ path: "a.md", kind: "edit", pairs: [{ old: "a", new: "b" }] });
    expect(editView(tool("MultiEdit", { file_path: "a.md", edits: [{ old_string: "1", new_string: "2" }, { old_string: "3", new_string: "4" }] }))!.pairs.length).toBe(2);
    expect(editView(tool("Write", { file_path: "n.md", content: "hi" }))!.kind).toBe("write");
    expect(editView(tool("Read", { file_path: "a.md" }))).toBeNull();
  });
});
