# 02 — Logging

> The Kubernetes logging architecture (stdout and stderr to CRI files on the
> node, with **no built-in cluster logging**), the node agent pattern
> (a DaemonSet that reads pod logs and ships them to a store), the sidecar
> pattern and when *not* to use it, structured JSON logging, and the controls
> that keep secrets and personal data out of logs and out of the store.
> Applied by shipping the Bookstore's JSON logs into Loki through a locked
> down agent, then planting a fake secret to show what reaches the store.

**Estimated time:** ~20 min read · ~60 min hands-on
**Prerequisites:** [Part 06 ch.01](01-observability-metrics.md), metrics show *that* it broke and logs show *why* · [Part 01 ch.06](../01-core-workloads/06-daemonsets.md), the node agent pattern · [Part 01 ch.01](../01-core-workloads/01-pods.md), stdout and stderr are the container log boundary · [Part 02 ch.06](../02-networking/06-network-policies.md), the policies that lock the store
**You'll know after this:** • explain why Kubernetes has no cluster logging and what fills the gap · • keep secrets and personal data out of logs, at the source and in the pipeline · • deploy a log agent that runs at `restricted` and reads through the API, not hostPath · • lock a log store so that only the agent writes and only Grafana reads · • name who can read the raw lines, and why an agent's RBAC is also a read path

<!-- tags: observability, day-2, security, opentelemetry -->

## Why this exists

[ch.01](01-observability-metrics.md) tells you that catalog's error rate rose.
Logs tell you why this one request failed: the stack trace, the bad input, the
database timeout. Metrics are aggregates; logs are the event detail.

Kubernetes has no cluster logging system. The container runtime captures a
container's stdout and stderr to a file on the node, and `kubectl logs` reads
that file. There is no aggregation, no search across Pods, and no retention
beyond the node. The logs are gone when the Pod is deleted or the node is
recycled. Centralised logging is something you add, with a node agent that
ships those files to a store.

Adding a store creates a new exposure. A value the app wrote to stdout is now
in the node file, in the agent's stream, in the store, and in every backup of
the store. One service that logs a token can expose tokens from every service
that reads the same store. So the controls come in order: what the app writes,
what the agent keeps, who can query the store, and who can read the raw node
files.

## Mental model

Follow one log line:

1. The Bookstore Go service writes a **JSON line to stdout**. It already does:
   `slog.NewJSONHandler(os.Stdout, ...)` in `app/catalog/main.go`.
2. The container runtime (containerd, via the CRI) captures stdout and stderr
   and writes them to `/var/log/pods/<NS>_<POD>_<UID>/<CONTAINER>/0.log`, in
   the CRI format. The file is raw. Nothing has been removed from it.
3. `kubectl logs` streams that file back for one Pod, now. Anyone with
   `pods/log` in the namespace reads the raw line.
4. A **node agent**, one Pod per node, which is a DaemonSet
   ([Part 01 ch.06](../01-core-workloads/06-daemonsets.md)), reads each
   container's log, attaches Kubernetes metadata, and pushes to a store: Loki,
   Elasticsearch or a cloud service. The agent in this chapter reads through
   the API server, so it needs no hostPath.
5. You query the store by label and time, as you query metrics.

Each step is a control point, and the rules below follow them in order:

- **Step 1, the app.** Only the app can keep a value out of the line. After
the write, the only cleanup left is in the store, and the node file keeps the
raw text.
- **Step 3, RBAC.** `pods/log` decides who reads the raw line on the node.
- **Step 4, the agent.** The agent can remove values before they are pushed.
- **Step 5, the store.** The network path and the query path decide who reads
the copy.

Three architectures, and when each applies:

- **Node agent (DaemonSet), the default.** One agent per node reads every
container's output. No per-app change, lowest overhead.
- **Sidecar.** An extra logging container in the Pod. Use it only when the app
*cannot* write stdout, for example a legacy app that writes a file inside the
container. It costs a container per Pod, so it is the last resort.
- **App ships directly.** The app library sends logs to the backend over the
network itself. This couples the app to the vendor, and logs are lost when the
app crashes with a batch still buffered. Generally an anti-pattern.

## Threats and controls

