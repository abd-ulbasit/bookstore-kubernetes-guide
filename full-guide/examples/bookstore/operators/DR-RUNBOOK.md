# Bookstore — Disaster Recovery Runbook

> Companion to [Part 08 ch.02 — Backup and disaster
> recovery](../../../08-day-2-operations/02-backup-and-dr.md). This is the
> ordered, runnable runbook the chapter references. It assumes the backup
> posture that chapter establishes:
>
> - **Desired state in Git** — the Bookstore's Kustomize overlays reconciled by
>   Argo CD ([Part 07 ch.04](../../../07-delivery/04-gitops-argocd.md)). This is
>   the *easiest* "restore": re-point Argo at Git and the declarative state
>   rebuilds itself.
> - **etcd snapshots** — cluster state, on a self-managed control plane
>   (`etcdctl snapshot save`). On managed clusters etcd is the provider's; you
>   cannot `etcdctl` it (and do not need to).
> - **Velero** — namespaced backup of `bookstore` **including the Postgres PV**
>   via CSI VolumeSnapshot, with the pre-backup Postgres CHECKPOINT consistency
>   hook ([`velero-backup.yaml`](velero-backup.yaml) /
>   [`velero-schedule.yaml`](velero-schedule.yaml)).
>
> **The core insight:** GitOps recovers the *declarative* state for free; only
> the **data** (the Postgres PVC) genuinely needs a data backup. Every scenario
> below is a different slice of that.

## Targets (set these per environment; values below are the lab defaults)

| Metric | Definition | Lab default | Driver |
|---|---|---|---|
| **RPO** (Recovery Point Objective) | Max acceptable *data loss* | ≈ backup interval (Schedule `0 2 * * *` → up to 24h; tighten to `0 */6 * * *` → 6h) | Velero `Schedule` cadence + WAL archiving if using an operator (ch.05) |
| **RTO** (Recovery Time Objective) | Max acceptable *time to restore* | ≈ minutes (declarative) + restore + app readiness | GitOps re-sync speed + Velero restore + `kubectl wait` |

> RPO is set by **how often you back up**; RTO by **how fast you can restore**.
> A crash-consistent CSI snapshot restores *exactly the snapshot instant*
> (including any corruption that existed then) — for sub-snapshot RPO you need
> WAL/PITR, which is the operator/managed-DB story
> ([ch.05](../../../08-day-2-operations/05-operators-and-crds.md)).

---

## Scenario 1 — A workload was deleted/corrupted (lost a Deployment)

*Example: someone `kubectl delete deploy catalog -n bookstore`, or a bad
`kubectl edit` wedged it.* **No data is lost** — only declarative state.

- **RPO:** 0 (no data involved). **RTO:** one Argo reconcile (~minutes).

1. Confirm scope — only declarative objects affected, PVC intact:
   ```sh
   kubectl get deploy,statefulset -n bookstore
   kubectl get pvc -n bookstore               # data-postgres-0 STILL Bound
   ```
2. **GitOps path (preferred — no manual apply):** Argo CD with
   `selfHeal: true` re-creates it automatically; force it if impatient:
   ```sh
   argocd app sync bookstore-prod
   argocd app get bookstore-prod              # Synced / Healthy
   ```
3. **Non-GitOps fallback:** re-apply the manifest (idempotent):
   ```sh
   kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
   kubectl rollout status deploy/catalog -n bookstore
   ```
4. **Validate:**
   ```sh
   kubectl wait --for=condition=available deploy/catalog -n bookstore --timeout=120s
   kubectl run dr-check --rm -it --restart=Never -n bookstore \
     --image=curlimages/curl:8.10.1 \
     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"dr-check","image":"curlimages/curl:8.10.1","command":["sh","-c","curl -fsS http://catalog.bookstore.svc.cluster.local/healthz && echo OK"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'
   #   ^ restricted-compliant overrides — the bookstore ns enforces PSA
   #     `restricted`, so even a throwaway check pod must comply.
   ```

---

## Scenario 2 — The Postgres PVC was lost/corrupted (data loss)

*Example: the `data-postgres-0` PVC/PV was deleted, the disk failed, or a
`DROP TABLE` ran.* **This is the real DR case** — declarative state is fine,
**data is gone**, and only a *data backup* recovers it.

- **RPO:** up to the Velero `Schedule` interval (lab: ≤24h). **RTO:** restore
  time + Postgres readiness (lab: ~minutes on a small DB).

1. **Stop writers** so nothing writes to a half-restored DB, then **stop
   Postgres** so the RWO PVC is unmounted before the restore:
   ```sh
   kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
     -n bookstore --replicas=0
   # data-postgres-0 is ReadWriteOnce — the node-agent restore pod cannot
   # mount it while postgres-0 holds it. Scale the StatefulSet to 0 and wait
   # for the pod to be gone before restoring:
   kubectl scale statefulset/postgres -n bookstore --replicas=0
   kubectl wait --for=delete pod/postgres-0 -n bookstore --timeout=120s
   ```
2. **Restore the Postgres data from the latest Velero backup.** Velero
   recreates the PVC's contents from the backup. Restore *only* the data
   (the declarative objects come back via GitOps, not from the backup):
   ```sh
   velero backup get                                  # pick the newest good one
   # Do NOT `--selector app=postgres`: the StatefulSet controller does not
   # copy pod-template labels onto the volumeClaimTemplate PVC, so
   # data-postgres-0 has NO app=postgres label — a label-selected restore
   # silently SKIPS the PVC and "succeeds" recovering nothing. Scope by
   # namespace + resource kind instead:
   velero restore create bookstore-pgrestore \
     --from-backup bookstore-daily-<TIMESTAMP> \
     --include-namespaces bookstore \
     --include-resources persistentvolumeclaims,persistentvolumes
   velero restore describe bookstore-pgrestore --details   # Phase: Completed
   ```
   *(Crash-consistent restore = state AS OF the snapshot. The pre-backup
   CHECKPOINT hook ensured it was a clean flush. Sub-snapshot RPO requires
   WAL/PITR — the operator/managed-DB story, ch.05.)*
