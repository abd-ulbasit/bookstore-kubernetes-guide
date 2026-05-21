// Validate every ```mermaid block in full-guide/*.md against the same parser
// version production uses (mermaid 10.9.1, configured in mkdocs.yml). Uses
// mermaid.parse() inside a jsdom shim — no Chromium needed, runs in seconds.
//
// Catches syntax errors that mkdocs build does NOT catch (mermaid runs in the
// browser at view-time, so invalid blocks slip through the build and only
// surface as "Syntax error in text" to the reader).
//
// Run locally:
//   npm install --no-save mermaid@10.9.1 jsdom
//   node .github/scripts/validate-mermaid.mjs full-guide
//
// In CI: docs.yml installs mermaid + jsdom in a temp dir and invokes this.

import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!DOCTYPE html><html><body></body></html>", {
  url: "http://localhost/",
});
// Node 22+ has read-only globals; install via defineProperty.
for (const key of ["window", "document", "HTMLElement", "SVGElement",
                   "Element", "Node", "DOMParser", "XMLSerializer"]) {
  Object.defineProperty(globalThis, key,
    { value: dom.window[key], writable: true, configurable: true });
}
Object.defineProperty(globalThis, "navigator",
  { value: dom.window.navigator, writable: true, configurable: true });
globalThis.requestAnimationFrame = (cb) => setTimeout(cb, 0);

const mermaid = (await import("mermaid")).default;
mermaid.initialize({ startOnLoad: false });

const ROOT = process.argv[2] ?? "full-guide";
const PATTERN = /^```mermaid\s*\n([\s\S]*?)^```/gm;

function* walk(dir) {
  for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, f.name);
    if (f.isDirectory()) yield* walk(p);
    else if (f.name.endsWith(".md")) yield p;
  }
}

const failures = [];
let total = 0;

for (const p of walk(ROOT)) {
  const text = fs.readFileSync(p, "utf8");
  // Build a line index so we can report file:line for each block.
  const lineStarts = [0];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\n") lineStarts.push(i + 1);
  }
  const lineOf = (off) => {
    let lo = 0, hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= off) lo = mid; else hi = mid - 1;
    }
    return lo + 1;
  };

  let m;
  PATTERN.lastIndex = 0;
  while ((m = PATTERN.exec(text)) !== null) {
    total++;
    const body = m[1];
    const line = lineOf(m.index);

    // Hard-fail on literal "\n" — mermaid 10.x renders it as the text "\n",
    // not as a line break. The guide invariant is to use <br/> instead.
    if (body.includes("\\n")) {
      failures.push({ path: p, line, msg: "literal \\n in block; use <br/> instead", body });
      continue;
    }

    try {
      await mermaid.parse(body);
    } catch (err) {
      const msg = (err?.message ?? String(err)).split("\n").slice(0, 6).join("\n");
      failures.push({ path: p, line, msg, body });
    }
  }
}

console.log(`\n=== ${total} mermaid blocks scanned; ${failures.length} failed ===\n`);
for (const { path: p, line, msg, body } of failures) {
  console.log(`--- ${p}:${line} ---`);
  console.log(msg);
  body.split("\n").slice(0, 4).forEach((bl, i) => {
    console.log(`  ${line + 1 + i}: ${bl}`);
  });
  console.log("");
}
process.exit(failures.length ? 1 : 0);