| Threat | Control taught here | Goes deeper |
|---|---|---|
| A secret or personal data reaches stdout | The service logs IDs and error classes, never values. The agent replaces a token and a URL password before the push. | [03.02](../03-config-and-storage/02-secrets.md) |
| Anyone who can reach the store reads all of it | Loki takes writes from the agent and reads from Grafana only, enforced by a NetworkPolicy. | [02.06](../02-networking/06-network-policies.md) |
| The agent can read every namespace's logs | A ClusterRole with `pods` read and `pods/log` get, no hostPath, namespace at `restricted`. The file-tailing variant and its exception are in [01.06](../01-core-workloads/06-daemonsets.md). | [05.01](../05-security/01-authn-authz-rbac.md) |
| A chart grants more than the agent needs | The values turn off the chart's sidecar, which would read every ConfigMap and Secret, and the chart's own RBAC. | [05.01](../05-security/01-authn-authz-rbac.md) |
| Whoever holds `pods/log` reads the raw lines | Namespaced read grants to named ServiceAccounts only. Removal at the source is the real fix. | [05.01](../05-security/01-authn-authz-rbac.md) |
| Old logs keep a leaked value readable | Seven-day retention in the Loki values. | (none) |
| A compromised agent sends the logs it reads to any HTTPS endpoint, because its API egress names no destination | Residual in this chapter's policy. In production, scope the API rule with an `ipBlock` for the API server address. | [05.01](../05-security/01-authn-authz-rbac.md) |
| Log lines cross the cluster network in cleartext, from the agent to Loki | Accepted in this chapter. The push stays on the cluster network, and the NetworkPolicy admits only the agent and Grafana to Loki. TLS on that hop belongs with workload TLS in [11.04](../11-advanced-production-patterns/04-service-mesh.md). | [11.04](../11-advanced-production-patterns/04-service-mesh.md) |

## Diagrams

### A log line: container to stdout to CRI file to agent to store (Mermaid)

```mermaid
flowchart LR
    subgraph node["Each node"]
      app["catalog container<br/>slog JSON to stdout"]
      cri["containerd (CRI)<br/>raw file in /var/log/pods"]
      agent["alloy (DaemonSet)<br/>reads pods/log, redacts"]
    end
    api["kube-apiserver<br/>RBAC on pods/log"]
    subgraph store["logging namespace"]
      loki["Loki<br/>NetworkPolicy: agent writes, Grafana reads"]
    end
    graf["Grafana<br/>(LogQL)"]
    kctl["kubectl logs<br/>(raw line, RBAC on pods/log)"]

    app --> cri
    cri -.-> kctl
    api -->|log stream| agent
    agent -->|push| loki
    graf -->|query| loki
```

### Logging architecture options (ASCII)

```
 OPTION A: NODE AGENT (DaemonSet)            <- default, use this
   app -> stdout -> CRI file -> [agent per node] -> store
   + no app change  + 1 agent per node  + survives Pod death
   - the agent reads every namespace's logs: a privileged position, so it
     needs the strictest RBAC and the tightest store access

 OPTION B: SIDECAR
   app -> file in Pod -> [sidecar in same Pod] -> store
   + works for apps that cannot use stdout
   - one more container per Pod (cost, complexity); only when A is impossible

 OPTION C: APP SHIPS DIRECTLY
   app --(vendor SDK over network)--> store
   - couples the app to the backend; logs lost on crash or buffer; anti-pattern

 WHY NOT A FILE INSIDE THE CONTAINER:
   the writable layer dies with the Pod; readOnlyRootFilesystem (Part 05
   ch.02) forbids it anyway; nothing tails it. stdout is the contract.
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).**

The output in this chapter came from a lab cluster whose name differs from
yours, and from namespaces with a different name prefix. Everything else is
verbatim. The lab script `examples/security-lab/labs/06-02.sh` runs these
steps on a kind cluster you own and keeps the transcript in
`examples/security-lab/evidence/06-02.txt`.

We will: (1) see what the services already write; (2) show what the app does
with a value it should never log; (3) remove values at the source, then at the
agent; (4) run Loki and an Alloy agent that reads through the API; (5) query
one request; (6) show the denied paths; (7) show what a log reader can see.

### 0. Prerequisites

Bring up the Bookstore as the earlier chapters did: the `bookstore` namespace
with ServiceAccounts, config, redis, postgres, catalog, orders, the Services
and the network policies. The Deployments name the Part 04 priority classes,
so those must exist first.

```sh
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml \
  -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml \
  -f examples/bookstore/raw-manifests/15-catalog-config.yaml \
  -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml \
  -f examples/bookstore/raw-manifests/20-postgres-statefulset.yaml \
  -f examples/bookstore/raw-manifests/40-services.yaml \
  -f examples/bookstore/raw-manifests/60-networkpolicy.yaml
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml \
  -f examples/bookstore/raw-manifests/14-orders-deploy.yaml