3. **Bring Postgres back** on the restored PVC, then writers:
   ```sh
   kubectl scale statefulset/postgres -n bookstore --replicas=1
   kubectl rollout status statefulset/postgres -n bookstore
   kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
     -n bookstore --replicas=2
   ```
4. **Validate the data is actually back** (postgres image has a shell):
   ```sh
   kubectl exec -n bookstore postgres-0 -- \
     psql -U bookstore -d bookstore -c '\dt'          # tables present
   kubectl exec -n bookstore postgres-0 -- \
     psql -U bookstore -d bookstore -c 'SELECT count(*) FROM books;'
   ```

---

## Scenario 3 — The entire cluster is gone (total loss)

*Example: the cluster was deleted, the region failed, an upgrade bricked it
([ch.01](../../../08-day-2-operations/01-cluster-lifecycle.md)).* Rebuild from
**Git (declarative) + Velero (data)**, optionally **etcd snapshot** if you must
resurrect the *same* self-managed control plane rather than a fresh one.

- **RPO:** Velero `Schedule` interval for data; 0 for declarative (it is in
  Git). **RTO:** new-cluster provision + Argo bootstrap + data restore.

1. **Stand up a new cluster** ([ch.01](../../../08-day-2-operations/01-cluster-lifecycle.md)):
   kind locally, or the provider/kubeadm in production. Install the CSI driver
   + snapshot CRDs and Velero (same `BackupStorageLocation` — the backups must
   outlive the cluster, which is *why* they live in an object store).
2. **Recover the declarative state from Git** (no cluster snapshot needed —
   this is the GitOps DR property):
   ```sh
   # install Argo CD, then TWO applies rebuild the whole app from Git:
   kubectl apply -n argocd -f examples/bookstore/argocd/00-appproject.yaml
   kubectl apply -n argocd -f examples/bookstore/argocd/01-app-of-apps.yaml
   #   → Argo recreates Namespace (PSA labels), Deployments, Services,
   #     NetworkPolicies, the StatefulSet, … everything declarative.
   ```
   *(Alternative for a self-managed control plane: restore the etcd snapshot —
   `etcdctl snapshot restore` into a fresh data-dir, repoint the new
   apiserver. This resurrects the OLD cluster's full state; the Git path
   rebuilds a CLEAN one and is preferred unless you specifically need the prior
   cluster-scoped state. Managed clusters: etcd is the provider's — use the Git
   path.)*
3. **Restore the data into the rebuilt cluster.** Argo (step 2) re-created the
   StatefulSet, which provisioned a **fresh empty** `data-postgres-0` PVC.
   Velero's default `existingResourcePolicy: none` **skips** a resource that
   already exists — so it would *not* overwrite that empty PVC. Stop Postgres,
   **delete the empty PVC** so Velero re-creates it from the backup, then
   restore (the same ns+resource scope as Scenario 2 — *not* `--selector
   app=postgres`, which silently skips the unlabelled volumeClaimTemplate PVC):
   ```sh
   kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
     -n bookstore --replicas=0
   kubectl scale statefulset/postgres -n bookstore --replicas=0
   kubectl wait --for=delete pod/postgres-0 -n bookstore --timeout=120s
   # delete the empty PVC so Velero recreates it from the backup (cleaner for
   # a learner than `velero restore … --existing-resource-policy update`,
   # which is the in-place alternative):
   kubectl delete pvc data-postgres-0 -n bookstore
   velero restore create bookstore-pgrestore \
     --from-backup bookstore-daily-<TIMESTAMP> \
     --include-namespaces bookstore \
     --include-resources persistentvolumeclaims,persistentvolumes
   velero restore describe bookstore-pgrestore --details   # Phase: Completed
   kubectl scale statefulset/postgres -n bookstore --replicas=1
   kubectl rollout status statefulset/postgres -n bookstore --timeout=120s
   kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
     -n bookstore --replicas=2
   ```
4. **Validate end-to-end** (the capstone-style smoke test):
   ```sh
   kubectl wait --for=condition=available deploy --all -n bookstore --timeout=300s
   kubectl get pods,svc,netpol -n bookstore
   kubectl exec -n bookstore postgres-0 -- \
     psql -U bookstore -d bookstore -c 'SELECT count(*) FROM books;'
   ```

---

## Post-incident (every scenario)

- [ ] **Verify data integrity**, not just pod readiness (row counts / app smoke
      test — a green pod with an empty DB is *not* recovered).
- [ ] **Record actual RPO/RTO achieved** vs target; if missed, tighten the
      Velero `Schedule` (RPO) or pre-stage images/cluster (RTO).
- [ ] **The backup is only real if the restore worked** — schedule a *recurring
      restore drill* (Scenario 2 against a throwaway namespace/cluster). An
      untested backup is not a backup.
- [ ] If data loss exceeded RPO, evaluate the operator/PITR path
      ([ch.05](../../../08-day-2-operations/05-operators-and-crds.md)) or a
      managed DB (provider SLA-backed PITR).
- [ ] Re-point writers, confirm `argocd app get` is Synced/Healthy, close the
      incident with the timeline.
