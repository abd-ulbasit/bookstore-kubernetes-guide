# Bookstore: Disaster Recovery Runbook

> Companion to [Part 08 ch.02: Backup and disaster
> recovery](../../../08-day-2-operations/02-backup-and-dr.md). This is the
> ordered, runnable runbook the chapter references. It assumes the backup
> posture that chapter establishes:
>
> - **Desired state in Git**: the Bookstore's Kustomize overlays reconciled by
>   Argo CD ([Part 07 ch.04](../../../07-delivery/04-gitops-argocd.md)). This is
>   the *easiest* "restore": re-point Argo at Git and the declarative state
>   rebuilds itself.
> - **etcd snapshots**: cluster state, on a self-managed control plane
>   (`etcdctl snapshot save`). On managed clusters etcd is the provider's; you
>   cannot `etcdctl` it (and do not need to).
> - **Velero**: namespaced backup of `bookstore` **including the Postgres PV**
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
> (including any corruption that existed then): for sub-snapshot RPO you need
> WAL/PITR, which is the operator/managed-DB story
> ([ch.05](../../../08-day-2-operations/05-operators-and-crds.md)).

---

## Scenario 1: A workload was deleted/corrupted (lost a Deployment)

*Example: someone `kubectl delete deploy catalog -n bookstore`, or a bad
`kubectl edit` wedged it.* **No data is lost**: only declarative state.

- **RPO:** 0 (no data involved). **RTO:** one Argo reconcile (~minutes).

1. Confirm scope: only declarative objects affected, PVC intact:
   ```sh
   kubectl get deploy,statefulset -n bookstore
   kubectl get pvc -n bookstore               # data-postgres-0 STILL Bound
   ```
2. **GitOps path (preferred: no manual apply):** Argo CD with
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
   #   ^ restricted-compliant overrides: the bookstore ns enforces PSA
   #     `restricted`, so even a throwaway check pod must comply.
   ```

---

## Scenario 2: The Postgres PVC was lost/corrupted (data loss)

*Example: the `data-postgres-0` PVC/PV was deleted, the disk failed, or a
`DROP TABLE` ran.* **This is the real DR case**: declarative state is fine,
**data is gone**, and only a *data backup* recovers it.

- **RPO:** up to the Velero `Schedule` interval (lab: ≤24h). **RTO:** restore
  time + Postgres readiness (lab: ~minutes on a small DB).

1. **Restore into a scratch namespace and validate first.** Use the drill in
   [chapter step 4](../../../08-day-2-operations/02-backup-and-dr.md), with the
   newest good backup as `backupName`. Compare its rows with the live database.
   The live namespace is not touched until this passes.
2. **Stop writers, then promote with Velero's in-place procedure.** Scale the
   writers to zero, delete the Postgres controller while keeping its PVC and
   PV, and restore with the controller included, as the upstream guide describes
   ([file-system backup, "To restore"](https://velero.io/docs/main/file-system-backup/)).
   Scaling the controller to zero is not enough: it ends the restored Pod that
   carries Velero's restore-wait init container, so the data is not restored.
   ```sh
   kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
     -n bookstore --replicas=0
   ```
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

## Scenario 3: The entire cluster is gone (total loss)

*Example: the cluster was deleted, the region failed, an upgrade bricked it
([ch.01](../../../08-day-2-operations/01-cluster-lifecycle.md)).* Rebuild from
**Git (declarative) + Velero (data)**, optionally **etcd snapshot** if you must
resurrect the *same* self-managed control plane rather than a fresh one.

- **RPO:** Velero `Schedule` interval for data; 0 for declarative (it is in
  Git). **RTO:** new-cluster provision + Argo bootstrap + data restore.

1. **Stand up a new cluster** ([ch.01](../../../08-day-2-operations/01-cluster-lifecycle.md)):
   kind locally, or the provider/kubeadm in production. Install the CSI driver
   + snapshot CRDs and Velero (same `BackupStorageLocation`: the backups must
   outlive the cluster, which is *why* they live in an object store).
2. **Recover the declarative state from Git** (no cluster snapshot needed:
   this is the GitOps DR property):
   ```sh
   # install Argo CD, then TWO applies rebuild the whole app from Git:
   kubectl apply -n argocd -f examples/bookstore/argocd/00-appproject.yaml
   kubectl apply -n argocd -f examples/bookstore/argocd/01-app-of-apps.yaml
   #   → Argo recreates Namespace (PSA labels), Deployments, Services,
   #     NetworkPolicies, the StatefulSet, … everything declarative.
   ```
   *(Alternative for a self-managed control plane: restore the etcd snapshot:
   `etcdutl snapshot restore` into a fresh data-dir, repoint the new
   apiserver. This resurrects the OLD cluster's full state; the Git path
   rebuilds a CLEAN one and is preferred unless you specifically need the prior
   cluster-scoped state. Managed clusters: etcd is the provider's: use the Git
   path.)*
3. **Restore the data into the rebuilt cluster.** Argo (step 2) re-created the
   StatefulSet, which provisioned a **fresh empty** `data-postgres-0` PVC.
   Velero's default `existingResourcePolicy: none` **skips** a resource that
   already exists, so it would *not* overwrite that empty PVC. Stop Postgres,
   **delete the empty PVC** so Velero re-creates it from the backup, then
   restore (the same ns+resource scope as Scenario 2). A label selector skips any
   object without the label, so do not use `--selector app=postgres` here:
   ```sh
   kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
     -n bookstore --replicas=0
   kubectl scale statefulset/postgres -n bookstore --replicas=0
   kubectl wait --for=delete pod/postgres-0 -n bookstore --timeout=120s
   # Pause Argo CD auto-sync for the Bookstore Application first, or Argo
   # recreates what you delete. Velero skips objects that already exist, so
   # delete the empty StatefulSet and PVC that GitOps recreated, then restore
   # the namespace with the StatefulSet and Pods included. A PVC-only restore
   # leaves the data behind: file-system data is written back through the
   # restored Pod's restore-wait init container. Read the drill in chapter
   # step 4 and the upstream "To restore" section before you run this.
   kubectl delete statefulset/postgres -n bookstore --ignore-not-found
   kubectl delete pvc data-postgres-0 -n bookstore --ignore-not-found
   velero restore create bookstore-pgrestore \
     --from-backup bookstore-daily-<TIMESTAMP> \
     --include-namespaces bookstore
   velero restore describe bookstore-pgrestore --details   # Phase: Completed
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
      test: a green pod with an empty DB is *not* recovered).
- [ ] **Record actual RPO/RTO achieved** vs target; if missed, tighten the
      Velero `Schedule` (RPO) or pre-stage images/cluster (RTO).
- [ ] **The backup is only real if the restore worked**: schedule a *recurring
      restore drill* (Scenario 2 against a throwaway namespace/cluster). An
      untested backup is not a backup.
- [ ] If data loss exceeded RPO, evaluate the operator/PITR path
      ([ch.05](../../../08-day-2-operations/05-operators-and-crds.md)) or a
      managed DB (provider SLA-backed PITR).
- [ ] Re-point writers, confirm `argocd app get` is Synced/Healthy, close the
      incident with the timeline.