kubectl -n bookstore rollout status deploy/catalog
kubectl -n bookstore rollout status deploy/orders
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl -n bookstore wait --for=condition=complete job/db-migrate
```

The migrate Job creates the `orders` table. Without it, orders cannot persist
an order, so `POST /orders` fails with a 500 and writes no `order placed` line.

### 1. See what the services already write

```sh
kubectl logs -n bookstore deploy/catalog --tail=2
kubectl logs -n bookstore deploy/orders --tail=2
```

Each line is one event with fixed fields: `time`, `level`, `msg`, and then the
event's own fields. An order placed shows `order_id`, `book_id` and `qty`. The
request body is `{"book_id":1,"qty":2}`, which holds no personal data. The
schema stays stable, so you filter on `level` or `order_id` rather than grep
free text.

Decide what may appear before you write any log call. The list is short:

- **Credentials.** Passwords, tokens, API keys, and any DSN or URL that holds
a password.
- **Personal data.** Names, emails, card numbers, addresses. Today's order
request carries none. The rule still applies the day a field is added.
- **Anything a dump would expose.** Request headers, whole environment maps,
and whole request bodies.

Log IDs, counts, durations and error classes. Those are what the queries need.

### 2. A value the app should never log (deliberate)

This Pod is a deliberate failure, labelled so you can tell it from the
hardened workloads. It hands the orders service a DSN in URL form with an
invalid escape (`%zz`). The password comes from a Secret, the way the example
builds `DB_DSN`, so it never appears in the manifest. The service cannot parse
the DSN and logs the failure.

```sh
kubectl -n bookstore create secret generic dsn-demo \
  --from-literal=PASSWORD=FAKE-PLANTED-PASSWORD
```

Save this Pod as `dsn-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dsn-demo
  namespace: bookstore
  labels:
    app: dsn-demo
