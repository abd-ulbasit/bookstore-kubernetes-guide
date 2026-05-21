# Runbook — code rollback via Helm (CODE layer)

> When to reach for this: a workload deployed by a **raw Helm release**
> (not behind Argo CD; not behind an Argo Rollout) is regressing. This
> shape exists on the Bookstore Platform for **addons** and **third-
> party charts** on the cluster's platform-base path (kube-prometheus-
> stack, ingress-nginx, external-secrets, cert-manager) — i.e. the
> charts installed by `bootstrap-cluster.sh` before Argo CD takes over
> the app namespaces. The Helm release ledger (the `Secret` named
> `sh.helm.release.v1.<RELEASE>.v<N>`) holds the manifests + values for
> every revision. `helm rollback <RELEASE> <REVISION>` re-applies an
> old revision atomically. Time to mitigate: **1-3 minutes**.

## Pre-flight

1. **Confirm this is NOT an Argo CD-managed release.** `argocd app
   list | grep <RELEASE>` — if it appears, use `code-rollback-
   argocd.md` instead (Argo CD owns the release; Helm CLI changes
   would be reverted on the next sync).
2. **Schema-compat note.** This runbook covers addon/infrastructure
   charts (cert-manager, ExternalDNS, etc.) which typically don't
   ship app DB migrations. For app-code Helm releases that DO migrate
   schemas, run `code-rollback-argocd.md`'s Step 0 (schema-compat
   check) FIRST.
3. **Confirm the chart did NOT change CRDs.** `helm rollback` does
   **not** roll back CRDs (Helm treats CRDs as cluster-scoped, owned
   by the cluster operator). If a CRD upgrade landed in the bad
   release and the application now reads a removed field, you have a
   compatibility problem `helm rollback` will NOT solve.
4. **Confirm you know the last-known-good revision.** `helm history
   <RELEASE> -n <NAMESPACE>` lists them.

## Alert / trigger

- A page from an addon's alert: `KubeProxyDown`,
  `IngressNginxConfigReloadFailing`,
  `ExternalSecretsControllerNotReady`.
- A platform engineer's manual decision after upgrading a chart
  (`helm upgrade kube-prometheus-stack ...`) and seeing metric
  ingestion break.

## Step 1 — Check (< 60s)

```sh
# What's the current state of the release?
helm status kube-prometheus-stack -n prometheus-system
# NAME: kube-prometheus-stack
# LAST DEPLOYED: Wed May 20 14:22:13 UTC 2026
# NAMESPACE: prometheus-system
# STATUS: deployed
# REVISION: 14
# CHART: kube-prometheus-stack-58.2.0

# History — list revisions to identify the last good one.
helm history kube-prometheus-stack -n prometheus-system
# REVISION   UPDATED                    STATUS          CHART                        APP VERSION   DESCRIPTION
# 12         2026-05-15 09:11:04 UTC    superseded      kube-prometheus-stack-57.0.0 0.74.0        Upgrade complete
# 13         2026-05-18 14:05:33 UTC    superseded      kube-prometheus-stack-57.5.0 0.74.0        Upgrade complete  <- LAST KNOWN GOOD
# 14         2026-05-20 14:22:13 UTC    deployed        kube-prometheus-stack-58.2.0 0.75.0        Upgrade complete  <- the bad one
```

## Step 2 — Diagnose (< 2 min)

```sh
# What did the upgrade actually change?
helm get values kube-prometheus-stack -n prometheus-system --revision 13 > /tmp/r13.yaml
helm get values kube-prometheus-stack -n prometheus-system --revision 14 > /tmp/r14.yaml
diff -u /tmp/r13.yaml /tmp/r14.yaml | head -40

# What manifests did the chart render in each revision?
helm get manifest kube-prometheus-stack -n prometheus-system --revision 13 \
  | grep -E "^(kind|name):" | sort -u > /tmp/r13-objs.txt
helm get manifest kube-prometheus-stack -n prometheus-system --revision 14 \
  | grep -E "^(kind|name):" | sort -u > /tmp/r14-objs.txt
diff -u /tmp/r13-objs.txt /tmp/r14-objs.txt | head -40
# A new object in revision 14 -> a CRD or a default-disabled component
# was enabled; check whether the cluster has the prereqs.
```

If the diff shows a chart **version bump only** (the upstream chart
moved 57.5 → 58.2 and added incompatible defaults) — `helm rollback`
is the right tool. If the diff shows a values change you committed —
revert that change in your values-tracking repo too (Helm rollback is
not a values-source-of-truth update).

