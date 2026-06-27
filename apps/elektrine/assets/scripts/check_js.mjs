import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = dirname(dirname(fileURLToPath(import.meta.url)));
const jsDir = join(rootDir, "js");

const bannedPatterns = [
  {
    pattern: /\bdebugger\b/,
    message: "debugger statements should not be committed",
  },
  {
    pattern: /\bconsole\.log\s*\(/,
    message: "use intentional console.warn/error or remove debug logging",
  },
  {
    pattern: /(oklch|hsl)\(var\(--/,
    message: "use public --color-* theme tokens instead of DaisyUI internals",
  },
  {
    pattern: /fallback-b[1-3c]\b/,
    message: "use public --color-* theme tokens instead of fallback base tokens",
  },
];

const relativeImportPattern =
  /(?:import|export)\s+(?:[\s\S]*?\s+from\s+)?["'](\.{1,2}\/[^"']+)["']/g;

const lineBudgets = new Map([
  ["js/hooks/chat_hooks.js", 2600],
  ["js/hooks/chat_voice_recorder_hook.js", 200],
  ["js/hooks/mailbox_private_storage_hooks.js", 1500],
  ["js/hooks/timeline_hooks.js", 1500],
  ["js/hooks/ui_hooks.js", 1450],
  ["js/hooks/email_hooks.js", 1200],
  ["js/hooks/proof_graph_hook.js", 1000],
]);

function jsFiles(dir) {
  return readdirSync(dir)
    .flatMap((entry) => {
      const path = join(dir, entry);
      const stat = statSync(path);

      if (stat.isDirectory()) return jsFiles(path);
      if (entry.endsWith(".js")) return [path];
      return [];
    })
    .sort();
}

function resolveRelativeImport(file, specifier) {
  const basePath = join(dirname(file), specifier);
  const candidates = [basePath, `${basePath}.js`, join(basePath, "index.js")];

  return candidates.find((candidate) => existsSync(candidate));
}

let failures = 0;

for (const file of jsFiles(jsDir)) {
  const displayPath = relative(rootDir, file);
  const syntax = spawnSync(process.execPath, ["--check", file], {
    encoding: "utf8",
  });

  if (syntax.status !== 0) {
    failures += 1;
    process.stderr.write(`error: ${displayPath} failed node --check\n`);
    process.stderr.write(syntax.stderr || syntax.stdout);
    continue;
  }

  const source = readFileSync(file, "utf8");
  const lineBudget = lineBudgets.get(displayPath);

  if (lineBudget) {
    const lineCount = source.split(/\r?\n/).length;

    if (lineCount > lineBudget) {
      failures += 1;
      process.stderr.write(
        `error: ${displayPath}: ${lineCount} lines exceeds JS maintainability budget of ${lineBudget}\n`,
      );
    }
  }

  for (const { pattern, message } of bannedPatterns) {
    if (!pattern.test(source)) continue;

    failures += 1;
    process.stderr.write(`error: ${displayPath}: ${message}\n`);
  }

  for (const match of source.matchAll(relativeImportPattern)) {
    const specifier = match[1];

    if (!resolveRelativeImport(file, specifier)) {
      failures += 1;
      process.stderr.write(`error: ${displayPath}: unresolved relative import ${specifier}\n`);
    }
  }

  if (
    displayPath.startsWith("js/hooks/") &&
    source.includes("mounted()") &&
    source.includes("addEventListener(") &&
    !source.includes("destroyed()")
  ) {
    failures += 1;
    process.stderr.write(
      `error: ${displayPath}: hooks that attach event listeners in mounted() must define destroyed()\n`,
    );
  }
}

if (failures > 0) {
  process.stderr.write(`JavaScript check failed with ${failures} issue(s).\n`);
  process.exit(1);
}

process.stdout.write("JavaScript check passed.\n");