spec:
  serviceAccountName: orders-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: orders
      image: bookstore/orders:dev
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: PORT
          value: "8080"
        - name: PW
          valueFrom:
            secretKeyRef: { name: dsn-demo, key: PASSWORD }
        - name: DB_DSN
          value: "postgres://app:$(PW)%zz@localhost:5432/books"
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { memory: 128Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
```

```sh
kubectl apply -f dsn-demo.yaml
kubectl -n bookstore logs dsn-demo --tail=3
```

<!-- gate: output -->
```text
{"time":"2026-10-31T14:14:05.407565098Z","level":"ERROR","msg":"connect postgres","error_class":"dsn_parse"}
```

The line names the class of the failure, `dsn_parse`, and nothing else. The
driver's own message for this DSN quotes it with the password masked as
`xxxxxx`. That masking is the library's behaviour in this version, not a
control you own, so the services do not lean on it. On the connect path,
`orders` and `catalog` log the class that `errClass` returns (`dsn_parse`,
`timeout`, `network` or `other`) and never the driver's text. The rule that
holds for every version is that no DSN reaches a log call at all. Other log
calls in the services still pass the driver's error: the readiness probes and
the query paths ([01.02](../01-core-workloads/02-health-and-lifecycle.md) shows
the Redis dial error that `readyz` logs). They are not on the connect path and
this chapter does not change them.

### 3. Remove values at the source first

The app is the only place that knows what a value is, so it removes values
first. Four habits do most of the work:

- **Log IDs and error classes.** Log `order_id`, not the whole order. Log
"dsn parse failed" and the class of error, not the text that carries the
input.
- **Keep secrets as references.** Env vars that come from a Secret stay
references. Never copy a secret value into a log field, a config string or a
debug print.
- **Never log input "for debugging".** The debug line is the one that ships to
production. If an error can echo its input, log a fixed message and keep the
error text out.
- **Clean the node file at the source.** The runtime writes what the app
wrote. Only the app can make the node file safe, so this habit matters even
when the agent also redacts.

### 4. Run a log agent that reads through the API

#### 4.1 The namespace, the agent's RBAC and the network path

The `logging` namespace enforces `restricted`, like every other namespace in
this guide. The agent needs no exception. It reads pod logs through the API
server, so it needs no hostPath and no node file access.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: logging
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alloy
  namespace: logging
automountServiceAccountToken: true   # the agent is an API client: its own token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alloy-log-reader
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alloy-log-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: alloy-log-reader
subjects:
  - kind: ServiceAccount
    name: alloy
    namespace: logging
```

Three points about that RBAC:

- The reach is **every namespace**. `pods/log` in a ClusterRole reads every
container's log, the way a hostPath collector reads every file. So the store
holds everything logged, and it needs the same care as the node. Nothing in
the rule reads Secrets, ConfigMaps or Nodes.
- The ServiceAccount is dedicated and sets `automountServiceAccountToken:
  true`
explicitly, which the baseline allows for a workload that calls the API.
- The chart's own ClusterRole would add rules for nodes and node metrics. The
values below turn it off, so this one is the only grant.

The NetworkPolicies lock the namespace. Loki accepts writes from the agent and
reads from Grafana in `monitoring`. Nothing else reaches port 3100.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: logging
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: logging
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-agent-egress
  namespace: logging
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: alloy
  policyTypes: ["Egress"]
  egress:
    - to:                                  # push to Loki on 3100
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: loki
      ports:
        - { protocol: TCP, port: 3100 }
    # RESIDUAL: no `to`, so any destination on 443 and 6443. Scope it with an
    # ipBlock for the API server address (kubectl get endpoints kubernetes).
    - ports:                               # read logs from the API server
        - { protocol: TCP, port: 443 }
        - { protocol: TCP, port: 6443 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-reads-to-loki
  namespace: logging
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: loki
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:                     # the agent writes
            matchLabels:
              app.kubernetes.io/name: alloy
        - namespaceSelector:               # Grafana reads, from monitoring only
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: grafana
      ports:
        - { protocol: TCP, port: 3100 }
```

The baseline fields for these workloads are explained in
[01.01](../01-core-workloads/01-pods.md#baseline). Save the two blocks above
as `logging-base.yaml` and apply it.

```sh
kubectl apply -f logging-base.yaml
```

#### 4.2 Loki and the Alloy agent

Loki runs in single-binary mode. The values pin its image by digest, run it as
the UID the image declares, and turn off everything this lab does not use.

Save this as `loki-values.yaml`:

```yaml
deploymentMode: SingleBinary
loki:
  image:
    digest: "sha256:44148ad243c07957113baea950ee5ba9b0c8eff8d7e38ff3cc1c0af705790945"  # 3.6.11
  auth_enabled: false
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: filesystem
  limits_config:
    retention_period: 168h
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence:
    size: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
write:
  replicas: 0
read:
  replicas: 0
backend:
  replicas: 0
gateway:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
minio:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
rbac:
  create: false
serviceAccount:
  automountServiceAccountToken: false
sidecar:
  rules:
    enabled: false
monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false
  dashboards:
    enabled: false
  rules:
    enabled: false
  serviceMonitor:
    enabled: false
```

Four of those choices are security decisions, not defaults you can ignore:

- **`auth_enabled: false`.** Loki has no user accounts in this setup, so no
identity is checked on a query. The NetworkPolicy above is the boundary: who
reaches port 3100 reads the logs. Put an authenticating proxy in front before
anyone outside the cluster reads them.
- **The sidecar is off.** The chart's rule sidecar watches ConfigMaps and
Secrets, and the chart grants it read on both in every namespace. This lab
uses no ruler, so the grant is not needed.
- **Retention is 168 hours.** A value that leaks into the store stays readable
until the compactor deletes it, so the window is the exposure.
- **The image's user.** Loki's image declares UID 10001, and the pod uses it.

The Alloy agent is a DaemonSet. Its config reads only the pods on its own
node, redacts two patterns, and pushes to Loki.

Save this as `alloy-values.yaml`:

```yaml
image:
  digest: "sha256:8ab871206bd2d8f89277f53abffee5f452a293980788d52f85fa183a87a505a4"  # v1.21.3
global:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 473                       # the alloy account in the image
    runAsGroup: 473
    seccompProfile:
      type: RuntimeDefault
controller:
  type: daemonset
  volumes:
    extra:
      - name: tmp
        emptyDir: {}
alloy:
  enableReporting: false                 # no usage reports leave the cluster
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  mounts:
    extra:
      - name: tmp
        mountPath: /tmp
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi
  configMap:
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
        selectors {
          role  = "pod"
          field = "spec.nodeName=" + sys.env("K8S_NODE_NAME")
        }
      }

      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.process.redact.receiver]
      }

      loki.process "redact" {
        stage.replace {
          expression = "\"token\":\"([^\"]*)\""
          replace    = "[REDACTED]"
        }
        stage.replace {
          expression = "://[^:/@\\s]+:([^@\\s]+)@"
          replace    = "[REDACTED]"
        }
        forward_to = [loki.write.loki.receiver]
      }

      loki.write "loki" {
        endpoint {
          url = "http://loki.logging.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
rbac:
  create: false
serviceAccount:
  create: false
  name: alloy
configReloader:
  enabled: false
```

The agent's `runAsUser` comes from the image's own `alloy` account, UID 473.
The image declares no user, so the pod sets one. Reading the node's pods needs
no node access, so the namespace stays at `restricted`.

The redaction runs in the agent, after the line leaves the node and before it
reaches the store. It is the second line of defence, and step 3 is the first.
The first pattern replaces a JSON `token` value. The second replaces the
password in a URL.

Install the store and the agent:

```sh
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki --version 7.5.0 --namespace logging \
  -f loki-values.yaml --wait
helm install alloy grafana/alloy --version 1.15.0 --namespace logging \
  -f alloy-values.yaml --wait
kubectl get ds -n logging alloy
kubectl get pods -n logging
```

<!-- gate: output -->
```text
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
alloy   1         1         1       1            1           <none>          65s
NAME          READY   STATUS    RESTARTS   AGE
alloy-s4pt6   1/1     Running   0          65s
loki-0        1/1     Running   0          2m10s
```

Check the agent's reach with the API, not by trusting the manifest:

```sh
kubectl auth can-i get pods/log -n bookstore --as=system:serviceaccount:logging:alloy
kubectl auth can-i list pods -n bookstore --as=system:serviceaccount:logging:alloy
kubectl auth can-i create pods -n bookstore --as=system:serviceaccount:logging:alloy
kubectl auth can-i get secrets -n bookstore --as=system:serviceaccount:logging:alloy
kubectl auth can-i get pods/log -n logging --as=system:serviceaccount:logging:alloy
```

<!-- gate: output -->
```text
yes
yes
no
no
yes
```

The agent reads logs and lists pods. It cannot create Pods or read Secrets, in
any namespace.

### 5. Plant a fake secret, and see what the store keeps

This Pod stands in for an app that logs a token and a DSN with a password. It
is deliberately bad, and it runs at `restricted` like everything else. It
writes one line every five seconds. The values are fake.

Save this Pod as `leaky-app.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: leaky-app-sa
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: leaky-app
  namespace: bookstore
  labels:
    app: leaky-app
spec:
  serviceAccountName: leaky-app-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command:
        - sh
        - -c
        - 'while true; do echo "{\"level\":\"INFO\",\"msg\":\"upstream call\",\"token\":\"FAKE-PLANTED-TOKEN\",\"dsn\":\"postgres://app:FAKE-PLANTED-PASSWORD@localhost:5432/books\"}"; sleep 5; done'
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
```

```sh
kubectl apply -f leaky-app.yaml
kubectl -n bookstore logs leaky-app --tail=1
```

<!-- gate: output -->
```text
{"level":"INFO","msg":"upstream call","token":"FAKE-PLANTED-TOKEN","dsn":"postgres://app:FAKE-PLANTED-PASSWORD@localhost:5432/books"}
```

`kubectl logs` shows the raw line. The node file was never redacted, and that
is why the source matters. Now query the store. The lab has no Grafana, so the
query goes to the Loki API through a port-forward. Grafana's Explore sends the
same LogQL.

```sh
kubectl -n logging port-forward svc/loki 3100:3100 &
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="bookstore", app="leaky-app"} |= "FAKE-PLANTED-PASSWORD"' \
  --data-urlencode 'since=30m' | jq '[.data.result[].values[]] | length'
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="bookstore", app="leaky-app"} |= "FAKE-PLANTED-TOKEN"' \
  --data-urlencode 'since=30m' | jq '[.data.result[].values[]] | length'
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="bookstore", app="leaky-app"} |= "REDACTED"' \
  --data-urlencode 'since=30m' --data-urlencode 'limit=1' | jq -r '.data.result[].values[][1]'
