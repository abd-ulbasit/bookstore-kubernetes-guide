# 07 — Local cluster setup

> Install `kubectl`, stand up a real (local) cluster with kind, understand
> kubeconfig and contexts, learn the everyday `kubectl` verbs — and run the
> first Bookstore Pod from [ch.06](06-declarative-api-model.md) for real.

**Estimated time:** ~15 min read · ~60 min hands-on
**Prerequisites:** [Part 00 ch.02](02-containers-and-images.md) — container/image basics · [Part 00 ch.06](06-declarative-api-model.md) — the manifest you'll apply
**You'll know after this:** • install `kubectl` and bring up a local kind cluster whose default Pod Security level is `restricted` · • show that a namespace nobody labelled refuses a privileged Pod · • understand `kubeconfig`, contexts, and namespaces · • use the everyday `kubectl` verbs (get, describe, logs, apply, exec, port-forward) · • apply the Bookstore Pod and watch reconciliation move it · • prove a NetworkPolicy is enforced with a connection that is denied · • troubleshoot a Pod that fails to start on a real cluster

<!-- tags: foundations, kubectl, kind, kubeconfig, local-cluster -->

## Why this exists

Part 00 has been concepts and one validated-but-unrun manifest. Concepts only
stick once you've watched the reconciliation loop move *your* object on a *real*
cluster. You need a cluster that is **free, local, disposable, and identical in
API to production** so every later chapter's hands-on works the same on your
laptop as on EKS. This chapter gives you that environment and the small set of
`kubectl` verbs you'll use in literally every chapter after this — then closes
the Part 00 arc by deploying `bookstore/catalog:dev` and curling its
`/healthz`, exactly the lifecycle you traced in
[ch.03](03-architecture-overview.md) and [ch.05](05-node-components.md).

## Mental model

