#!/usr/bin/env -S npx tsx
/**
 * cli.ts — Markdown -> LaTeX command-line driver, for end-to-end testing.
 *
 *   md2tex <input.md> [-o out.tex] [--template academic] [--bib refs.bib]
 *          [--templates-dir ./templates] [--title T] [--author A] [--date D]
 *          [--cjk]
 *
 * Writes the .tex (to --out or stdout). When citations are present and -o is
 * given, also writes `references.bib` next to the output and prints an asset
 * manifest to stderr so a build step (e.g. `tectonic out.tex`) can follow.
 */
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { convert } from "./index.js";
import type { ConvertOptions } from "./types.js";

function loadTemplatesDir(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    for (const file of readdirSync(dir)) {
      if (file.endsWith(".tex")) {
        out[basename(file, ".tex")] = readFileSync(join(dir, file), "utf8");
      }
    }
  } catch {
    // Directory missing -> rely on built-in fallback template.
  }
  return out;
}

function defaultTemplatesDir(): string {
  // src/latex/cli.ts -> repo-root/templates
  const here = dirname(fileURLToPath(import.meta.url));
  return resolve(here, "..", "..", "..", "templates");
}

function main(): void {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      out: { type: "string", short: "o" },
      template: { type: "string", short: "t" },
      "templates-dir": { type: "string" },
      bib: { type: "string" },
      "bib-backend": { type: "string" },
      title: { type: "string" },
      author: { type: "string" },
      date: { type: "string" },
      cjk: { type: "boolean" },
    },
  });

  const input = positionals[0];
  if (!input) {
    process.stderr.write("usage: md2tex <input.md> [options]\n");
    process.exit(2);
  }

  const source = readFileSync(input, "utf8");
  const templatesDir = values["templates-dir"] ?? defaultTemplatesDir();

  const opts: ConvertOptions = {
    templates: loadTemplatesDir(templatesDir),
  };
  if (values.template) opts.template = values.template;
  if (values.title) opts.title = values.title;
  if (values.author) opts.author = values.author;
  if (values.date !== undefined) opts.date = values.date;
  if (values.cjk) opts.cjk = true;
  if (values.bib) {
    opts.bib = { kind: "bibtex", text: readFileSync(values.bib, "utf8") };
  }
  const backend = values["bib-backend"];
  if (backend === "biber" || backend === "bibtex") opts.bibBackend = backend;

  const result = convert(source, opts);

  if (values.out) {
    writeFileSync(values.out, result.tex, "utf8");
    if (result.bib) {
      const bibPath = join(dirname(values.out), "references.bib");
      writeFileSync(bibPath, result.bib, "utf8");
      process.stderr.write(`wrote ${bibPath}\n`);
    }
    process.stderr.write(`wrote ${values.out}\n`);
  } else {
    process.stdout.write(result.tex);
  }

  if (result.assets.length) {
    process.stderr.write("assets:\n");
    for (const a of result.assets) {
      process.stderr.write(
        `  [${a.kind}] ${a.ref}${a.resolved ? "" : " (UNRESOLVED)"}\n`,
      );
    }
  }
  if (result.citationKeys.length) {
    process.stderr.write(`citations: ${result.citationKeys.join(", ")}\n`);
  }
}

main();