```

<!-- gate: output -->
```text
0
0
```

The redacted line, from the same query for the word REDACTED:

<!-- gate: output -->
```text
{"level":"INFO","msg":"upstream call","token":"[REDACTED]","dsn":"postgres://app:[REDACTED]@localhost:5432/books"}
```

Both secret strings are absent from the store, and the line is there with its
redactions. The store never saw the raw value. The node file still has it, so
anyone with `pods/log` on that namespace still sees it, which step 7 shows.

### 6. One request by label and by a field of the line

Generate traffic from a Pod labelled `app: storefront`. The storefront is the
real caller of orders, so this Pod gets the same network path the storefront
has.

Save this Job as `loadgen.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loadgen-sa
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: batch/v1
kind: Job
metadata:
  name: loadgen
  namespace: bookstore
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: storefront
    spec:
      restartPolicy: Never
      serviceAccountName: loadgen-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: loadgen
          image: curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b  # curlimages/curl:8.10.1
          command:
            - sh
            - -c
            - 'for i in $(seq 1 20); do curl -s -o /dev/null -XPOST http://orders.bookstore.svc.cluster.local/orders -H "Content-Type: application/json" -d "{\"book_id\":1,\"qty\":2}"; done; echo done'
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 64Mi }
```

```sh
kubectl apply -f loadgen.yaml
kubectl -n bookstore wait --for=condition=complete job/loadgen --timeout=180s
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="bookstore", app="orders"} | json | msg="order placed"' \
  --data-urlencode 'since=30m' --data-urlencode 'limit=3' | jq -r '.data.result[].values[][1]'
