/**
 * ai.ts — inline AI assist overlay (⌘K). Two modes:
 *  - EDIT (text selected): preset/instruction → rewrite → inline DIFF
 *    (accept/reject hunks) → apply (replaces selection, undoable).
 *  - GENERATE (no selection): instruction → AI writes new content using the
 *    preceding text as context → review → insert at the cursor.
 * The web owns the UX; model calls go over the bridge (Ollama).
 */
import { EditorView } from "@codemirror/view";
import { t } from "./i18n.js";
import { EditorState } from "@codemirror/state";
import { unifiedMergeView } from "@codemirror/merge";
import { call } from "./bridge.js";
import { getConfig } from "./config.js";

type Mode = "edit" | "generate";
let overlay: HTMLElement | null = null;
let mergeView: EditorView | null = null;

export function closeAI(): void {
  mergeView?.destroy();
  mergeView = null;
  overlay?.remove();
  overlay = null;
}

export function openAI(view: EditorView): void {
  const sel = view.state.selection.main;
  const text = view.state.sliceDoc(sel.from, sel.to);
  const mode: Mode = text.trim() ? "edit" : "generate";
  closeAI();
  overlay = build(view, text, sel.from, sel.to, mode);
  document.body.appendChild(overlay);
  (overlay.querySelector("input") as HTMLInputElement | null)?.focus();
}

function chip(label: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement("button");
  b.textContent = label;
  b.style.cssText =
    "background:#2c313a;color:#cdd3df;border:1px solid #3a3f4b;border-radius:14px;padding:4px 12px;font-size:12px;cursor:pointer";
  b.onclick = onClick;
  return b;
}

function build(view: EditorView, text: string, from: number, to: number, mode: Mode): HTMLElement {
  const panel = document.createElement("div");
  panel.className = "np-ai";
  panel.style.cssText =
    "position:fixed;top:56px;left:50%;transform:translateX(-50%);width:min(720px,92vw);" +
    "background:#21252b;color:#e6e6e6;border:1px solid #3a3f4b;border-radius:10px;" +
    "box-shadow:0 12px 40px rgba(0,0,0,.5);z-index:9998;padding:14px;font-family:-apple-system,sans-serif";

  const title = document.createElement("div");
  title.textContent = mode === "edit" ? t("AI 協助 — ⌘K") : t("AI 生成（游標處插入）— ⌘K");
  title.style.cssText = "font-weight:600;font-size:13px;margin-bottom:10px;opacity:.8";
  panel.appendChild(title);

  const chips = document.createElement("div");
  chips.style.cssText = "display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px";
  const presets = mode === "edit" ? getConfig().aiPresets : getConfig().genPresets;
  for (const p of presets) {
    chips.appendChild(chip(p.label, () => run(p.instruction)));
  }
  panel.appendChild(chips);

  const input = document.createElement("input");
  input.type = "text";
  input.placeholder = mode === "edit" ? t("或輸入自訂指示，按 Enter…") : t("要生成什麼？按 Enter…");
  input.style.cssText =
    "width:100%;box-sizing:border-box;background:#1b1e24;color:#e6e6e6;border:1px solid #3a3f4b;border-radius:6px;padding:8px 10px;font-size:13px";
  input.onkeydown = (e) => {
    if (e.key === "Enter" && input.value.trim()) run(input.value.trim());
    else if (e.key === "Escape") closeAI();
  };
  panel.appendChild(input);

  const status = document.createElement("div");
  status.style.cssText = "font-size:12px;opacity:.7;margin-top:8px;min-height:16px";
  panel.appendChild(status);

  const out = document.createElement("div");
  out.style.cssText =
    "display:none;margin-top:10px;border:1px solid #3a3f4b;border-radius:6px;max-height:300px;overflow:auto;font-size:13px";
  panel.appendChild(out);

  const actions = document.createElement("div");
  actions.style.cssText = "display:none;gap:8px;margin-top:10px;justify-content:flex-end;align-items:center";
  const apply = document.createElement("button");
  apply.textContent = mode === "edit" ? t("套用 Apply") : t("插入 Insert");
  apply.style.cssText = "background:#3b82f6;color:#fff;border:0;border-radius:6px;padding:6px 14px;font-size:13px;cursor:pointer";
  const cancel = document.createElement("button");
  cancel.textContent = t("取消 Cancel");
  cancel.style.cssText = "background:#2c313a;color:#cdd3df;border:1px solid #3a3f4b;border-radius:6px;padding:6px 14px;font-size:13px;cursor:pointer";
  cancel.onclick = closeAI;
  actions.append(cancel, apply);
  panel.appendChild(actions);

  let generated = "";

  function run(instruction: string): void {
    status.textContent = t("思考中… (模型運算中)");
    out.style.display = "none";
    actions.style.display = "none";
    mergeView?.destroy();
    mergeView = null;

    if (mode === "edit") {
      call("ai.edit", { text, instruction })
        .then((res) => {
          const suggestion = asText(res);
          if (suggestion.trim() === text.trim()) { status.textContent = t("AI 未提出變更。"); return; }
          status.textContent = t("檢視修改（綠＝新增、紅＝刪除）：");
          out.innerHTML = "";
          out.style.display = "block";
          mergeView = new EditorView({
            parent: out,
            doc: suggestion,
            extensions: [EditorView.editable.of(true), EditorView.lineWrapping, EditorState.readOnly.of(false), unifiedMergeView({ original: text, mergeControls: true })],
          });
          actions.style.display = "flex";
        })
        .catch(onErr);
    } else {
      const context = view.state.sliceDoc(Math.max(0, from - 1500), from);
      call("ai.generate", { context, instruction })
        .then((res) => {
          generated = asText(res);
          if (!generated.trim()) { status.textContent = t("AI 沒有產生內容。"); return; }
          status.textContent = t("預覽（將插入游標處）：");
          out.textContent = generated;
          out.style.cssText += ";display:block;padding:10px;white-space:pre-wrap";
          actions.style.display = "flex";
        })
        .catch(onErr);
    }
  }

  function onErr(err: Error): void {
    status.textContent = t("失敗：") + err.message + t("（請確認 Ollama 正在執行）");
  }

  apply.onclick = () => {
    if (mode === "edit") {
      const finalText = mergeView ? mergeView.state.doc.toString() : "";
      if (finalText) {
        view.dispatch({ changes: { from, to, insert: finalText }, selection: { anchor: from, head: from + finalText.length } });
      }
    } else if (generated) {
      view.dispatch({ changes: { from, insert: generated }, selection: { anchor: from + generated.length } });
    }
    view.focus();
    closeAI();
  };

  return panel;
}

function asText(res: unknown): string {
  return typeof res === "string" ? res : String((res as { text?: string })?.text ?? "");
}
