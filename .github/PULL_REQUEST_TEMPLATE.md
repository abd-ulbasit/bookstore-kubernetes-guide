<!-- Thanks for the contribution. A few prompts to keep the PR small + reviewable. -->

## What does this change?

<!-- One paragraph. What did you change, where, and why now? -->

## Type of change

<!-- Tick all that apply. -->

- [ ] Bug fix (broken diagram / dead link / wrong command / version drift)
- [ ] Content correction (technical inaccuracy)
- [ ] New chapter or section (within the existing Part structure)
- [ ] Tooling / CI improvement
- [ ] Refactor (no functional change to text or examples)
- [ ] Other:

## Linked issue

<!-- e.g. Closes #42, Fixes #17, Related to #23 -->

## How I verified

<!-- Commands run, screenshots if visual. At minimum: -->

- [ ] `mkdocs build --strict` — clean build
- [ ] `node .github/scripts/validate-mermaid.mjs full-guide` — every block parses
- [ ] Relevant `helm lint` / `helm template` / `kubectl kustomize` / `terraform validate` — all pass (which ones apply depends on what you touched)

## Cross-references

<!-- If this changes a manifest count, an example-tree path, or a primitive
     name cited from multiple chapters, list the chapters that needed an
     update and confirm they got one. -->

## Checklist before merge

- [ ] One concern per PR — if I touched more than three Parts I split this
- [ ] Hard invariants preserved (Helm 49 / Kustomize 45-49-48 / `<UPPERCASE>` placeholders / no machine-specific paths)
- [ ] Self-reviewed the diff one more time