curl -sG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (level) (count_over_time({namespace="bookstore", app="orders"} | json [30m]))' \
  | jq -r '.data.result[] | "\(.metric.level) \(.value[1])"'
```

<!-- gate: output -->
```text
{"time":"2026-10-31T02:09:36.603258553Z","level":"INFO","msg":"order placed","order_id":17,"book_id":1,"qty":2}
{"time":"2026-10-31T02:09:36.570666227Z","level":"INFO","msg":"order placed","order_id":16,"book_id":1,"qty":2}
{"time":"2026-10-31T02:09:36.54732799Z","level":"INFO","msg":"order placed","order_id":15,"book_id":1,"qty":2}
```

The level counts for the same stream, from the instant query:

<!-- gate: output -->
```text
INFO 23
WARN 11
```

Labels are cheap and content is searched. `namespace`, `app`, `pod` and
`container` are labels, so the store indexes them. `order_id` lives in the
line, so `| json` filters it at query time. A label per request would create
one stream per request and exhaust the index, just as a per-request Prometheus
label would ([ch.01](01-observability-metrics.md)).

### 7. Who can reach the store, and who can read the raw lines

Two Pods are denied. One is in a namespace with no policies of its own. The
other is labelled `app: other` in the Bookstore, where default-deny egress
applies. Both should time out with curl's exit code 28.

```sh
kubectl create namespace client
kubectl label namespace client pod-security.kubernetes.io/enforce=restricted
```

Save this Pod as `probe-client.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe-client-sa
  namespace: client
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: probe-client
  namespace: client
  labels:
    app: client
