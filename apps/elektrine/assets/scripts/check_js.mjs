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

const lifecycleRules = [
  {
    resource: "setInterval",
    acquire: /\bsetInterval\s*\(/g,
    release: /\bclearInterval\s*\(/g,
    message: "hooks that create intervals must clear them",
  },
  {
    resource: "MutationObserver",
    acquire: /\bnew\s+MutationObserver\s*\(/g,
    release: /\.disconnect\s*\(/g,
    message: "hooks that create MutationObserver instances must disconnect them",
  },
  {
    resource: "ResizeObserver",
    acquire: /\bnew\s+ResizeObserver\s*\(/g,
    release: /\.disconnect\s*\(/g,
    message: "hooks that create ResizeObserver instances must disconnect them",
  },
];

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

function countMatches(source, pattern) {
  return Array.from(source.matchAll(pattern)).length;
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

  if (displayPath.startsWith("js/hooks/")) {
    const globalListenerAdds = countMatches(
      source,
      /\b(?:window|document)\.addEventListener\s*\(/g,
    );
    const globalListenerRemoves = countMatches(
      source,
      /\b(?:window|document)\.removeEventListener\s*\(/g,
    );
    const allowsAppLifetimeListeners = source.includes(
      "js-check: allow-global-listener-singleton",
    );

    if (globalListenerAdds > globalListenerRemoves && !allowsAppLifetimeListeners) {
      failures += 1;
      process.stderr.write(
        `error: ${displayPath}: global window/document listeners must be removed or documented as an app-lifetime singleton\n`,
      );
    }

    for (const { acquire, release, message } of lifecycleRules) {
      if (countMatches(source, acquire) > 0 && countMatches(source, release) === 0) {
        failures += 1;
        process.stderr.write(`error: ${displayPath}: ${message}\n`);
      }
    }
  }
}

if (failures > 0) {
  process.stderr.write(`JavaScript check failed with ${failures} issue(s).\n`);
  process.exit(1);
}

process.stdout.write("JavaScript check passed.\n");
