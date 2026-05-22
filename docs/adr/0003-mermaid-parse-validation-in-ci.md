# 0003 — Real `mermaid.parse()` in CI over regex heuristics

* **Status:** Accepted
* **Date:** 2026-05-21
* **Deciders:** abd-ulbasit

## Context

`mkdocs build --strict` does **not** validate Mermaid diagrams.
Mermaid runs in the reader's browser at view-time, so a syntactically
broken `\`\`\`mermaid` block compiles, ships, deploys to Pages, and only
surfaces as the "Syntax error in text" red overlay to the *reader*.

Our CI originally tried to catch this with a Python regex job that
checked: (a) the first word of each block is a valid header
(`flowchart`, `sequenceDiagram`, …), (b) `timeline` doesn't appear,
(c) no literal `\n` in node text. This heuristic missed 11 real syntax
errors that the user later reported via a screenshot — including `;`
parsed as a sequence-diagram statement terminator, `(` inside an
unquoted edge label, and `.` inside a dotted-edge label.

## Decision

We will validate every `\`\`\`mermaid` block in `full-guide/` by feeding
it to **Mermaid's own parser** (`mermaid.parse()` from the
`mermaid@10.9.1` npm package — the same version production renders
with), inside a jsdom shim so it runs headless in CI in seconds. The
script lives at `.github/scripts/validate-mermaid.mjs` and runs as a
required step in `.github/workflows/docs.yml` **before** `mkdocs
build`. A literal `\n` in a Mermaid block also hard-fails (it renders
as the text "\n", not a line break — well-known foot-gun).

## Consequences

* **Good:** Every push to `main` and every PR catches every syntax
  error the production renderer would catch, before deploy. Zero
  false-positives observed in the 139 blocks the guide currently has.
* **Good:** Adds ~10 s to the build (npm install of `mermaid` + `jsdom`,
  then a few hundred parses). Negligible.
* **Good:** Pinning to the exact production version means the
  CI-vs-production parser cannot diverge silently.
* **Bad:** Adds a Node.js dependency to a Python-tooled site. The
  `node_modules/` is gitignored and only ever installed in CI.
* **Bad:** Requires bumping the pinned mermaid version when MkDocs
  Material upgrades its bundled version. Manageable: one number in two
  places.
* **Follow-up:** Consider extending the same pattern to an ASCII-art
  alignment validator (the `│`-column-drift detector that surfaced 8
  misaligned diagrams in May 2026).

## Alternatives considered

* **Regex heuristics.** Tried first; missed 11 real bugs. Rejected.
* **Headless Chromium via puppeteer.** Heavier (~150 MB Chromium
  download), slower (~30 s startup), no benefit over the parse-only
  approach. Rejected.
* **Leave validation to MkDocs Material when it lands** *(future)*.
  Material may add a build-time Mermaid check eventually. Until it
  does, this is the cleanest local fix.

## References

* `.github/scripts/validate-mermaid.mjs` — the validator.
* `.github/workflows/docs.yml` — the CI wiring.
* Mermaid 10.9.1 release notes for syntax quirks.
