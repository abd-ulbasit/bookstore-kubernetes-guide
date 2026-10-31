# Contributing

Thanks for considering a contribution. This repo is a learning artifact, but
the same disciplines that keep production codebases healthy keep a teaching
codebase from rotting: small focused changes, runnable examples, CI as the
arbiter of truth.

## Quick orientation

- **Where to read first:** [`README.md`](README.md) for the lay of the land,
  then the [live site](https://abd-ulbasit.github.io/bookstore-kubernetes-guide/)
  for the actual reading experience.
- **Where the design rationale lives:** [`docs/adr/`](docs/adr/) for the
  load-bearing decisions.
- **Where the CI is wired:** [`.github/workflows/`](.github/workflows/).
- **The rules every chapter and manifest follows:**
  [`docs/security-first-authoring.md`](docs/security-first-authoring.md). The
  guide is security-first. Every workload carries the hardened baseline from
  its first manifest, in a namespace that enforces `restricted`, and the
  security gates in that file's section 8 enforce it. Read it before you add
  a manifest or a chapter.

## Open in Codespaces

The fastest path to a working dev environment is the *Open in Codespaces*
badge in the README. Locally, a `python3 -m venv && pip install -r
requirements.txt` plus a `kubectl`/`helm`/`terraform`/`kind` install matching
the versions in `.devcontainer/devcontainer.json` is the manual equivalent.

## Workflow

1. **Open an issue first** for anything beyond a typo or a small wording
   tweak. Issues are how this project tracks intent.
2. **Branch off `main`.** Branch naming: `fix/short-name`,
   `feat/short-name`, `docs/short-name`.
3. **Write the change small.** One concern per PR. If you've touched more
   than three Parts, that's almost certainly two PRs.
4. **Run CI locally before pushing** to keep the feedback loop short:
   ```bash
   mkdocs build --strict
   node .github/scripts/validate-mermaid.mjs full-guide
   helm lint full-guide/examples/bookstore/helm/bookstore
   make gates-registry
   make gates-static SCOPE=05-security/02-pod-security.md   # your chapter
   ```
   `make gates-static` needs Trivy, and `make gates-admission` needs a kind
   cluster. Every chapter and example tree fails CI on a violation, except
   Parts 16 and 17, which are outlines whose labs wait
   (`.github/security-gates-report-only.txt`).
5. **Open the PR**, fill in the template, link the issue.

## What gets accepted

* **Bug fixes:** broken diagrams, dead links, wrong commands, version drift
  in cited tools.
* **Content corrections:** technical inaccuracies (always welcome — open
  with a citation when possible).
* **Chapter additions:** new chapters within the existing Part structure,
  if they fill a documented gap. **Don't** add chapters that duplicate
  existing content with a different framing — the guide's discipline is
  "deepen, don't duplicate."
* **Tooling improvements:** CI checks, validation scripts, the build
  pipeline.

## What gets pushed back

* **Restructuring of the Part skeleton** (Parts 00 to 17) without a
  discussion-issue first. The Part ordering is itself a load-bearing decision; restructuring
  it ripples through every cross-reference.
* **Single-PR rewrites of multiple chapters.** Even if the rewrite is
  better, the review surface is too large. The exception is a Part-wide
  change that the security-first design calls for, such as a baseline fix
  applied to every manifest, which a maintainer has asked for.
* **Tool-version bumps without a corresponding chapter update.** The text
  cites specific versions; CI enforces the count invariants. They have to
  move together.

## Reporting bugs / suggesting content

Open an issue using the templates in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).
For sensitive matters (e.g., a real-secret leak you spotted), see
[`SECURITY.md`](SECURITY.md) instead — please don't open a public issue.

## Code of conduct

This project follows the [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)
informally. Be kind. Disagree on substance, not on people.