A local cluster tool **fakes the machines, not the API**. kind ("Kubernetes IN
Docker") runs each Kubernetes *node as a Docker container* and a real control
plane inside it. The objects, the API server pipeline
([ch.04](04-control-plane-deep-dive.md)), the kubelet/CRI flow
([ch.05](05-node-components.md)) are the genuine Kubernetes code — only the
"hardware" is containers. So everything you learn transfers; what differs is
purely the substrate (no cloud load balancers, local image loading, single
node) — flagged by `> **In production:**` callouts. `kubectl` is just a REST
client; **kubeconfig** is the file telling it *which* API server and *as whom*.

## Threats and controls

| Threat | Control taught here | Goes deeper in |
|---|---|---|
| A namespace nobody labelled admits any Pod, privileged ones included, because Pod Security Admission falls back to `privileged` | `restricted` as the cluster-wide default, set in the API server's admission configuration; the step that proves it creates an unlabelled namespace and asks for a privileged Pod | [05.02](../05-security/02-pod-security.md) for the per-namespace labels, [05.07](../05-security/07-admission-control-and-policy-as-code.md) for rules beyond the standards |
| A NetworkPolicy the API server accepts but the network plugin does not enforce, so traffic still flows | Prove enforcement with a request that is denied, in the NetworkPolicy step below | [02.06](../02-networking/06-network-policies.md) |
| A kubeconfig holds a client key or a token, so whoever reads the file acts as you | Keep the file private and out of version control | [05.01](../05-security/01-authn-authz-rbac.md) |
| A change reaches the wrong cluster because the current context is not the one you meant | Read `kubectl config current-context` before each change | [05.01](../05-security/01-authn-authz-rbac.md) |

These are the only threats this chapter owns. The Pod's own threats come with
the Pod in [01.01](../01-core-workloads/01-pods.md#baseline). The threat model
for the whole Bookstore is in [Part 00 ch.08](08-security-foundations.md).

## Tooling diagram

```mermaid
flowchart TB
    subgraph laptop["Your laptop"]
        kc["kubectl<br/>(REST client)"]
        cfg["kubeconfig<br/>(~/.kube/config)<br/>clusters · users · contexts"]
        subgraph docker["Docker / Colima engine"]
            subgraph kindnode["kind node = ONE Docker container"]
                api["kube-apiserver"]
                etcd[("etcd")]
                cm["controller-manager"]
                sch["scheduler"]
                kub["kubelet + containerd"]
                pods["your Pods<br/>(e.g. catalog)"]
            end
        end
    end
    kc -->|reads current-context| cfg
    cfg -->|server URL + creds| kc
    kc -->|HTTPS :6443| api
    api <--> etcd
    sch --> api
    cm --> api
    kub --> api
    kub --> pods
```

A "node" here is a container; a multi-node kind cluster is just multiple
containers on the same Docker engine. That's the only illusion — the
Kubernetes inside is real.

## Why kind

kind is the one local cluster this guide verifies. It runs upstream
Kubernetes, so the API server, scheduler and kubelet are the real components,
and each node is a container you can inspect with `docker exec` (see
[ch.05](05-node-components.md)). Other distributions exist, k3d and minikube
among them. This guide does not test them, and nothing later depends on them.

## Why `restricted` is the cluster default

Pod Security Admission judges a Pod by the labels on its namespace. A
namespace with no labels is judged by the cluster's default, and out of the
box that default is `privileged`, which admits every Pod. The
[admission controller page](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/)
lists `privileged` as the default level. A namespace nobody labelled
therefore has no Pod Security at all.

Every namespace in this guide carries its own labels, and they stay. They are
the first line of defence: they say what each namespace is for, and they
travel with the manifests to a cluster that has no default. The cluster-wide
default is the last line. It catches the namespace the labels missed: one
created with `kubectl create namespace` and never labelled, one a Helm chart
created with `--create-namespace` (the flag cannot set labels), or one an
operator created on its own. On this cluster, a namespace like that refuses a
Pod that lacks the baseline on the first apply, instead of admitting it
without a word.

The API server reads the default from a file. This one sets all three modes
to `restricted` and exempts the four namespaces kind itself needs:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: restricted
        enforce-version: latest
        audit: restricted
        audit-version: latest
        warn: restricted
        warn-version: latest
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces:
          - kube-system
          - kube-public
          - kube-node-lease
          - local-path-storage
```

The fields follow the Kubernetes page on
[applying Pod Security Standards at the cluster level](https://kubernetes.io/docs/tutorials/security/cluster-level-pss/).
`enforce` refuses a Pod, `audit` records a violation in the audit log, and
`warn` prints it to the client. A label on a namespace overrides the default
for the mode it names, and for that mode only. The exemptions skip Pod
Security entirely, so the list is short and fixed: `kube-system` holds the
control plane, the CNI and CoreDNS, `kube-public` and `kube-node-lease` hold
no workloads, and `local-path-storage` holds kind's storage provisioner,
whose Pods carry no `securityContext`. Every other namespace, `default`
included, is judged at `restricted`.

## Hands-on with the Bookstore

This is the payoff of Part 00: a running cluster and the first Bookstore Pod.

### 1. Install `kubectl`

```sh
# macOS (Homebrew)
brew install kubectl
# Linux: the release this guide ran against, checked against the checksum
# file that dl.k8s.io publishes for it
curl -LO "https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -m 0755 kubectl /usr/local/bin/kubectl

kubectl version --client      # confirm it runs (server check comes after cluster up)
```

<!-- gate: output -->
```text
Client Version: v1.37.2
Kustomize Version: v5.8.1
```

> Keep `kubectl` within one minor version of the cluster (the supported skew is
> ±1 minor). Mismatched skew is a common source of odd errors.

### 2. Install a cluster tool and create a cluster

Run this step, and every later command in the chapter, from the `full-guide/`
directory of the repository. The config's mount path is relative to it.

```sh
go install sigs.k8s.io/kind@v0.33.0     # or `brew install kind`, then check:
kind version                            # expect v0.33.0
kind create cluster --name bookstore \
  --config examples/security-lab/kind/cluster-restricted-default.yaml
```

The [config](../examples/security-lab/kind/cluster-restricted-default.yaml)
does three things. It pins the node image by digest, so every reader's node is
the same. That digest is the default node image that kind v0.33.0 names in its
own
[source](https://github.com/kubernetes-sigs/kind/blob/v0.33.0/pkg/apis/config/defaults/image.go).
It mounts the file from the last section,
[`pod-security-admission.yaml`](../examples/security-lab/kind/pod-security-admission.yaml),
into the control-plane node. And it tells kubeadm to start the API server with
`--admission-control-config-file` pointing at the mounted file:

```yaml
    extraMounts:
      - hostPath: examples/security-lab/kind/pod-security-admission.yaml
        containerPath: /etc/kubernetes/policies/pod-security-admission.yaml
        readOnly: true
    kubeadmConfigPatches:
      - |
        apiVersion: kubeadm.k8s.io/v1beta4
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            - name: admission-control-config-file
              value: /etc/kubernetes/policies/pod-security-admission.yaml
          extraVolumes:
            - name: pod-security-config
              hostPath: /etc/kubernetes/policies
              mountPath: /etc/kubernetes/policies
              readOnly: true
              pathType: DirectoryOrCreate
```

kubeadm is at `v1beta4` on Kubernetes 1.37, where `extraArgs` is a list of
`name` and `value` pairs. The API server runs as a container on the node, so
`extraVolumes` is what makes the mounted directory visible inside it.

A later chapter that starts its own cluster with a plain
`kind create cluster --name bookstore` gets kind's stock default, `privileged`.
Add the same `--config` line to keep the default there. The labs of those
chapters ran on stock clusters unless a chapter says otherwise, and every
namespace in them carries its own labels.

`kind create cluster` also **merges a context into your kubeconfig and switches
to it** — so `kubectl` immediately points at the new cluster.

> A Docker-compatible engine must be running (Docker Engine, or
> Rancher Desktop/Podman/etc.). If you see "Cannot connect to the Docker
> daemon", start your engine first, then re-run `kind create cluster`. If your
> engine does not expose the default `/var/run/docker.sock`, point Docker at
> its socket via `DOCKER_HOST` (see your engine's docs for the socket path).

### 3. Verify the control plane and nodes

You're now looking at the real architecture from
[ch.03](03-architecture-overview.md):

```sh
kubectl cluster-info                       # API server endpoint (the front door, ch.04)
kubectl get nodes -o wide                  # the node container(s); STATUS should be Ready
kubectl -n kube-system get pods            # control plane + CoreDNS + kube-proxy as Pods
kubectl get --raw='/readyz?verbose'        # API server health gates (ch.04 pipeline)
```

`kubectl get nodes` showing `Ready` means the kubelet ([ch.05](05-node-components.md))
in the node container has registered and is healthy.

### 4. Prove that `restricted` is the default

A default nobody has tested is a hope. First confirm that the API server
started with the flag:

```sh
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{"\n"}{end}' \
  | grep admission-control
```

<!-- gate: output -->
```text
--admission-control-config-file=/etc/kubernetes/policies/pod-security-admission.yaml
```

Then make a namespace and label nothing. A new namespace gets its `default`
ServiceAccount a moment after it exists, and the API server refuses a Pod
before then, so the loop waits for it:

```sh
kubectl create namespace default-check
until kubectl -n default-check get serviceaccount default >/dev/null 2>&1; do sleep 1; done
kubectl get namespace default-check --show-labels
```

<!-- gate: output -->
```text
namespace/default-check created
# ...
NAME            STATUS   AGE   LABELS
default-check   Active   0s    kubernetes.io/metadata.name=default-check
```

The only label is the one Kubernetes adds itself. Now ask the namespace for a
privileged Pod. This failure is deliberate: the default is meant to refuse it.

```sh
BUSYBOX=busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec  # busybox:1.37
kubectl run privileged-probe -n default-check --image="$BUSYBOX" \
  --restart=Never --privileged -- sleep 3600
```

<!-- gate: output -->
```text
Error from server (Forbidden): pods "privileged-probe" is forbidden: violates PodSecurity "restricted:latest": privileged (container "privileged-probe" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "privileged-probe" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "privileged-probe" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "privileged-probe" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "privileged-probe" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The API server names every field that broke `restricted`, and it created
nothing. A Pod that carries the baseline is admitted in the same namespace.
This manifest adds a ServiceAccount, a 64Mi claim and a Pod that mounts the
claim. The claim also tests kind's storage provisioner, which sits in an
exempt namespace:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: check-sa
  namespace: default-check
automountServiceAccountToken: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: default-check
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: baseline-check
  namespace: default-check
  labels:
    app: baseline-check
spec:
  serviceAccountName: check-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec  # busybox:1.37
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: data
          mountPath: /data
  volumes:
    - name: tmp
      emptyDir: {}
    - name: data
      persistentVolumeClaim:
        claimName: data
EOF
kubectl wait --for=condition=Ready pod/baseline-check -n default-check --timeout=120s
```

<!-- gate: output -->
```text
serviceaccount/check-sa created
persistentvolumeclaim/data created
pod/baseline-check created
# ...
pod/baseline-check condition met
```

The claim stays `Pending` until a Pod uses it, because the `standard`
StorageClass binds a volume on first use. Then the provisioner creates the
volume through a helper Pod, and the claim is `Bound`:

```sh
kubectl get pvc data -n default-check
kubectl get pod baseline-check -n default-check
kubectl exec -n default-check baseline-check -- sh -c 'echo stored > /data/check && cat /data/check'
VOLUME=$(kubectl get pvc data -n default-check -o jsonpath='{.spec.volumeName}')
kubectl -n local-path-storage logs deploy/local-path-provisioner | grep -o "create the helper pod helper-pod-create-$VOLUME into local-path-storage"
```

<!-- gate: output -->
```text
NAME   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
data   Bound    pvc-59587be9-5cec-45fd-a067-cb7cab60febe   64Mi       RWO            standard       <unset>                 9s
# ...
NAME             READY   STATUS    RESTARTS   AGE
baseline-check   1/1     Running   0          9s
# ...
stored
# ...
create the helper pod helper-pod-create-pvc-59587be9-5cec-45fd-a067-cb7cab60febe into local-path-storage
```

The helper Pod has no `securityContext`, so the default would refuse it in
any namespace but an exempt one. That is why `local-path-storage` is on the
exemption list. CoreDNS lives in `kube-system`, which is exempt too. Check
that it runs and that the Pod resolves a Service name through it. The `tr`
turns the tabs that busybox prints into spaces:

```sh
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl exec -n default-check baseline-check -- nslookup kubernetes.default.svc.cluster.local | tr '\t' ' '
```

<!-- gate: output -->
```text
NAME                       READY   STATUS    RESTARTS   AGE
coredns-559f6c778d-78zvt   1/1     Running   0          64m
coredns-559f6c778d-hh8js   1/1     Running   0          64m
# ...
Server:  10.96.0.10
Address: 10.96.0.10:53
# ...
Name: kubernetes.default.svc.cluster.local
Address: 10.96.0.1
```

An exception is a label. The next namespace asks for `privileged` on purpose,
and it keeps `audit` and `warn` at `restricted` so that the gap stays visible.
The same privileged Pod that the unlabelled namespace refused is now admitted:

```sh
kubectl create namespace privileged-check
until kubectl -n privileged-check get serviceaccount default >/dev/null 2>&1; do sleep 1; done
kubectl label namespace privileged-check \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
kubectl run privileged-probe -n privileged-check --image="$BUSYBOX" \
  --restart=Never --privileged -- sleep 3600
```

<!-- gate: output -->
```text
namespace/privileged-check labeled
# ...
Warning: would violate PodSecurity "restricted:latest": privileged (container "privileged-probe" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "privileged-probe" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "privileged-probe" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "privileged-probe" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "privileged-probe" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/privileged-probe created
```

The label overrode the default for `enforce` and nothing else, so `warn` still
prints the `restricted` findings while the Pod is admitted. A label above
`restricted` is an exception, and this guide records every one in
`security/namespace-exceptions.yaml`, at the root of the repository, with a
reason, the chapter that explains it and an expiry date.
[Part 00 ch.08](08-security-foundations.md) says how the registry works.
`privileged-check` has its entry, and CI checks the entries against the
labels in both directions. Remove the two check namespaces:

```sh
kubectl delete namespace default-check privileged-check
```

The `bookstore` namespace in step 7 still carries its own `restricted`
label, although the default would give the same answer. The label says what
you meant, and a cluster without the default honours it too.

### 5. kubeconfig & contexts

`kubectl` itself is stateless; **kubeconfig** (`~/.kube/config`, or
`$KUBECONFIG`) tells it where and as whom to connect. Three lists plus a
pointer:

```
kubeconfig (~/.kube/config)
├── clusters:   [ { name, server: https://…:6443, certificate-authority } , … ]
├── users:      [ { name, client-cert / token / exec-plugin (cloud auth) }  , … ]
├── contexts:   [ { name, cluster: <CLUSTERS.NAME>, user: <USERS.NAME>, namespace } , … ]
└── current-context: <CONTEXTS.NAME>     ← the (cluster + user + ns) kubectl uses NOW
```

A **context** binds a cluster + a user + a default namespace. Switching
clusters/identities is switching context — *no flags on every command*:

```sh
kubectl config get-contexts                       # all contexts; * marks current
kubectl config current-context                    # → kind-bookstore
kubectl config use-context kind-bookstore         # switch the active context
kubectl config set-context --current --namespace=default   # set default ns for this context
```

The kubeconfig is a credential. It holds the client certificate and key, or
the token, that identify you to the API server. The
[kubeconfig docs](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
list both forms. Anyone who can read the file acts as you, so keep it private
(`chmod 600 ~/.kube/config`) and out of version control. A managed cluster can
issue a short-lived token through an exec plugin, such as `aws eks get-token`,
rather than a static key.

The context is the other half of the risk. Before a command that changes state,
run `kubectl config current-context` and read the answer. A shell prompt, or a
tool such as [kubectx](https://github.com/ahmetb/kubectx), shows the context on
every line, so the check does not depend on memory.

> **In production:** one kubeconfig typically holds *many* contexts (dev,
> staging, prod, several clouds), so the check matters more with each one.
> [Part 07](../07-delivery/04-gitops-argocd.md) replaces hand-run `apply` with
> changes reviewed in Git.

### 6. `kubectl` basics (the everyday verbs)

These are ~90% of daily use; you'll repeat them in every later chapter:

```sh
kubectl get <KIND> [name] [-o wide|yaml|json]   # list/show (spec+status)
kubectl describe <KIND> <NAME>                  # human view + Events (debug start here)
kubectl logs <POD> [-c <CTR>] [-f] [--previous] # stdout/stderr (--previous = crashed ctr)
kubectl exec -it <POD> [-c <CTR>] -- sh         # needs a shell in the image
kubectl apply -f <file|dir>                     # declarative create/update (ch.06)
kubectl delete -f <FILE>                        # delete what a manifest declared
kubectl port-forward <pod|svc> <LOCAL>:<REMOTE> # tunnel to a Pod/Service from your laptop
kubectl get events --sort-by=.lastTimestamp     # the reconciliation loop, narrated
kubectl explain <KIND>.spec                     # authoritative schema (ch.06)
```

The catalog image has no shell, so `exec -- sh` fails on it. It is built on a
[distroless](https://github.com/GoogleContainerTools/distroless) base, which ships
no shell by default. The probe Pod in step 8 is where you run commands from
inside the cluster.

`describe` + `logs` + `events` are the troubleshooting trident — internalize
them now ([Part 08 ch.03](../08-day-2-operations/03-troubleshooting-playbook.md)
goes deep).

### 7. Create the namespace, load the image, and deploy the first Bookstore Pod

The Pod needs two things the cluster does not have yet. The first is a
`bookstore` namespace that enforces Pod Security `restricted`, so the API
server refuses a Pod that drops the baseline. The second is the `catalog-sa`
ServiceAccount the Pod runs as. Create both first. This step runs from the
`full-guide/` directory, which the paths below assume.

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: bookstore
  labels:
    app.kubernetes.io/part-of: bookstore
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog-sa
  namespace: bookstore
  labels:
    app: catalog
    app.kubernetes.io/part-of: bookstore
automountServiceAccountToken: false
EOF
```

<!-- gate: output -->
```text
# ...
serviceaccount/catalog-sa created
```

- **`pod-security.kubernetes.io/enforce: restricted`** makes the API server
  refuse any Pod in the namespace that lacks the fields `restricted` requires.
  `warn` prints the same findings to the client. The
  [namespace control](../01-core-workloads/01-pods.md#baseline-namespace)
  explains the levels.
- **`automountServiceAccountToken: false`** keeps the API token out of the Pod,
  so a compromised process has no token to present to the API server. The
  [ServiceAccount baseline](../01-core-workloads/01-pods.md#baseline-service-account)
  has the rest of the reasoning.
- **The Pod's `securityContext`, `resources` and `emptyDir` fields** complete
  the baseline. [01.01](../01-core-workloads/01-pods.md#baseline) explains each
  one against the threat it answers.

The Pod manifest was written and validated in
[ch.06](06-declarative-api-model.md):
[`raw-manifests/01-catalog-pod.yaml`](../examples/bookstore/raw-manifests/01-catalog-pod.yaml).
It uses `image: bookstore/catalog:dev` with `imagePullPolicy: IfNotPresent`.
That image lives only on your laptop ([ch.02](02-containers-and-images.md)),
not in any registry, so you must **load it into the kind node**. Without it,
the kubelet fails with `ImagePullBackOff`.

```sh
# Build the image if you haven't (ch.02).
docker build -t bookstore/catalog:dev examples/bookstore/app/catalog

# Make the image available INSIDE the kind node container.
kind load docker-image bookstore/catalog:dev --name bookstore
docker exec bookstore-control-plane crictl images | grep bookstore/catalog

# (Optional) re-validate the manifest client-side before applying (ch.06)
kubectl apply --dry-run=client -n bookstore \
  -f examples/bookstore/raw-manifests/01-catalog-pod.yaml

# Declare the desired state for real → triggers the ch.03/ch.05 lifecycle
kubectl apply -n bookstore -f examples/bookstore/raw-manifests/01-catalog-pod.yaml

# Watch the reconciliation loop converge: Pending → ContainerCreating → Running
kubectl get pod catalog -n bookstore -w
```

The node lists the image. The `dev` line is the one you need:

<!-- gate: output -->
```text
# ...
docker.io/bookstore/catalog                     dev                  1fd7038d36fd7       7MB
```

Once the Pod shows `Running`, it reports the state below:

<!-- gate: output -->
```text
NAME      READY   STATUS    RESTARTS   AGE
catalog   1/1     Running   0          26s
```

When `STATUS` is `Running` and `READY` is `1/1`, reach the app the way you did
with plain `docker run` in [ch.02](02-containers-and-images.md), but now it is a
real Pod scheduled by Kubernetes:

```sh
# Tunnel local :8080 → the Pod's container :8080
kubectl port-forward -n bookstore pod/catalog 8080:8080
```

In another terminal, ask the app for its health:

```sh
curl -s localhost:8080/healthz ; echo
```

<!-- gate: output -->
```text
{"status":"ok"}
```

```sh
curl -s localhost:8080/readyz ; echo
```

<!-- gate: output -->
```text
{"status":"ready"}
```

`/readyz` reports ready because `DB_DSN` is unset. The app then serves an
in-memory catalog and has no database to ping, as its log says in the next
block. The `/books` endpoint returns that catalog:

```sh
curl -s localhost:8080/books | head -c 160; echo
```

Now connect it to the internals you learned:

```sh
kubectl get pod catalog -n bookstore -o wide    # which node (kubelet, ch.05) runs it
kubectl describe pod catalog -n bookstore       # Events: scheduled → pulled → created → started
kubectl logs catalog -n bookstore | head -2     # the first lines of the Go app's JSON logs

# Peek at the data plane directly: kind nodes ARE containers (ch.05)
docker exec -it bookstore-control-plane crictl pods   # the catalog Pod + its pause sandbox
docker exec -it bookstore-control-plane crictl ps     # the running app container
```

<!-- gate: output -->
```text
{"time":"2026-10-30T22:12:29.402356908Z","level":"INFO","msg":"DB_DSN unset; serving in-memory sample books"}
{"time":"2026-10-30T22:12:29.404990035Z","level":"INFO","msg":"catalog listening","addr":":8080"}
```

You've now executed the *entire Part 00 arc against a real cluster*:
declarative `spec` ([ch.06](06-declarative-api-model.md)) → API server pipeline
→ etcd ([ch.04](04-control-plane-deep-dive.md)) → scheduler bind
([ch.04](04-control-plane-deep-dive.md)) → kubelet/CRI sandbox+container
([ch.05](05-node-components.md)) → status reported → traffic served. Everything
after this *adds* to this Pod.

### 8. Prove a NetworkPolicy is enforced

The API server stores a NetworkPolicy without checking that anything enforces
it. The [Kubernetes docs](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
say a policy has no effect unless a controller implements it. A cluster whose
network plugin ignores policies therefore fails open: the object exists, and
traffic flows anyway. The reliable check is a connection, so this step makes
one before the policy, under it, and after it is removed.

kind v0.33.0 enforces NetworkPolicy out of the box. Its default CNI, kindnetd,
has carried that support since
[kind v0.24.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0),
so this cluster needs no plugin swap. Allow rules and the default-deny pattern
are the subject of [02.06](../02-networking/06-network-policies.md).

First, a probe: a second Pod with its own ServiceAccount and the same baseline
as the catalog. Its image is pinned by digest, with the tag in the comment. The
image declares no user, so the baseline sets UID 65534 explicitly.

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe-sa
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: bookstore
  labels:
    app: probe
spec:
  serviceAccountName: probe-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec  # busybox:1.37
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF
kubectl wait --for=condition=Ready pod/probe -n bookstore --timeout=120s
CATALOG_IP=$(kubectl get pod catalog -n bookstore -o jsonpath='{.status.podIP}')
kubectl exec -n bookstore probe -- wget -qO- -T 3 "http://$CATALOG_IP:8080/healthz"
```

Without a policy, the request succeeds:

<!-- gate: output -->
```text
{"status":"ok"}
```

Next, a default-deny policy. It selects every Pod in the namespace and allows
no ingress to any of them:

```sh
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: bookstore
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
EOF
```

<!-- gate: output -->
```text
networkpolicy.networking.k8s.io/default-deny-ingress created
```

Now repeat the request. This failure is deliberate: the policy is meant to deny
it.

```sh
kubectl exec -n bookstore probe -- wget -qO- -T 3 "http://$CATALOG_IP:8080/healthz"
```

<!-- gate: output -->
```text
wget: download timed out
command terminated with exit code 1
```

A plugin that ignored the policy would have printed the same JSON as before, so
the timeout is the evidence. Remove the policy:

```sh
kubectl delete networkpolicy default-deny-ingress -n bookstore
```

Now the same request works again:

```sh
kubectl exec -n bookstore probe -- wget -qO- -T 3 "http://$CATALOG_IP:8080/healthz"
```

<!-- gate: output -->
```text
{"status":"ok"}
```

Then remove the probe:

```sh
kubectl delete pod probe -n bookstore
```

### 9. Tear down (and reset any time)

A local cluster is disposable — deleting and recreating is the normal way to
get a clean slate:

```sh
kind delete cluster --name bookstore
```

(Deleting the cluster also removes its kubeconfig context.)

## How it works under the hood

- **`kind create cluster` = run node container(s) + bootstrap real Kubernetes
  in them.** kind uses a prebuilt node image containing kubelet, containerd,
  and the control-plane components, then runs `kubeadm` *inside* to bring up
  etcd, the API server, controller-manager, and scheduler — the genuine
  binaries from [ch.03](03-architecture-overview.md)/[ch.04](04-control-plane-deep-dive.md).
- **`kubectl` is a pure REST client.** It reads kubeconfig to find the API
  server URL and credentials, then makes the same HTTPS calls any controller
  makes (and gets the same authN→authZ→admission→validation pipeline,
  [ch.04](04-control-plane-deep-dive.md)). `kubectl apply` is client logic on
  top of that REST API ([ch.06](06-declarative-api-model.md)).
- **`kind load` exists because there's no shared registry.** Normally the
  kubelet pulls images from a registry ([ch.02](02-containers-and-images.md)
  pull flow). Locally, your image is only in your laptop's Docker engine, so
  `kind load` copies it *into the node container's containerd image store*;
  `imagePullPolicy: IfNotPresent` ([ch.06](06-declarative-api-model.md)) then
  makes the kubelet use that local copy instead of contacting a registry.
- **`port-forward` is a tunnel through the API server**, not a Service. The API
  server proxies a connection to the kubelet, which forwards to the Pod's
  port. It's a debugging convenience; real exposure uses Services/Ingress
  ([Part 02](../02-networking/02-services.md)) — which is why this works even
  with no cloud load balancer.

## Production notes

> **In production:** you do **not** run `kind`. The cluster is provisioned by a
> managed service (EKS/GKE/AKS) or a tool like kubeadm/Cluster API on real
> machines ([Part 08 ch.01](../08-day-2-operations/01-cluster-lifecycle.md)).
> kind is for *local dev and CI*: it is excellent in CI, with ephemeral
> clusters per pipeline run. The **API and objects are identical**; only
> provisioning and substrate differ.

> **In production:** a managed control plane may not let you set the API
> server's flags, so there may be no admission file to edit. The equivalent is a
> Pod Security label on every namespace, applied by automation, and a policy
> that refuses a namespace with no `enforce` label.
> [05.09](../05-security/09-running-security-on-a-platform-team.md) builds a
> rule of that kind. The cluster-wide default is a setting for kind and for
> clusters you run yourself. The labels are what travels everywhere.

> **In production:** `Service` type `LoadBalancer` and dynamic `PersistentVolume`
> provisioning **don't work on bare kind** (no
> [cloud-controller-manager](04-control-plane-deep-dive.md), no cloud CSI). You
> use `port-forward`/NodePort and local-path storage locally; the cloud
> provides real LBs and disks. Every chapter's `In production:` callouts flag
> these substrate gaps — the manifests themselves stay the same.

> **In production:** a bare Pod like this one is **not** what you deploy — it
> isn't rescheduled on node loss or recreated on permanent crash. It's a Part
> 00 teaching artifact; [Part
> 01](../01-core-workloads/04-replicasets-and-deployments.md) replaces it with
> a self-healing Deployment.

## Quick Reference

```sh
# cluster lifecycle (local; run from full-guide/)
kind create cluster --name bookstore \
  --config examples/security-lab/kind/cluster-restricted-default.yaml
kind delete cluster --name bookstore
kind load docker-image <img> --name bookstore

# context / kubeconfig
kubectl config get-contexts                  # list contexts (* = current)
kubectl config current-context               # which cluster/user am I on?
kubectl config use-context <NAME>            # switch context
kubectl config set-context --current --namespace=<NS>   # default namespace

# verify
kubectl cluster-info ; kubectl get nodes -o wide ; kubectl get --raw=/readyz

# everyday verbs
kubectl apply -f <F> ; kubectl get <K> ; kubectl describe <K> <N>
kubectl logs <POD> [-f|--previous] ; kubectl exec -it <POD> -- sh
kubectl port-forward pod/<P> 8080:8080 ; kubectl delete -f <F>
```

Smallest end-to-end loop (the thing to remember):

```
# run from the guide directory (full-guide/)
docker build -t bookstore/catalog:dev examples/bookstore/app/catalog   # ch.02 image
kind create cluster --name bookstore \
  --config examples/security-lab/kind/cluster-restricted-default.yaml
kind load docker-image bookstore/catalog:dev --name bookstore   # no registry locally
# step 7: create the bookstore namespace and catalog-sa first (heredoc)
kubectl apply -n bookstore -f examples/bookstore/raw-manifests/01-catalog-pod.yaml   # declare (ch.06)
kubectl get pod catalog -n bookstore -w                  # watch the loop converge
kubectl port-forward -n bookstore pod/catalog 8080:8080 && curl localhost:8080/healthz
```

Setup checklist:

- [ ] `kubectl` installed, within ±1 minor of the cluster
- [ ] Docker/Colima engine running before `kind create cluster`
- [ ] Cluster up from `cluster-restricted-default.yaml`; all nodes `Ready`;
  kube-system Pods running
- [ ] An unlabelled namespace refused a privileged Pod, admitted a Pod with
  the baseline, and bound a claim through the storage provisioner
- [ ] You confirm `current-context` before any mutating command
- [ ] Namespace `bookstore` enforces `restricted`; `catalog-sa` exists
- [ ] Local image `kind load`ed (matches `imagePullPolicy: IfNotPresent`)
- [ ] `catalog` Pod `Running 1/1`; `/healthz` returns `{"status":"ok"}`
- [ ] A probe's request was denied under the default-deny policy, and
  worked again once the policy was deleted
- [ ] You can tear down and recreate from scratch (cluster is disposable)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Why does the `catalog` manifest use `imagePullPolicy: IfNotPresent` for local kind use, and what would go wrong with `Always`?**
   <details><summary>Show answer</summary>

   `bookstore/catalog:dev` only exists in your laptop's Docker engine and `kind load` copies it into the node container's containerd image store. With `Always`, the kubelet would contact a registry every time — but there is none for `bookstore/catalog:dev`, so it fails `ImagePullBackOff`. `IfNotPresent` makes the kubelet use the loaded local copy and skip the registry round-trip (see §Hands-on step 7, and §How it works under the hood, `kind load`).

   </details>

2. **A teammate runs `kubectl apply` and accidentally targets the production cluster instead of dev. What single shell-level habit could have prevented this, and what's the deeper architectural reason a stronger mechanism (GitOps) is preferable?**
   <details><summary>Show answer</summary>

   Always confirm `kubectl config current-context` before any mutating command, or use a shell prompt segment / kubectx to make context visible. The deeper fix is GitOps: changes go through a reviewed pull request, and an Argo CD/Flux controller running *in* the target cluster reconciles from Git — there is no human typing apply at prod (see §kubeconfig & contexts, §Production notes).

   </details>

3. **You run `kubectl port-forward pod/catalog 8080:8080` on a brand-new kind cluster with no `Service` and no cloud load balancer. Why does this work, and why is it explicitly not how you'd expose the Pod in production?**
   <details><summary>Show answer</summary>

   `port-forward` is a tunnel through the API server: kubectl opens an HTTPS connection to the API server, which proxies to the kubelet, which forwards to the Pod's container port. It needs no Service or LB. In production you don't want every user holding open an API-server tunnel — you use Services and Ingress so traffic flows through the data plane, not the control plane (see §How it works under the hood, port-forward).

   </details>

4. **A teammate says, "We applied a NetworkPolicy, so the Pods are isolated." The API server accepted it without complaint. What do you check before you believe them?**
   <details><summary>Show answer</summary>

   The API server stores a NetworkPolicy whether or not the cluster's network
   plugin enforces it, so acceptance proves nothing. The Kubernetes docs say a
   policy has no effect without a controller that implements it. Check with a
   connection, as step 8 does: a probe's request should succeed before the
   policy and be denied under it. A request that still succeeds under the
   policy means the plugin ignores the policy, and the cluster fails open (see
   §Threats and controls).

   </details>

5. **Hands-on extension: bring up the cluster, deploy the catalog Pod, then `kind delete cluster --name bookstore` and `kind create cluster --name bookstore` again. Re-run `kubectl get pod catalog -n bookstore`. What's gone, and what's the point of this exercise?**
   <details><summary>What you should see</summary>

   Everything the cluster held is gone: the catalog Pod, the namespace, the
   ServiceAccount, and the etcd data behind them. `kubectl get pod catalog -n
   bookstore` returns `NotFound`, because the namespace no longer exists. The
   point: local clusters are cattle, not pets. Treating "reset to clean" as a
   one-command operation is a deliberate workflow that mirrors how production
   clusters should be reproducible from manifests in Git, not by accumulated
   hand-applied state (see §Tear down (and reset any time), §Production
   notes).

   </details>

6. **A teammate runs `kubectl create namespace tools` and applies a vendor's Pod that runs as root. What happens on this chapter's cluster, what happens on a stock kind cluster, and why do the guide's own namespaces still carry labels?**
   <details><summary>Show answer</summary>

   On this cluster the new namespace has no labels, so it takes the
   `restricted` default, and the API server refuses the Pod and names the
   fields that broke the level (step 4). On a stock kind cluster the default
   is `privileged`, so the Pod is admitted without a word. The labels stay
   because they are the first line of defence: they say what each namespace is
   for, they travel with the manifests to a cluster that has no default, and
   an exception is a label that the registry records. The default is the last
   line, for the namespace nobody labelled (see §Why `restricted` is the
   cluster default).

   </details>

## Further reading

- **Poulton, _The Kubernetes Book_, ch.3 (and its setup appendix)** — getting a
  local cluster and `kubectl` working, first deployment.
- **Lukša, _Kubernetes in Action_ 2e, ch.3 — "Deploying your first
  application"** — kubeconfig/contexts, the core `kubectl` verbs, and watching
  the first workload come up.
- Official: kind <https://kind.sigs.k8s.io/docs/user/quick-start/>,
  `kubectl` install <https://kubernetes.io/docs/tasks/tools/>, and the kubectl
  cheatsheet <https://kubernetes.io/docs/reference/kubectl/cheatsheet/>.
- NetworkPolicy: the kind v0.24.0 release notes for out-of-the-box support
  <https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0>, and the
  Kubernetes docs <https://kubernetes.io/docs/concepts/services-networking/network-policies/>.
