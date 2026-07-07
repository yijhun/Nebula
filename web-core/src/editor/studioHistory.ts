/**
 * studioHistory.ts — tiny undo/redo for the diagram studios. Serialize the
 * model to a string; `capture()` at the start of a gesture and `commit()` at
 * the end pushes an undo step only when the model actually changed. Bounded to
 * 100 steps.
 */
export interface History {
  /** Snapshot the current model as the "before" baseline for a gesture. */
  capture(): void;
  /** If the model changed since the last capture(), push an undo step. */
  commit(): void;
  undo(): void;
  redo(): void;
  canUndo(): boolean;
  canRedo(): boolean;
}

export function makeHistory(serialize: () => string, restore: (s: string) => void): History {
  const undoStack: string[] = [];
  const redoStack: string[] = [];
  let before: string | null = null;
  return {
    capture() { before = serialize(); },
    commit() {
      if (before !== null && serialize() !== before) {
        undoStack.push(before);
        if (undoStack.length > 100) undoStack.shift();
        redoStack.length = 0;
      }
      before = null;
    },
    undo() {
      const s = undoStack.pop();
      if (s === undefined) return;
      redoStack.push(serialize());
      restore(s);
    },
    redo() {
      const s = redoStack.pop();
      if (s === undefined) return;
      undoStack.push(serialize());
      restore(s);
    },
    canUndo: () => undoStack.length > 0,
    canRedo: () => redoStack.length > 0,
  };
}
