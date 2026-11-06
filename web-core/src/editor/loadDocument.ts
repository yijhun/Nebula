import { Compartment, Transaction, type EditorState, type TransactionSpec } from "@codemirror/state";
import { history } from "@codemirror/commands";

/** Undo history lives in a compartment so loading a document can reset it. */
const historyCompartment = new Compartment();
export const undoHistory = historyCompartment.of(history());

/** Replace the editor's text with another document, leaving nothing to undo.
 *
 * All open files share one editor view per tab. If a load were an ordinary
 * edit, ⌘Z would step back into the PREVIOUS file's text and report it as a
 * user edit, and autosave would then write that text over the current file.
 * Removing and re-adding the history extension is what drops its state. */
export function replaceDocument(
  view: { state: EditorState; dispatch(spec: TransactionSpec): void },
  text: string,
): void {
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: text },
    annotations: Transaction.addToHistory.of(false),
  });
  view.dispatch({ effects: historyCompartment.reconfigure([]) });
  view.dispatch({ effects: historyCompartment.reconfigure(history()) });
}
