# Bookstore Platform — feature flags

Self-hosted **Flagsmith** install + sample flag configs + Go SDK
integration patterns for the Bookstore Platform services. Introduced
in [Part 15 ch.08](../../../15-day-to-day-production-ops/08-feature-flags-and-dark-launches.md);
this directory is the reference implementation.

## Files

| File | What it is | When to touch |
|------|------------|---------------|
| [`flagsmith-helm-values.yaml`](flagsmith-helm-values.yaml) | Helm values for `flagsmith/flagsmith` (chart 0.39.1) | Updating the install (chart bumps; PSA changes; resources) |
| [`sample-flag-config.json`](sample-flag-config.json) | Six representative flags + four segments | Adding a new flag in IaC — commit the export here |
| [`catalog-go-sdk-integration.md`](catalog-go-sdk-integration.md) | How catalog (Go) consumes flags via OpenFeature + Flagsmith / LaunchDarkly | Onboarding a new service to feature flags |
| [`README.md`](README.md) | This file | Adding a new artifact to the directory |

## Decisions baked in

- **Self-hosted Flagsmith** is the default (data residency for EU
  tenants; no per-MAU pricing at platform scale). **LaunchDarkly**
  is the documented alternative for teams that explicitly choose
  SaaS to skip operational load. **Unleash** is mentioned as a
  Flagsmith-equivalent with the same trade-offs.
- **OpenFeature SDK** in every Go service. Vendor lock-in is avoided
  via the OpenFeature `Provider` abstraction; the Bookstore code
  never imports a vendor SDK directly.
- **Default-on-failure for kill switches.** Every flag call passes a
  safe default. If Flagsmith is unreachable, the default applies —
  kill switches default to "feature enabled" (the safe state).
- **Flag lifecycle: 30-day stale-flag policy.** Every flag has an
  owner + an `expected_removal_date`. Flags past their date show up
  in a weekly report; un-removed flags become tech-debt tickets.

## How the four flag use-cases map to files

| Use case | Sample flag | Note |
|----------|-------------|------|
| **Dark launch** | `catalog_v2_search_engine` | Deploy code dark; flip segments → 100% |
| **Migration canary** | `checkout_stripe_payment_intents_v2024_11` | 10% → 50% → 100% rollout |
| **A/B test** | `recommendations_ab_test_model_v3` | 33/33/33 split; time-boxed |
| **Kill switch** | `kill_switch_checkout`, `kill_switch_recommendations` | < 60s to disable |
| **Config flag** | `catalog_per_tenant_pagination_size` | Per-tenant value override |

## Where the secrets live

The Flagsmith **server-side environment keys** (per-env, per-provider)
are stored in **Vault** under
`kv/data/feature-flags/flagsmith/<env>` and `kv/data/feature-flags/
launchdarkly/<env>`. The Bookstore Go services pull them via
ExternalSecrets ([Part 15 ch.05](../../../15-day-to-day-production-ops/05-production-secrets-vault-eso.md)).

## Pinning + upgrades

- **Chart version**: pin `--version 0.39.1` (or whatever is current
  at install time). Floating versions cause silent drift.
- **Image tags**: pin `api.image.tag` and `frontend.image.tag` to
  matching versions; the chart's defaults may move.
- **Upgrade order**: dev → staging → prod with > 1h soak each. A
  Flagsmith API change has bitten teams that upgraded prod first.

## Related runbooks

- [`../runbooks/runbook-api-latency-p99.md`](../runbooks/runbook-api-latency-p99.md) —
  when a catalog regression is suspected, the Flagsmith kill switch
  is faster than rollback if the regression is config-driven.
- [`../rollback/code-rollback-rollouts.md`](../rollback/code-rollback-rollouts.md) —
  when a dark-launched code path regresses, the FIRST mitigation is
  flag flip (faster); the SECOND is Rollout abort.

## See also

- [Part 15 ch.08 — feature flags & dark launches](../../../15-day-to-day-production-ops/08-feature-flags-and-dark-launches.md) — chapter.
- [OpenFeature docs](https://openfeature.dev/) — the SDK abstraction.
- [Flagsmith docs](https://docs.flagsmith.com/) — the self-hosted
  platform.
