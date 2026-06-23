/**
 * config.ts — central user-configurable settings for the web core.
 *
 * The native shell stores prefs (@AppStorage) and pushes them in via
 * `window.notepro.configure(json)`; web modules read `getConfig()` instead of
 * hardcoded constants, so users can tailor presets / cite format / appearance /
 * snippets to their own habits.
 */
export interface PresetCfg { label: string; instruction: string; }
export interface SnippetCfg { label: string; template: string; }
export type CiteStyle = "author-year" | "citekey";

export interface NoteproConfig {
  aiPresets: PresetCfg[];
  genPresets: PresetCfg[];
  citeLatexCommand: string; // e.g. "autocite" → \autocite{key}
  previewCiteStyle: CiteStyle;
  fontSize: number;
  fontFamily: string;
  lineHeight: number;
  snippets: SnippetCfg[];
  /** Default Markdown→LaTeX template when a note has no frontmatter `template`. */
  defaultTemplate: string;
}

export const DEFAULT_CONFIG: NoteproConfig = {
  aiPresets: [
    { label: "潤飾", instruction: "潤飾下面的文字，使其更通順自然，保持原意與原本的語言。" },
    { label: "文法", instruction: "修正下面文字的文法與錯字，只更正錯誤，不要改寫風格。" },
    { label: "精簡", instruction: "將下面文字精簡，去除冗詞贅句，保留所有要點。" },
    { label: "改寫", instruction: "改寫下面文字，使其更清楚、更專業。" },
    { label: "翻譯→英文", instruction: "將下面文字翻譯成自然流暢的英文。" },
  ],
  genPresets: [
    { label: "續寫", instruction: "根據上文，自然地續寫下一段。" },
    { label: "補一段", instruction: "根據上文補一個相關的段落。" },
    { label: "整理要點", instruction: "把上文整理成條列要點（- ）。" },
    { label: "插入公式", instruction: "插入一個與上文相關的數學公式（用 $$...$$）。" },
  ],
  citeLatexCommand: "autocite",
  previewCiteStyle: "author-year",
  fontSize: 14,
  fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
  lineHeight: 1.6,
  snippets: [],
  defaultTemplate: "apj",
};

let current: NoteproConfig = JSON.parse(JSON.stringify(DEFAULT_CONFIG));

export function getConfig(): NoteproConfig { return current; }

/** Merge a partial config (only keys present override defaults). */
export function mergeConfig(partial: Partial<NoteproConfig>): void {
  current = { ...current, ...partial };
}