## Step 3 — Mitigate

### 3a. Roll back

```sh
helm rollback kube-prometheus-stack 13 \
  -n prometheus-system \
  --wait \
  --timeout 5m
# Rollback was a success! Happy Helming!
```

Flags:
- `--wait` — block until Kubernetes resources are ready (Service IPs
  assigned, Pods Ready). Default: false; **always set for production
  rollbacks**.
- `--timeout` — how long to wait. 5m is a sensible default for chart-
  level rollbacks; controllers settle in seconds, but the chart's
  `--wait` checks every Pod's ReadinessProbe.
- `--cleanup-on-fail` — if the rollback itself fails (e.g. one Pod
  fails its probe), delete the partially-rolled-back resources so a
  retry is clean.

### 3b. Verify

```sh
# History updated?
helm history kube-prometheus-stack -n prometheus-system
# REVISION 15 (the rollback gets a new revision number; it points at
# the manifests of revision 13)

# What's running?
kubectl -n prometheus-system get pods -l app.kubernetes.io/instance=kube-prometheus-stack
# All Pods on chart version 57.5.0 manifests.

# The previously-broken metric scrapes work?
kubectl -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 'up{job="kubelet"}'
# All "1" -> metric ingestion working.
```

### 3c. Sync the source-of-truth

If the Helm release is tracked in a values-repository (e.g. the
`platform-base` git repo), open a PR that reverts the values bump:

```sh
git -C ./platform-base checkout -b revert-kube-prometheus-stack-58.2.0
git revert <SHA-of-58.2.0-bump>
git push origin revert-kube-prometheus-stack-58.2.0
# Open PR; merge after review.
```

Without this step, the **next** `helm upgrade` (e.g. when someone re-
applies the platform-base path) will re-bump to 58.2.0 and break
again.

## Step 4 — Communicate

Same as the Argo CD runbook. Platform-base chart regressions are
typically P1 (one addon broken) or P0 (Prometheus down → blind on-
call).

## Step 5 — Postmortem

Mandatory questions for a Helm-rollback postmortem:

- **Why did we upgrade in production first?** Platform addons SHOULD
  be upgraded in dev → staging → prod with > 1h soak each;
  if not, → action item: add the upgrade gate to the CI pipeline.
- **Are we pinning chart versions?** A `helm upgrade --version
  ${CHART_VERSION}` is safer than `helm repo update + helm upgrade`
  (the latter pulls "latest"). → action item: pin in the values
  repo's `Chart.yaml` or with `--version`.
- **Was the chart's CHANGELOG read before upgrade?** Most chart-
  breakage rollbacks are postmortem'd to "the breaking-change note
  in the chart's CHANGELOG was missed". → action item: add a
  "CHANGELOG read?" checkbox to the upgrade PR template.

## Common false starts

- **`helm rollback` fails with "release: not found".** Wrong
  namespace — Helm releases are namespaced. Check `helm list -A | grep
  <RELEASE>` to find the right namespace.
- **`helm rollback` succeeded but a CRD is still wrong.** Helm does
  not roll back CRDs by default (see pre-flight). Manually fetch the
  old CRD definition from the chart at the target revision:
  ```sh
  helm fetch kube-prometheus-stack --version 57.5.0 --untar
  kubectl apply -f kube-prometheus-stack/crds/
  ```
- **`helm rollback` succeeded but Pods are stuck in
  `CreateContainerConfigError`.** A `ConfigMap`/`Secret` immutable
  flag (the chart sets `metadata.annotations.helm.sh/resource-policy:
  keep`) or a webhook (cert-manager, kyverno) is blocking. The
  rollback partial-applied; clean it up with `--cleanup-on-fail`.

## Related runbooks

- [`code-rollback-argocd.md`](code-rollback-argocd.md) — if Argo CD
  manages the release.
- [`config-rollback-argocd-app.md`](config-rollback-argocd-app.md) —
  if the bad change is a Helm values edit in git, not a chart-version
  bump.

## When this runbook last worked

| Date       | Release                       | Resolved by                | Notes |
|------------|-------------------------------|----------------------------|-------|
| 2026-05-12 | kube-prometheus-stack         | Step 3a (rollback 14 -> 13)| 58.2.0 changed default scrape interval; alerts noisy |
| 2026-03-30 | external-secrets              | Step 3a + 3c               | helm-managed CRD upgrade required separate `kubectl apply` |

> Stale after **90 days** without exercise.
