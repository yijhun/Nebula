import { describe, expect, it } from "vitest";
import { EditorState, type TransactionSpec } from "@codemirror/state";
import { undo, undoDepth } from "@codemirror/commands";
import { replaceDocument, undoHistory } from "../loadDocument.js";

function editor(doc: string) {
  const view = {
    state: EditorState.create({ doc, extensions: [undoHistory] }),
    dispatch(spec: TransactionSpec) { view.state = view.state.update(spec).state; },
  };
  return view;
}
const pressUndo = (v: ReturnType<typeof editor>) =>
  undo({ state: v.state, dispatch: (tr) => { v.state = tr.state; } });

describe("replaceDocument", () => {
  it("undo can't step back into the previously open document", () => {
    const v = editor("welcome");
    replaceDocument(v, "derivations");
    replaceDocument(v, "kenyon");
    replaceDocument(v, "physics");
    expect(pressUndo(v)).toBe(false);
    expect(v.state.doc.toString()).toBe("physics");
  });
  it("edits made in the previous document are forgotten too", () => {
    const v = editor("old");
    v.dispatch({ changes: { from: 3, insert: " typed" } });
    expect(undoDepth(v.state)).toBe(1);
    replaceDocument(v, "new");
    expect(undoDepth(v.state)).toBe(0);
    expect(pressUndo(v)).toBe(false);
    expect(v.state.doc.toString()).toBe("new");
  });
  it("undo still works for edits made after loading", () => {
    const v = editor("old");
    replaceDocument(v, "new");
    v.dispatch({ changes: { from: 3, insert: " typed" } });
    expect(pressUndo(v)).toBe(true);
    expect(v.state.doc.toString()).toBe("new");
  });
});
