# About this guide

This is *The Bookstore Guide* — a hands-on Kubernetes learning resource that
takes a reader from container fundamentals to running multi-region
production platforms across 16 Parts and 115 chapters, anchored on one
evolving microservices application called *Bookstore*. Concepts compound
instead of resetting per topic: every chapter's hands-on section advances
the *same* app.

## Author

Maintained by **[abd-ulbasit](https://github.com/abd-ulbasit)**. The guide
is the result of an unusually disciplined build pipeline — every Part went
through a spec → plan → implement → review cycle with separate reviewers
for spec compliance and code quality (see
[ADR 0002](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/blob/main/docs/adr/0002-multi-agent-fix-loop.md)
for the methodology). The repo and the live site are both MIT-licensed and
open to contributions.

## What this guide is

- **Zero-to-production, and deep.** Assumes *no* prior Kubernetes knowledge.
  Internals are explained ("how it works under the hood"), not just "what
  to type." Containers are taught from first principles in Part 00.
- **One worked example throughout.** Every primitive is introduced because
  the Bookstore needs it next, then applied to it immediately. The four
  example trees (`bookstore/`, `bookstore-platform/`,
  `bookstore-platform/terraform/`, `terraform-account-baseline/`) are
  versions of the same application at different points along the arc.
- **Locally reproducible, free.** Parts 00–13 run entirely on local
  **kind**/`k3d` clusters with only open-source tooling. Parts 14–15 add a
  Terraform tree that was [live-smoke-tested on AWS EKS](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/blob/main/docs/lessons-from-smoke-test.md)
  for ~$0.20 — every cost-bearing variable defaults to off.

## What this guide isn't

- A certification cram sheet. (Cheat-sheet content lives in
  [Appendix A](appendix/A-kubectl-cheatsheet.md); the guide as a whole is
  about durable mental models, not exam tricks.)
- An opinion-free survey of every CNCF project. The guide opinionatedly
  picks **one** tool per concern and explains the trade-offs. The reader
  who wants a comparison shop should look elsewhere.
- A static snapshot. CI enforces hard invariants on every push: manifest
  counts, Mermaid validity, Terraform shape, leak-scan, link-check. The
  guide rots if it isn't actively maintained — the gates are how I notice.

## How to engage

- **Reading questions / clarifications:** [GitHub Discussions](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/discussions)
- **Bug reports / corrections:** [GitHub Issues](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/issues)
- **Security findings:** see [`SECURITY.md`](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/blob/main/SECURITY.md)
- **Contributing:** see [`CONTRIBUTING.md`](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/blob/main/CONTRIBUTING.md)

## Acknowledgements

Built on the shoulders of the Kubernetes / CNCF / HashiCorp / AWS / Mermaid
/ MkDocs Material communities, all of whom publish documentation that this
guide cites heavily and depends on. The methodology side draws on Michael
Nygard's *Documenting Architecture Decisions* (the ADR format used in
[`docs/adr/`](https://github.com/abd-ulbasit/bookstore-kubernetes-guide/tree/main/docs/adr)).
