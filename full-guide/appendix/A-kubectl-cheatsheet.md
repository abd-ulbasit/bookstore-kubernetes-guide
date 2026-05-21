# Appendix A — `kubectl` cheatsheet

> A task-organized `kubectl` reference for this guide, current for Kubernetes
> **v1.30+** (verified against `kubectl` v1.35 / embedded Kustomize v5.7).
> Every command here is one this guide actually uses; the conventions
> (distroless `kubectl debug`, the PSA-`restricted` `bookstore` namespace,
> Helm-pinned operator installs, the bootstrap order, server-side apply) are the
> guide's hard-won ones — they are called out where they matter, not invented
> here. Keep this open while you work; the **[Which chapter teaches
> this](#which-chapter-teaches-this)** table at the end maps every area back to
> the chapter that explains *why*.

This is a reference, not a tutorial. It does **not** follow the nine-section
chapter anatomy. `<NS>` = a namespace, `<POD>`/`<SVC>`/`<D>` = object names,
`<C>` = a container name. The running example is the **Bookstore** in the
`bookstore` namespace (PSA `enforce: restricted`).

> **The one rule that prevents the worst outage:** before *any* mutating
> command, confirm `kubectl config current-context`. Acting on the wrong
> cluster is the single most expensive everyday mistake
> ([00-foundations/07](../00-foundations/07-local-cluster-setup.md)).

---

## 1. Context & namespace (always set the namespace)

```sh
kubectl config get-contexts                       # list all contexts (* = current)
kubectl config current-context                    # which cluster/user am I on RIGHT NOW?
kubectl config use-context <NAME>                 # switch the active context
kubectl config set-context --current --namespace=<NS>   # default ns for THIS context
kubectl config view --minify                      # the effective config for the current context
```

Per-command overrides (do not rely on these for safety — set the context):

```sh
kubectl get pods -n <NS>                          # one-off namespace override
kubectl get pods -A                               # --all-namespaces
kubectl --context <CTX> -n <NS> get pods          # fully explicit (scripts/CI)
```

> **Discipline:** *always* either set the namespace on the context or pass
> `-n <NS>`. A command with no namespace silently targets `default` — a common
> "why is nothing there?" The Bookstore lives in `bookstore`, never `default`.
> `kubens`/`kubectx` (<https://github.com/ahmetb/kubectx>) are widely-used
> **third-party** helpers (not part of `kubectl`) for fast namespace/context
> switching; a shell prompt that shows the context is the cheapest safeguard.

---

## 2. Fast imperative creation (CKAD-speed) → manifest workflow

The guide's workflow: generate YAML imperatively, redirect to a file, edit, then
`apply` and keep in Git. `--dry-run=client -o yaml` is the bridge from "fast to
type" to "declarative and reviewable"
([00-foundations/06](../00-foundations/06-declarative-api-model.md)).

```sh
# The imperative -> manifest pattern (use this constantly):
kubectl create deployment catalog --image=bookstore/catalog:dev \
  --dry-run=client -o yaml > catalog-deploy.yaml      # generate, don't apply
$EDITOR catalog-deploy.yaml                            # add probes, resources, securityContext
kubectl apply -f catalog-deploy.yaml                   # declarative create/update
```

Generators (each accepts `--dry-run=client -o yaml`):

```sh
kubectl run catalog --image=bookstore/catalog:dev --port=8080 --restart=Never   # a bare Pod
kubectl create deployment catalog --image=bookstore/catalog:dev --replicas=3
kubectl create job db-migrate --image=postgres:16 \
  -- psql -h postgres -U bookstore -d bookstore -c 'SELECT 1'   # args after -- are argv (no shell)
kubectl create cronjob cleanup --image=postgres:16 --schedule="0 3 * * *" \
  -- sh -c '/scripts/cleanup.sh'   # use sh -c for a path; bare 'cleanup.sh' would resolve via $PATH
kubectl create configmap catalog-config --from-literal=LOG_LEVEL=info \
  --from-file=app.properties
kubectl create secret generic db-credentials \
  --from-literal=POSTGRES_PASSWORD=devpassword          # base64, NOT encryption
kubectl create secret docker-registry regcred \
  --docker-server=<REG> --docker-username=<U> --docker-password=<P>
kubectl create serviceaccount catalog-sa
kubectl create role catalog-config-reader --verb=get --resource=configmaps \
  --resource-name=catalog-config
kubectl create rolebinding catalog-config-reader-binding \
  --role=catalog-config-reader --serviceaccount=bookstore:catalog-sa
kubectl create clusterrole pod-reader --verb=get,list,watch --resource=pods
kubectl create clusterrolebinding pr --clusterrole=pod-reader --serviceaccount=bookstore:catalog-sa
kubectl create quota bookstore-quota --hard=cpu=4,memory=8Gi,pods=20
kubectl create namespace bookstore
kubectl create ingress bookstore --rule="bookstore.localdev.me/*=storefront:80"
```

Expose a workload as a Service:

```sh
kubectl expose deployment catalog --port=80 --target-port=8080 --name=catalog
kubectl expose deployment catalog --port=8080 --type=ClusterIP --dry-run=client -o yaml
```

In-place edits to running objects (fast for learning/incident response; in
production change the *source*, not the live object —
[00-foundations/06](../00-foundations/06-declarative-api-model.md)):

```sh
kubectl set image deploy/catalog catalog=bookstore/catalog:dev -n bookstore
kubectl set env  deploy/catalog -n bookstore LOG_LEVEL=warn       # set an env var
kubectl set env  deploy/catalog -n bookstore LOG_LEVEL-           # trailing '-' DELETES it
kubectl set resources deploy/catalog -n bookstore \
  --requests=cpu=50m,memory=64Mi --limits=cpu=250m,memory=128Mi
kubectl set serviceaccount deploy/catalog catalog-sa -n bookstore
kubectl scale deploy/catalog --replicas=4 -n bookstore
kubectl scale deploy/catalog --replicas=4 --current-replicas=3 -n bookstore   # guarded
kubectl autoscale deploy/catalog --min=2 --max=10 --cpu-percent=70 -n bookstore
kubectl label   pod <POD> tier=backend -n bookstore [--overwrite]
kubectl annotate deploy/catalog kubernetes.io/change-cause="bump to 1.4" -n bookstore
kubectl patch deploy/catalog -n bookstore --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/readyz"}]'
kubectl patch deploy/catalog -n bookstore --type=merge -p='{"spec":{"replicas":3}}'
```

Rollout management (Deployments/StatefulSets/DaemonSets):

```sh
kubectl rollout status     deploy/catalog -n bookstore         # wait for the rollout
kubectl rollout history    deploy/catalog -n bookstore         # revisions
kubectl rollout history    deploy/catalog -n bookstore --revision=3
kubectl rollout undo       deploy/catalog -n bookstore          # roll back one revision
kubectl rollout undo       deploy/catalog -n bookstore --to-revision=2
kubectl rollout restart    deploy/catalog -n bookstore          # re-roll (e.g. pick up a rotated Secret)
kubectl rollout pause      deploy/catalog -n bookstore          # batch several edits then resume
kubectl rollout resume     deploy/catalog -n bookstore
```

Schema discovery (authoritative, version-correct — reach for it constantly):

```sh
kubectl explain deploy.spec.template.spec.containers          # one level
kubectl explain deploy.spec --recursive                       # the whole subtree
kubectl explain pod.spec.securityContext --recursive          # what 'restricted' fields exist
kubectl api-resources                                         # every kind, its group, namespaced?
kubectl api-resources --namespaced=true -o wide               # verbs too
kubectl api-versions                                          # every served group/version
```

---

## 3. Inspect & observe

```sh
kubectl get pods -n <NS>                                  # list (STATUS, RESTARTS, AGE)
kubectl get pods -n <NS> -o wide                          # + node, Pod IP
kubectl get deploy,svc,pods -n <NS>                       # several kinds at once
kubectl get pod <POD> -n <NS> -o yaml                     # full spec AND controller-written status
kubectl get pod <POD> -n <NS> -o json
kubectl get pods -n <NS> -w                               # watch (stream changes)
kubectl get pods -n <NS> --watch-only                     # only subsequent changes
kubectl get pods -A --sort-by=.metadata.creationTimestamp # newest last
kubectl get pods -n <NS> --show-labels                    # all labels
kubectl get pods -n <NS> -L app -L version                # selected labels as columns
kubectl get pods -n <NS> -l app=catalog                   # equality selector
kubectl get pods -n <NS> -l 'app in (catalog,orders)'     # set-based selector
kubectl get pods -n <NS> -l 'app,!canary'                 # has 'app', NOT 'canary'
kubectl get pods -n <NS> --field-selector status.phase=Running
```

Custom output — jsonpath, custom-columns, go-template:

```sh
# jsonpath: pull exact fields (note the {} and quoting)
kubectl get pod <POD> -n <NS> -o jsonpath='{.spec.containers[0].image}{"\n"}'
kubectl get pods -n <NS> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# custom-columns: a tidy table
kubectl get pods -n <NS> \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,NODE:.spec.nodeName'

# go-template (when jsonpath is not enough)
kubectl get pods -n <NS> \
  -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}'
```

`describe`, events, resource usage, raw endpoints:

```sh
kubectl describe pod <POD> -n <NS>                        # human view + the Events section
kubectl describe deploy/catalog -n <NS>

# kubectl events (the modern command; richer than `get events`):
kubectl events -n <NS>                                    # namespace events
kubectl events -n <NS> --for pod/<POD>                    # events for ONE object
kubectl events -n <NS> --types=Warning                    # warnings only
kubectl events -n <NS> -w                                 # stream
kubectl get events -n <NS> --sort-by=.lastTimestamp       # older form, still valid

kubectl top pod -n <NS>                                   # live CPU/mem (needs metrics-server)
kubectl top pod -n <NS> --containers
kubectl top node

kubectl get --raw='/readyz?verbose'                       # API server health gates
kubectl get --raw='/livez?verbose'
kubectl get --raw='/metrics' | head                       # apiserver Prometheus metrics
kubectl cluster-info                                      # control-plane endpoints
kubectl get componentstatuses                             # legacy; prefer /readyz on modern clusters
```

---

## 4. Debug — guide-consistent (distroless, PSA-`restricted`)

> **The reflex that fails in this codebase.** `catalog`, `orders`, and
> `payments-worker` are distroless `gcr.io/distroless/static:nonroot` images:
> **no shell, no `ps`, no `curl`**. `kubectl exec catalog -- sh` returns
> `exec: "sh": executable file not found`. The correct tool is **`kubectl debug`** with an ephemeral container. `postgres`/`redis`/`rabbitmq` are stock
> images and *do* have a shell — the Bookstore is mixed; know which
> ([08-day-2-operations/03](../08-day-2-operations/03-troubleshooting-playbook.md)).

Logs and the troubleshooting trident:

```sh
kubectl logs <POD> -n <NS>                                # stdout/stderr
kubectl logs <POD> -n <NS> -c <C>                         # a specific container
kubectl logs <POD> -n <NS> -f                             # follow
kubectl logs <POD> -n <NS> --previous                     # the PREVIOUS (crashed) container — CrashLoop
kubectl logs <POD> -n <NS> --since=15m                    # time-bounded
kubectl logs <POD> -n <NS> --tail=100 --timestamps
kubectl logs deploy/catalog -n <NS> --all-containers      # logs across a workload's pods
kubectl logs -n <NS> -l app=catalog --prefix              # by label, prefix each line with the pod
```

`kubectl debug` — ephemeral containers (the right primitive for distroless):

```sh
# (a) EPHEMERAL debug into a RUNNING distroless pod — inject a tooling
# container that SHARES the target's PROCESS + NETWORK namespaces.
# --target=<CTR> requires a *Pod name* (not a Deployment): with a workload
# name kubectl debug does copy-to instead, NOT ephemeral injection. Resolve
# one pod of the workload first. --profile=restricted (GA in v1.30) shapes
# it runAsNonRoot + drop ALL + seccomp RuntimeDefault so PSA admits it.
POD=$(kubectl get pod -n bookstore -l app=catalog \
  -o jsonpath='{.items[0].metadata.name}')
kubectl debug -it -n bookstore pod/"$POD" \
  --image=nicolaka/netshoot --target=catalog --profile=restricted -- /bin/bash
#   inside: curl -s localhost:8080/healthz ; nslookup postgres ; nc -vz postgres 5432 ; ps aux
#   (the ephemeral container is gone on exit; the live Pod is untouched.)

# (b) Debug a COPY (mutate freely — swap image/entrypoint — live Pod untouched).
# This form DOES take a Pod name OR a workload; --copy-to makes a new Pod:
kubectl debug -n bookstore pod/"$POD" --copy-to=catalog-dbg \
  --set-image=catalog=busybox:1.36 --profile=restricted -- sh
#   equivalently from the Deployment: kubectl debug -n bookstore deploy/catalog \
#     --copy-to=catalog-dbg --set-image=catalog=busybox:1.36 --profile=restricted -- sh
kubectl delete pod catalog-dbg -n bookstore         # clean up the copy when done

# Node-level debugging (host fs at /host, host namespaces) — for kubelet/containerd/disk:
kubectl debug node/<NODE> -it --profile=sysadmin --image=busybox:1.36
```

> **Why `--profile`, not a bare `--image`.** An ephemeral container joins the
> *target Pod's* namespace, so in `bookstore` it must itself satisfy PSA
> `restricted`. `--profile=restricted` shapes it to comply (use this for
> `bookstore`); a bare `--image=busybox` with no profile is **rejected by PSA**.
> The fallback for a tool image that cannot be made restricted-compliant: debug
> a **copy in the `default` namespace** (`--copy-to=dbg --namespace=default`),
> which has no PSA enforcement. Profiles: `restricted` (PSA-`restricted` ns —
> the Bookstore), `general` (non-PSA ns), `sysadmin`/`netadmin` (privileged /
> NET_ADMIN, for `node/<N>` debugging only)
> ([08-day-2-operations/03](../08-day-2-operations/03-troubleshooting-playbook.md),
> [05-security/02](../05-security/02-pod-security.md)).

Ad-hoc pod in the **`bookstore`** namespace — must be restricted-compliant. The
one-liner `--overrides` JSON the guide uses (busybox/curl/netshoot all run fine
under this `securityContext`):

```sh
kubectl run sa-peek -n bookstore --image=busybox:1.36 --restart=Never -i --rm \
  --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"sa-peek","image":"busybox:1.36","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["sh","-c","echo restricted-compliant pod OK"]}]}}'
#   NOTE: "apiVersion":"v1" is REQUIRED (kubectl needs the Pod wrapper to
#   merge the override). The "containers" override REPLACES the generated
#   container (it does not merge), so "name" AND "image" must be repeated
#   correctly. Preview the merged Pod with --dry-run=client -o yaml:
#     kubectl run sa-peek -n bookstore --image=busybox:1.36 --restart=Never \
#       --dry-run=client -o yaml --overrides='{...same JSON...}'
#   (Or: run an unconstrained throwaway pod in the `default` namespace, which
#    does NOT enforce PSA — the simplest path when you just need a scratch pod.)
```

`exec`, `port-forward`, `cp`, `attach` (note: `exec ... sh` only works on
images that *have* a shell — not the distroless Go services):

```sh
kubectl exec -it -n <NS> <POD> -c <C> -- sh               # shell (stock images only)
kubectl exec -n <NS> <POD> -- env                         # one-shot command
kubectl exec -n bookstore statefulset/postgres -- psql -U bookstore -c '\dt'
kubectl port-forward -n <NS> pod/<POD> 8080:8080          # tunnel localhost:8080 -> pod:8080
kubectl port-forward -n <NS> svc/catalog 8080:80          # forward to a Service
kubectl cp <NS>/<POD>:/path/in/pod ./local               # copy out (needs tar in the image)
kubectl attach -it -n <NS> <POD>                          # attach to PID 1's stdio
```

---

## 5. Apply / diff / server-side apply

```sh
kubectl apply -f manifest.yaml                            # declarative create/update (3-way merge)
kubectl apply -f dir/                                     # a directory of manifests
kubectl apply -f https://example.com/manifest.yaml        # a URL (pin the URL — see note)
kubectl apply -k overlays/dev                             # render a kustomization, then apply
kubectl apply -f manifest.yaml --dry-run=client           # parse + local validate, NO cluster
kubectl apply -f manifest.yaml --dry-run=server           # run apiserver admission incl. PSA, NO persist
kubectl apply -f manifest.yaml --server-side --field-manager=ci   # Server-Side Apply (field ownership)
kubectl apply -f manifest.yaml --server-side --force-conflicts     # take ownership on conflict (use deliberately)
kubectl diff  -f manifest.yaml                            # what apply WOULD change (live vs desired)
kubectl diff  -k overlays/prod
kubectl replace -f manifest.yaml                          # full replace (object must exist)
kubectl replace --force -f manifest.yaml                  # delete + recreate (loses immutable-field history)
kubectl delete -f manifest.yaml                           # delete what a manifest declares
kubectl delete -k overlays/dev
kubectl kustomize overlays/prod                           # render only (no apply) — built into kubectl
```

> **Server dry-run is the PSA proof.** `--dry-run=client` only parses YAML.
> `--dry-run=server` runs the full admission pipeline (including **Pod Security
> Admission**) without persisting — this is how the guide certifies every
> Bookstore workload is admitted under `enforce: restricted`
> ([05-security/02](../05-security/02-pod-security.md),
> [07-delivery/01](../07-delivery/01-packaging-helm.md)).

> **Server-Side Apply (SSA).** Each field has a recorded *manager*
> (`metadata.managedFields`); the API server merges by field ownership and
> reports a **conflict** if two managers fight over the same field. This is what
> makes "Git owns most of the Deployment, an HPA owns `spec.replicas`" safe.
> Prefer `--server-side` for GitOps/CI; resolve conflicts deliberately, not by
> reflexively adding `--force-conflicts`
> ([00-foundations/06](../00-foundations/06-declarative-api-model.md),
> [appendix C](C-yaml-and-api-conventions.md)).

> **Operator installs — pin, do not `latest`-URL.** The guide installs
> operators (Prometheus, KEDA, Kyverno, Gateway API, snapshotter, CNPG, Argo)
> with **pinned Helm charts** (`helm repo add … && helm install … --version <PINNED>`),
> *never* `kubectl apply -f https://…/releases/latest/download/<PINNED-FILE>.yaml` — that URL 404s the
> moment a new release ships
> ([08-day-2-operations/05](../08-day-2-operations/05-operators-and-crds.md),
> [07-delivery/01](../07-delivery/01-packaging-helm.md)).

---

## 6. RBAC & auth

```sh
kubectl auth whoami                                       # your identity (the authN result)
kubectl auth can-i create pods -n <NS>                    # your authZ (SubjectAccessReview)
kubectl auth can-i --list -n <NS>                         # everything YOU can do here
kubectl auth can-i delete clusterroles                    # almost certainly: no
kubectl auth can-i get configmap/catalog-config -n bookstore \
  --as=system:serviceaccount:bookstore:catalog-sa         # audit a workload's SA
kubectl auth can-i --list -n bookstore \
  --as=system:serviceaccount:bookstore:orders-sa          # what can this SA do? (~nothing, by design)
kubectl auth can-i get secrets -n <NS> --as=alice --as-group=dev   # impersonate user+group
kubectl create token catalog-sa -n bookstore              # mint a short-lived SA token (TokenRequest API)
kubectl create token catalog-sa -n bookstore --duration=10m --audience=api
kubectl get sa,role,rolebinding,clusterrole,clusterrolebinding -n <NS>
kubectl describe clusterrole view                         # inspect a built-in role
```

> `--as`/`--as-group` is **impersonation** — itself an RBAC-gated power
> (`impersonate` verb), the canonical way to audit another identity without its
> credentials. `kubectl auth can-i` asks the *real* authorizer, so it is the
> authoritative answer ([05-security/01](../05-security/01-authn-authz-rbac.md)).

---

## 7. Cleanup, labels & selectors

```sh
kubectl delete pod <POD> -n <NS>
kubectl delete pod <POD> -n <NS> --grace-period=0 --force  # last resort (skips graceful shutdown)
kubectl delete pods -n <NS> -l app=catalog                 # by selector
kubectl delete deploy,svc -n <NS> -l app.kubernetes.io/part-of=bookstore
kubectl delete pods --all -n <NS>
kubectl delete namespace <NS>                              # deletes EVERYTHING in it (incl. PVCs)
kubectl delete -f manifest.yaml --wait=true                # block until gone (finalizers)
kubectl get pods -n <NS> -l app=catalog -o name | xargs -r kubectl delete -n <NS>
kubectl label  pods -n <NS> -l app=catalog tier=backend --overwrite
kubectl label  pod <POD> -n <NS> tier-                     # trailing '-' REMOVES the label
```

> A `kubectl delete namespace bookstore` (or deleting a packaging tree that
> templates the Namespace) **destroys the postgres PVC and its data**. In
> production keep the namespace/PVCs out of the release's ownership
> ([07-delivery/01](../07-delivery/01-packaging-helm.md),
> [08-day-2-operations/02](../08-day-2-operations/02-backup-and-dr.md)).

---

## 8. The Bookstore bootstrap order (the standing invariant)

Every flow that brings up `catalog`/`orders` must respect this order, or you get
schema-missing `CrashLoopBackOff` and a `kubectl wait` timeout
([09-end-to-end-bookstore/01](../09-end-to-end-bookstore/01-bookstore-end-to-end.md),
[05-security/01](../05-security/01-authn-authz-rbac.md)):

```sh
# from the repo root (full-guide/)
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml          # ns + PSA restricted labels
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml     # config
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml     # secret (demo-only)
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml    # cluster-scoped
# ... workloads (10-/11-/14-/19-/20-/40-/12-/13-) ...
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=180s   # MUST complete first
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=300s
```

`kubectl wait` is the generic gate primitive used throughout:

```sh
kubectl wait --for=condition=complete   job/db-migrate -n bookstore --timeout=180s
kubectl wait --for=condition=available  deploy --all   -n bookstore --timeout=300s
kubectl wait --for=condition=Ready      pod -l app=catalog -n bookstore --timeout=120s
kubectl wait --for=delete               pod/postgres-0 -n bookstore --timeout=120s
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/<POD> -n <NS>
kubectl rollout status statefulset/postgres -n bookstore        # StatefulSet readiness gate
```

---

## CKAD speed tips

```text
┌─ FAST IN THE EXAM (and in real incident response) ───────────────────────────┐
│ • alias k=kubectl ; export do='--dry-run=client -o yaml' ; export now=       │
│     '--grace-period=0 --force'  →  k run x --image=nginx $do > x.yaml        │
│ • GENERATE, don't hand-write: create/run/expose ... --dry-run=client -o yaml │
│     > f.yaml, then edit. Faster and less error-prone than typing YAML.       │
│ • kubectl explain <KIND>.spec.<FIELD> --recursive  before guessing a field.  │
│ • kubectl <CMD> --help | less  — the per-command flags are exam-legal docs.  │
│ • -o jsonpath / custom-columns to extract one value fast (image, nodeName).  │
│ • k get po -w  (or kubectl events -w) to watch a rollout converge live.      │
│ • k delete po x $now  to skip the 30s graceful term when you need it gone.   │
│ • Set the namespace ONCE: k config set-context --current --namespace=<NS>.   │
│ • kubectl debug (NOT exec sh) for distroless; --profile=restricted in a      │
│     PSA-restricted ns.                                                       │
│ • --dry-run=server validates against admission (incl. PSA) without applying. │
│ • k apply -k <OVERLAY> / k kustomize <OVERLAY> — Kustomize is built in.      │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Which chapter teaches this

Every command area maps back to the chapter that explains *why* it works that
way. Read the chapter; keep this page for the syntax.

| Command area | Chapter that teaches it |
|---|---|
| Contexts, kubeconfig, the everyday verbs, `kubectl` as a REST client | [00-foundations/07 — Local cluster setup](../00-foundations/07-local-cluster-setup.md) |
| The declarative model, `apply` 3-way merge, **SSA**, `explain`, `diff`, labels/selectors | [00-foundations/06 — The declarative API model](../00-foundations/06-declarative-api-model.md) |
| The API server pipeline (authN/authZ/admission) behind these calls | [00-foundations/04 — Control plane deep dive](../00-foundations/04-control-plane-deep-dive.md) |
| Pods, `kubectl run`, multi-container | [01-core-workloads/01 — Pods](../01-core-workloads/01-pods.md) |
| Probes, lifecycle, `--previous`, readiness vs Endpoints | [01-core-workloads/02 — Health and lifecycle](../01-core-workloads/02-health-and-lifecycle.md) |
| `set resources`, requests/limits, QoS, OOM | [01-core-workloads/03 — Resources and QoS](../01-core-workloads/03-resources-and-qos.md) |
| `create deployment`, `scale`, `rollout *`, `set image` | [01-core-workloads/04 — ReplicaSets and Deployments](../01-core-workloads/04-replicasets-and-deployments.md) |
| StatefulSet `rollout status`, ordinals | [01-core-workloads/05 — StatefulSets](../01-core-workloads/05-statefulsets.md) |
| `create job`/`cronjob`, `wait --for=condition=complete` | [01-core-workloads/07 — Jobs and CronJobs](../01-core-workloads/07-jobs-and-cronjobs.md) |
| `expose`, Services, Endpoints | [02-networking/02 — Services](../02-networking/02-services.md) |
| DNS lookups from a debug container | [02-networking/03 — DNS and service discovery](../02-networking/03-dns-and-discovery.md) |
| `create ingress` | [02-networking/04 — Ingress](../02-networking/04-ingress.md) |
| NetworkPolicy diagnosis (`nc`/`nslookup` from `kubectl debug`) | [02-networking/06 — Network policies](../02-networking/06-network-policies.md) |
| `create configmap`, `set env` | [03-config-and-storage/01 — ConfigMaps](../03-config-and-storage/01-configmaps.md) |
| `create secret`, why it is base64 not encryption, `create token` | [03-config-and-storage/02 — Secrets](../03-config-and-storage/02-secrets.md) |
| PVC/StorageClass inspection | [03-config-and-storage/04 — Persistent storage](../03-config-and-storage/04-persistent-storage.md) |
| Affinity/taint/topology fields (via `explain`/`describe node`) | [04-scheduling/02 — Affinity, taints, topology](../04-scheduling/02-affinity-taints-topology.md) |
| PriorityClass, preemption, `Evicted` | [04-scheduling/03 — Priority and preemption](../04-scheduling/03-priority-and-preemption.md) |
| `auth whoami/can-i`, `create token`, RBAC objects, `--as` | [05-security/01 — Authn, authz, RBAC](../05-security/01-authn-authz-rbac.md) |
| **PSA `restricted`**, `--dry-run=server` as the PSA proof, restricted `--overrides`/`--profile` | [05-security/02 — Pod security](../05-security/02-pod-security.md) |
| Image digests, `kubectl debug` & distroless rationale | [05-security/03 — Supply chain](../05-security/03-supply-chain.md) |
| `top pod/node`, `get --raw /metrics` | [06-production-readiness/01 — Observability: metrics](../06-production-readiness/01-observability-metrics.md) |
| `logs` patterns, `--since`, `-l --prefix` | [06-production-readiness/02 — Logging](../06-production-readiness/02-logging.md) |
| `autoscale`, HPA inspection | [06-production-readiness/04 — Autoscaling](../06-production-readiness/04-autoscaling.md) |
| PodDisruptionBudget, drain interaction | [06-production-readiness/05 — Reliability and disruptions](../06-production-readiness/05-reliability-and-disruptions.md) |
| Helm-pinned operator installs, `--dry-run=server` cert | [07-delivery/01 — Packaging with Helm](../07-delivery/01-packaging-helm.md) |
| `apply -k`, `kustomize`, `diff -k` | [07-delivery/02 — Packaging with Kustomize](../07-delivery/02-packaging-kustomize.md) |
| `cordon`/`drain`/`uncordon`, version skew | [08-day-2-operations/01 — Cluster lifecycle](../08-day-2-operations/01-cluster-lifecycle.md) |
| **`kubectl debug` (distroless, `--profile=restricted`)**, the per-symptom tree | [08-day-2-operations/03 — Troubleshooting playbook](../08-day-2-operations/03-troubleshooting-playbook.md) |
| Namespaces, ResourceQuota, `create quota` | [08-day-2-operations/04 — Multi-tenancy and namespaces](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) |
| CRDs/operators, `api-resources` for CRD discovery | [08-day-2-operations/05 — Operators and CRDs](../08-day-2-operations/05-operators-and-crds.md) |
| The full bootstrap order & `kubectl wait` gating | [09-end-to-end-bookstore/01 — Bookstore end-to-end](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) |

Node lifecycle (drain/cordon) and `crictl` (data-plane peek inside a kind node):

```sh
kubectl cordon   <NODE>                                   # mark unschedulable
kubectl drain    <NODE> --ignore-daemonsets --delete-emptydir-data   # evict (respects PDBs)
kubectl uncordon <NODE>                                    # back into rotation
kubectl get nodes -o wide ; kubectl describe node <NODE>   # capacity, conditions, taints
docker exec -it bookstore-control-plane crictl ps          # kind node: running containers
docker exec -it bookstore-control-plane crictl pods        # kind node: pod sandboxes
```

See also: [Appendix B — Glossary](B-glossary.md) for any term above,
[Appendix C — YAML & API conventions](C-yaml-and-api-conventions.md) for the
`apply`/SSA/jsonpath/deprecation details, and [Appendix E — Learning
paths](E-learning-paths.md) for where these commands appear in a study order.