spec:
  serviceAccountName: probe-client-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  restartPolicy: Never
  containers:
    - name: probe
      image: curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b  # curlimages/curl:8.10.1
      command: ["sh", "-c", "curl -s -m 5 -o /dev/null -w 'status=%{http_code}\\n' http://loki.logging.svc.cluster.local:3100/ready; echo rc=$?"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
```

Save the Bookstore probe as `probe-bookstore.yaml`. It is the same Pod in the
`bookstore` namespace, with `app: other` and its own ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe-bookstore-sa
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: probe-client-sa
  namespace: client
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: probe-bookstore
  namespace: bookstore
  labels:
    app: other
spec:
  serviceAccountName: probe-bookstore-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  restartPolicy: Never
  containers:
    - name: probe
      image: curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b  # curlimages/curl:8.10.1
      command: ["sh", "-c", "curl -s -m 5 -o /dev/null -w 'status=%{http_code}\\n' http://loki.logging.svc.cluster.local:3100/ready; echo rc=$?"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
```

Apply both.

```sh
kubectl apply -f probe-client.yaml -f probe-bookstore.yaml
kubectl -n client logs probe-client
kubectl -n bookstore logs probe-bookstore
```

<!-- gate: output -->
```text
status=000
rc=28
status=000
rc=28
```

Those two denials are the two boundaries: the store refuses a caller it has no
rule for, and the Bookstore refuses to call out to a store it has no rule for.
A policy that allowed the whole cluster would make that first line disappear.

Now the readers. A log reader is anyone who holds `pods/log`. Grant it with a
Role in one namespace, to one named ServiceAccount.

Save this as `log-reader.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-reader
  namespace: bookstore
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: log-reader
  namespace: bookstore
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: log-reader
  namespace: bookstore
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: log-reader
subjects:
  - kind: ServiceAccount
    name: log-reader
    namespace: bookstore
```

```sh
kubectl apply -f log-reader.yaml
kubectl auth can-i get pods/log -n bookstore --as=system:serviceaccount:bookstore:log-reader
kubectl auth can-i get pods/log -n logging --as=system:serviceaccount:bookstore:log-reader
kubectl auth can-i get secrets -n bookstore --as=system:serviceaccount:bookstore:log-reader
kubectl -n bookstore logs leaky-app --tail=1 --as=system:serviceaccount:bookstore:log-reader
```

<!-- gate: output -->
```text
yes
no
no
```

The raw line, read with that identity:

<!-- gate: output -->
```text
{"level":"INFO","msg":"upstream call","token":"FAKE-PLANTED-TOKEN","dsn":"postgres://app:FAKE-PLANTED-PASSWORD@localhost:5432/books"}
```

The reader sees the raw line, the planted password included, because the node
holds it. That is the reach of `pods/log`. The fix is the one in step 3: the
app does not write the value. Scoping the Role to one namespace limits who
sees it, and the agent's ClusterRole, which is wider, is the reason the store
needs the tight network path above.

Clean up:

```sh
helm uninstall alloy -n logging
helm uninstall loki -n logging
kubectl delete clusterrolebinding alloy-log-reader --ignore-not-found
kubectl delete clusterrole alloy-log-reader --ignore-not-found
kubectl delete namespace logging client --ignore-not-found
kubectl delete -f log-reader.yaml -f loadgen.yaml -f leaky-app.yaml -f dsn-demo.yaml \
  -f probe-bookstore.yaml --ignore-not-found
kubectl -n bookstore delete secret dsn-demo --ignore-not-found
```

## Production notes

> **In production:** the choice of store and agent changes, not the model.
> **EKS**: a Fluent Bit DaemonSet ships to CloudWatch Logs or OpenSearch.
> **GKE**: Cloud Logging is on by default and the node agent is managed for
> you. **AKS**: Azure Monitor with Container Insights. All of them consume
> stdout and stderr, so the "JSON to stdout" contract is portable. Only the
> backend and the query language change. The access rules in steps 4 and 7
> still apply to each backend.

> **In production:** decide retention and cost deliberately. Logs are usually
> the largest telemetry stream. Set retention per tenant, and sample or drop
> chatty debug lines in the agent. Put a correlation or trace ID on every line
> and carry it across services with W3C `traceparent` ([ch.03](03-tracing.md)),
> so "every log for the request that failed" is one query.

## How it works under the hood

- **The runtime owns capture.** The kubelet asks containerd to run the
container, and containerd writes its stdout and stderr to
`/var/log/pods/<NS>_<POD>_<UID>/<CONTAINER>/<RESTART_COUNT>.log` in the CRI
format. The kubelet rotates these files (`containerLogMaxSize`,
`containerLogMaxFiles`). `kubectl logs` is an API call the kubelet serves by
reading that file. There is no database behind it.
- **`kubectl logs --previous` reads the prior file.** On a restart the runtime
starts a new `N.log`, and `--previous` serves `N-1.log`. After the Pod is
deleted the directory is removed, which is the reason to ship logs off the
node.
- **The agent discovers and reads through the API.** The Alloy pipeline lists
the pods whose `spec.nodeName` is its own node, then opens a log stream per
container with `pods/log`. Each line gets the pod's labels. The redaction
stages run on the stream, before the push. A collector that tails files
instead reads `/var/log/pods` through a hostPath; that variant is in
[01.06](../01-core-workloads/06-daemonsets.md).
- **Loki indexes labels, not content.** Elasticsearch indexes every word of
every line. Loki indexes only the label set of each stream and stores
compressed chunks. A query selects streams by label and then scans the chunks.
Cheap to run; the trade-off is that labels must stay low-cardinality.
- **Structured logs are the contract.** A stable schema means `level` and
`order_id` become filters. Free text forces regex at query time, and regex
against free text is where secrets slip through unnoticed.
- **Multiline.** A stack trace is many lines but one event. Agents rejoin them
with a start pattern. JSON logging avoids most of this, because one event is
one line by construction.

## Quick Reference

```sh
kubectl logs -n <NS> deploy/<D> --tail=20 -f            # one workload, live
kubectl logs -n <NS> <POD> -c <CONTAINER> --previous    # the prior run's raw log
kubectl auth can-i get pods/log -n <NS> --as=system:serviceaccount:<NS>:<SA>
kubectl get ds -n logging alloy                         # the node agent
```

```logql
{namespace="bookstore", app="catalog"}                        # by label (indexed)
{namespace="bookstore", app="orders"} | json | level="ERROR"  # parse and filter
sum by (level) (count_over_time({app="orders"} | json [5m]))  # log-derived metric
```

Checklist:

- [ ] The app logs structured JSON to stdout, IDs and error classes only
- [ ] No DSN, token or password ever reaches a log call, even in an error path
- [ ] The agent runs `restricted` in its own namespace, with no hostPath
- [ ] The agent's RBAC is `pods` read and `pods/log` get, and nothing else
- [ ] The chart's sidecar and its RBAC are off, or granted nothing
- [ ] The store accepts writes from the agent and reads from Grafana only
- [ ] Retention is set, and the store's labels are low-cardinality
- [ ] Readers of `pods/log` are named ServiceAccounts or groups, scoped to a
  namespace

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **`kubectl logs <pod>` works perfectly. Why does the chapter still insist
   you need a logging stack?**
   <details><summary>Show answer</summary>

   `kubectl logs` reads the node-local file for one container. It has no aggregation across replicas, no search beyond text, no retention beyond the node, and the logs vanish when the Pod is deleted. Step 6 is impossible with `kubectl logs` and simple with Loki.

   </details>

2. **A junior engineer writes logs to `/var/log/myapp.log` inside the
   container "for cleaner output". What breaks, and what should they do?**
   <details><summary>Show answer</summary>

   The file lives in the container's writable layer. It disappears on restart, the agent never sees it, and `kubectl logs` is empty. Log JSON to stdout. The runtime captures it, and the agent reads it from there.

   </details>

3. **You ship `customer_id` as a label on every request. Loki becomes
   unresponsive. What happened?**
   <details><summary>Show answer</summary>

   Storage cost follows the number of distinct label sets, or streams. One stream per customer is unbounded cardinality, the same trap as Prometheus. Put the identifier in the line and filter with `| json`. Keep labels to `namespace`, `app`, `pod`, `container`.

   </details>

4. **Hands-on extension: a service logs a bearer token in an error path. Name
   the two controls that keep it out of the store, and say which one keeps it
   off the node.**
   <details><summary>What you should see</summary>

   Removing the value at the source keeps it off the node and out of the store. The agent's redaction keeps it out of the store only. The node file still holds the raw text, and anyone with `pods/log` reads it, as step 7 shows. So the source control is the one that matters, and the agent is the backstop.

   </details>

5. **A teammate asks for `pods/log` on every namespace for the whole dev
   group, "so people can debug". What does that grant, and what would you give
   instead?**
   <details><summary>Show answer</summary>

   It grants reading the raw line of every container in the cluster, including any token or password an app wrote. Grant `pods/log` in a Role per namespace, to the named ServiceAccount or a narrow group that needs it. Remove the values at the source so there is less to read.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.9: Observability** (the logging
pipeline, node agents, store choices, and retention and cost trade-offs).
- Official:
<https://kubernetes.io/docs/concepts/cluster-administration/logging/> (cluster
logging architecture, node-agent vs sidecar, and why there is no built-in
cluster logging) and
<https://kubernetes.io/docs/concepts/cluster-administration/system-logs/>.
