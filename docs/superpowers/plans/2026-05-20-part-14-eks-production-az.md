# Part 14 — "EKS in Production: A-Z" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan. Spec: `docs/superpowers/specs/2026-05-20-part-14-eks-production-az-design.md`.

**Goal:** Build Part 14 (12 chapters of EKS-in-production discipline) + round out the Terraform tree at `examples/bookstore-platform/terraform/` with Tier 1+2+3 additions from the post-smoke-test assessment.

**Architecture:** Proven pipeline (opus implementer → sonnet spec-review → sonnet code-quality-review → fix-loop). Continuous; no user check-ins unless BLOCKED.

**Tech Stack:** Terraform 1.10+ (use_lockfile native locking), AWS provider 5.95+ (or 6+ once available), EKS 1.35, Karpenter 1.6, AWS Budgets, infracost, GitHub Actions (OIDC trust), VPC endpoints, Graviton (arm64), Argo CD App-of-Apps, CNPG cross-region, AWS GuardDuty + Security Hub + Config.

---

## Phase 14-R — Terraform tree expansion (Tier 1+2+3)

Single batched dispatch. All additions are var-gated default-off where they cost money.

### Task 14-R.1 — Implementer dispatch
- [ ] Apply all 12 items from the spec's Tier 1+2+3 list (see spec §"Terraform-tree expansion").
- [ ] New files/sub-directories under `examples/bookstore-platform/terraform/`:
  - `cost-budgets.tf` (Tier 1 #4)
  - `addons.tf` updated (Tier 1 #2)
  - `eks.tf` updated (Tier 1 #1 — log retention)
  - `gp3-storageclass.tf` (Tier 1 #3 — kubectl_manifest)
  - `Makefile` updated (Tier 1 #5 — plan-cost target)
  - `.github/workflows/terraform.yml` (Tier 2 #6)
  - `vpc-endpoints.tf` (Tier 2 #7, var-gated)
  - `karpenter-graviton.tf` (Tier 2 #8, var-gated)
  - `argocd-bootstrap.tf` (Tier 2 #9, var-gated)
  - `multi-region/` sub-directory (Tier 2 #10 — scaffolding + module wrapper)
  - `drift-check/` sub-directory (Tier 3 #12 — sample workflow + atlantis.yaml + DRIFT.md)
- [ ] New sibling tree `examples/bookstore-platform/terraform-account-baseline/` (Tier 3 #11):
  - `versions.tf`, `variables.tf`, `locals.tf`, `outputs.tf`
  - `guardduty.tf`, `securityhub.tf`, `config.tf`, `cloudtrail.tf`, `iam-access-analyzer.tf`
  - `Makefile`, `README.md` (~150 lines)
- [ ] Variables (`variables.tf`): add `enable_budget_alarm`, `budget_alarm_email`, `monthly_budget_usd`, `enable_vpc_endpoints`, `enable_graviton_pool`, `enable_argocd_bootstrap`, `argocd_repo_url`, `cloudwatch_log_group_retention_in_days`. All default-false / default-empty for cost-bearing items.
- [ ] README updates: new "Production extensions" section documenting each enable flag.

### Task 14-R.2 — Spec-review
- [ ] Independent verification of: var-gated default-off invariant; no breaking changes to existing variables; `terraform fmt -check` + `validate` exit 0; Tier 1+2+3 coverage complete; `account-baseline/` is genuinely separate (not depended on by the main tree).

### Task 14-R.3 — Code-quality-review
- [ ] Craft + IAM scope + cost-trap detection + multi-region scaffolding quality (the cross-region wiring should be coherent enough that a user can extend it, even if not fully wired).

### Task 14-R.4 — Fix-loop
- [ ] Until both reviews APPROVED.

---

## Phase 14a — Chapters 14.01–14.04

### Task 14a.1 — Implementer
- [ ] 4 chapters at `full-guide/14-eks-in-production-a-to-z/`:
  - `01-terraform-state-in-production.md`
  - `02-eks-cluster-lifecycle.md`
  - `03-eks-addon-management.md`
  - `04-storage-classes-and-ebs.md`
- [ ] Each follows the 9-section anatomy.
- [ ] Cross-references to Parts 00–13 + Phase 14-R Terraform additions.

### Task 14a.2 — Spec-review
- [ ] 9-anatomy, content coverage (matches spec §"Chapter list" 14.01–14.04), Mermaid validity, link resolution, no machine leaks.

### Task 14a.3 — Code-quality-review
- [ ] Prose voice (matches Part 13's), deepen-don't-duplicate discipline, Production notes pointed, Quick Reference yes/no checklists.

### Task 14a.4 — Fix-loop

---

## Phase 14b — Chapters 14.05–14.08

### Task 14b.1 — Implementer
- [ ] 4 chapters:
  - `05-logging-and-metrics-cost.md`
  - `06-cost-guardrails.md`
  - `07-infrastructure-cicd-and-drift.md`
  - `08-vpc-endpoints-and-egress.md`

### Task 14b.2-4 — Spec-review + code-quality + fix-loop

---

## Phase 14c — Chapters 14.09–14.12

### Task 14c.1 — Implementer
- [ ] 4 chapters:
  - `09-arm-graviton-on-eks.md`
  - `10-gitops-bootstrap-fresh-cluster.md`
  - `11-multi-region-active-active-cloud.md`
  - `12-cross-region-dr-account-baseline-90-day-runbook.md` (capstone shape)

### Task 14c.2-4 — Spec-review + code-quality + fix-loop

---

## Phase 14d — Finalize

### Task 14d.1
- [ ] Append Part 14 TOC section to `full-guide/README.md`.
- [ ] Update `appendix/B-glossary.md` intro to "Parts 00–14 (98 chapters)" + ~30 new entries.
- [ ] Append Part 14 section to `appendix/D-further-reading.md`.
- [ ] Re-scan all 5 appendix intros for stale chapter counts.
- [ ] 14-check guide-wide consistency re-proof (helm 49 / kustomize 45/49/48 / mermaid valid / no leaks / link graph 0 broken / placeholders uppercase / etc.).

---

## Phase 14e — Final audit

### Task 14e.1
- [ ] Independent audit subagent (opus) with: concern resolution ledger (every Phase 14 reviewer concern verified in live files); 14-check hard-invariant re-proof; spot-check 4 random chapters for anatomy + voice + links + Mermaid; verify the production-A-Z arc lands; SHIP_IT|SHIP_WITH_NOTES|DO_NOT_SHIP verdict.

---

## Acceptance for the entire Part 14 build

- Phase 14-R passes review-loops; Terraform tree has all 12 additions; `terraform validate` exit 0.
- Phases 14a/b/c each have all 12 chapters spec-reviewed + code-quality-reviewed + fix-loop closed.
- Phase 14d passes the 14-check consistency pass.
- Phase 14e returns SHIP_IT (or SHIP_WITH_NOTES with notes the user accepts).

---

## ADDENDUM (2026-05-20, mid-build) — 5 new chapters + Tier 4 + 2 new phases

Spec addendum at the same date adds 5 chapters (14.12–14.16) and Tier 4 Terraform items. Total Part 14 = **17 chapters**; build is **8 phases**.

### Revised phase map

- **Phase 14-R** — Tier 1+2+3+**4** Terraform (one batched dispatch; Tier 4 = Velero, Falco, Kyverno image-signing, Cilium .example)
- Phase 14a — ch.14.01–14.04 (unchanged)
- Phase 14b — ch.14.05–14.08 (unchanged)
- Phase 14c — ch.14.09–14.12 (Graviton / GitOps / multi-region / **supply chain**)
- **Phase 14d (NEW)** — ch.14.13–14.16 (runtime defense / Velero / Cilium / DX) — implementer + spec-review + code-quality-review + fix-loop
- **Phase 14e (NEW)** — ch.14.17 capstone (cross-region DR + AWS account baseline + 90-day runbook) — single-chapter dispatch + pipeline
- Phase 14f — Finalize (was 14d): README Part 14 TOC + appendix B intro to "Parts 00-14 (**103 chapters**)" + appendix D Part 14 section + 14-check guide-wide consistency
- Phase 14g — Final audit (was 14e): independent verifier + SHIP_IT

Chapter count: **103** (was 86 at end of Part 13; +17 from Part 14).

### Phase 14d task detail

- 4 chapters at `full-guide/14-eks-in-production-a-to-z/{13-runtime-defense-and-container-security,14-backup-and-restore-velero,15-cilium-ebpf-on-eks,16-developer-experience-for-k8s-teams}.md`
- 9-section anatomy.
- Cross-references to: 05 ch.03 (cosign), 11 ch.04 (mesh), 11 ch.07 (Chaos Mesh), 13 ch.07 (edge security), Phase 14-R Tier 4 Terraform.
- Implementer → spec-review → code-quality-review → fix-loop.

### Phase 14e task detail

- 1 chapter at `full-guide/14-eks-in-production-a-to-z/17-cross-region-dr-account-baseline-90-day-runbook.md`
- Capstone shape: H1 + 1-line summary + 8 standard H2s + "What we did not build" + "Closing the production-A-Z thread" (so 10 H2s total, matching Part 12 ch.08 and Part 13 ch.12).
- The "Closing the production-A-Z thread" section is the through-line of the ENTIRE guide, since this is the new last chapter.

---

## ADDENDUM 2 (2026-05-21) — Part 15 phases added

Part 14 a–g continues. After Part 14 closes, Part 15 begins:

| Phase | Content |
|-------|---------|
| 15-R | Terraform tree additions: `vault.tf` (var-gated Helm), Vault Terraform provider config example |
| 15a | Chapters 15.01–15.03 (lifecycle / app CI/CD / signing) + `examples/bookstore-platform/ci/` |
| 15b | Chapters 15.04–15.06 (multi-env / secrets / progressive delivery) + `examples/bookstore-platform/vault/` |
| 15c | Chapters 15.07–15.09 (rollback / feature flags / hotfix) + `examples/bookstore-platform/{rollback,feature-flags}/` |
| 15d | Chapters 15.10–15.11 (incident response / day-to-day ops) + `examples/bookstore-platform/incident/` |
| 15e | Chapter 15.12 capstone (90-day production ownership) |
| 15f | Finalize: README Part 15 TOC + appendix B intro to **Parts 00-15 (115 chapters)** + appendix D Part 15 section + 14-check guide-wide consistency |
| 15g | Final cross-Part audit (Parts 14+15 combined) + SHIP_IT verdict |

Total guide arc at end: **Parts 00-15 / 115 chapters / 4 example trees (canonical bookstore + platform v2 + terraform infra + terraform-account-baseline)**.

After Phase 15g returns SHIP_IT, run `pmset sleepnow` per user's deferred end-of-run instruction.
