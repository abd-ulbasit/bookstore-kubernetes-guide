# 13.12 — Day-2: runbook + on-call playbook + DR drill + chaos game-day

> The page an on-call engineer opens at 3am; the monthly DR drill; the
> quarterly chaos game-day; the operational story that turns the
> platform's capabilities into a working system. The closing arc of
> Part 13.

**Estimated time:** ~60 min read · half-day hands-on
**Prerequisites:** [Part 13 ch.01-11](01-bookstore-2-from-toy-to-platform.md) — every v2 capability this chapter operationalises · [Part 11 ch.07](../11-advanced-production-patterns/07-chaos-engineering.md) — chaos discipline this chapter schedules · [Part 08 ch.02](../08-day-2-operations/02-backup-and-dr.md) — DR drill foundation · [Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md) — SLO + error budget that drive the runbook
**You'll know after this:** • synthesise the eleven prior chapters' capabilities into a single operational discipline · • author a runbook that an on-call engineer can open at 3am and act on · • plan a monthly DR drill that exercises multi-region failover end-to-end · • plan a quarterly chaos game-day with bounded blast radius and learning outcomes · • close the loop from incident → postmortem → SLO budget → backlog · • prove the v2 platform's capabilities hold under coordinated failure · • close the Part 13 capstone with an honest "what we did not build" list

<!-- tags: bookstore-v2, day-2, dr, postmortem, slo, capstone -->

## Why this exists

The eleven previous chapters built **capabilities**: tenancy, regions,
identity, search, payments, edge, ML, observability, cost, developer
portal. Each one ships a working slice. **None of them is the
platform.** A platform is not a set of capabilities; a platform is an
**operational discipline** applied to capabilities. This chapter is
that discipline:

1. **The runbook is the page an on-call engineer opens at 3am.** Not
   a Confluence wiki; a versioned markdown file in the repo. Each
   alert has a runbook. Each runbook is structured. Each runbook is
   exercised in chaos game-days.
2. **The on-call playbook is who's on-call and how escalation works.**
   1-week rotations, 2-tier (primary + secondary), explicit severity
   definitions, blameless postmortems.
3. **The DR drill is the monthly fire drill.** Scripted, time-boxed,
   scored. Extends ch.13.03's regional failover.
4. **The chaos game-day is the quarterly resilience test.** Hypothesis-
   driven, blast-radius-bounded, observed against SLOs (the discipline
   from [Part 11 ch.07](../11-advanced-production-patterns/07-chaos-engineering.md)).

[Part 08](../08-day-2-operations/02-backup-and-dr.md) built the
Day-2 chapters — backup/DR, multi-tenancy, upgrades, capacity. [Part 11
ch.07](../11-advanced-production-patterns/07-chaos-engineering.md)
built Chaos Mesh. This chapter is the **platform-v2-shaped** synthesis:
real runbooks against the v2 alerts; the on-call rotation that fits
multi-region; the DR drill against the multi-region active-active
shape; the chaos game-day against the nine-service request path.

This chapter is also **the closing arc of Part 13**. The reader who
gets here has read 11 chapters that each built one slice of the
platform; this chapter pulls them into one operational story and
names the through-line.

> **In production:** Without this chapter, the platform is **code**,
> not a **product**. The capabilities exist; the discipline does not.
> Every multi-team Kubernetes platform that fails to ship operability
> dies the same way: the platform team becomes a 24/7 escalation
> queue; senior engineers burn out; the product teams lose trust;
> migration begins. The remedy is the four artifacts in this chapter,
> rehearsed before they are needed.

## Mental model

**Day-2 operations = (the playbook the on-call USES at 3am) + (the
procedures the team REHEARSES monthly) + (the chaos drills the team
RUNS quarterly). The runbook is structured (alert → check → diagnose
→ mitigate → postmortem). On-call rotations are 1-week, 2-tier, with
explicit escalation. DR drills are scripted, scored. Chaos game-days
are hypothesis-driven, blast-radius-bounded, postmortem-closed.**

- **The runbook structure — five sections.** Every runbook in
  `examples/bookstore-platform/runbooks/` follows the same shape:
  1. **Alert** — the alert name, the Prometheus query, the
     dashboard link. The first sentence answers "what fired?".
  2. **Check** — fast (< 60s) commands to confirm it's a real
     incident, not a flapping alert. The "is it real?" gate.
  3. **Diagnose** — ordered commands to localise the cause. The
     branching tree of "if the answer is X, jump to step Y."
  4. **Mitigate** — the action to stop the bleeding. Cite the
     exact command + the safety check ("does this affect any other
     tenant?").
  5. **Postmortem link** — the template for the writeup. Required
     within 48h for any P0/P1 incident.
- **On-call rotation patterns.** Two shapes work at platform scale:
  - **Primary + secondary (the v2 default).** A primary engineer is
    paged first; a secondary is paged if primary does not ack in
    15 minutes. 1-week shifts. Handoff meetings every Monday.
  - **Follow-the-sun.** Three regional teams (us-east, eu-west,
    ap-southeast) each cover an 8-hour window. Pages route by
    time-of-day to the awake team. The right shape at > 100
    engineers; over-engineered at < 50. v2 ships primary+secondary;
    follow-the-sun is a production-graduate.
- **Severity definitions — P0 / P1 / P2.** Each severity ties to
  customer impact:
  - **P0** — production down (50 % of customers affected; data
    loss; safety / regulatory). Page; customer comm in 15 minutes;
    postmortem mandatory; war-room within 30 minutes.
  - **P1** — degraded (single-region down; single feature broken
    for all tenants; tenant isolation breach). Page; customer
    comm in 1 hour; postmortem within 48h.
  - **P2** — minor (single tenant affected, workaround exists;
    cosmetic). Slack only; no postmortem.
- **DR-drill scoring.** Every drill produces three numbers:
  - **RTO actual** vs **RTO target** (how long until recovery?
    target is 30 minutes for v2).
  - **RPO actual** vs **RPO target** (how much data was lost?
    target is < 5 minutes for v2 via CNPG sync replication).
  - **Human action time** (how long did the responders take? The
    point of monthly drills is to drive this number down.)
- **Chaos game-day pattern.** Hypothesis → safety boundary →
  experiment → observe → learn:
  - **Hypothesis** — a falsifiable claim ("storefront stays up
    when one payments-gateway Pod dies").
  - **Safety boundary** — what we WON'T break (no chaos in
    production; one Pod, one namespace; a stated duration).
  - **Experiment** — the Chaos Mesh CR.
  - **Observe** — against the SLO (the Prometheus dashboard +
    the Grafana panel for active alerts).
  - **Learn** — postmortem template; action items.
- **Postmortem culture — blameless, action-item-driven.** The
  template (the file in `examples/bookstore-platform/runbooks/
  postmortem-template.md`) has structured sections: Summary,
  Impact, Timeline, Root Cause, Action Items, Lessons. The writeup
  is published widely (not buried in a wiki); the action items are
  tracked to completion.

The trap to keep in view: **runbooks decay**. A runbook written and
not exercised is wrong within 30 days — the service evolved, the
alert renamed, the dashboard moved. The defence: every runbook is
exercised at least once per quarter, either in a chaos game-day
(intentional) or a real incident (unfortunate). Runbooks not
exercised in 90 days carry a banner: "STALE — exercise before
trusting."

## Threats and controls

| Threat | Control in this chapter | Deeper |
|---|---|---|
| Break-glass admin access outlives the incident | Humans bind `bookstore-platform-admin` only through the gate in hands-on section 6: a named binding, an expiry annotation, and removal at exit | [05.01](../05-security/01-authn-authz-rbac.md) |
| A chaos fault reaches past the service it targets | One namespace and `mode: one` per experiment, a stated duration, faults admitted only in namespaces annotated `chaos-mesh.org/inject=enabled`, and the game-day Workflow created only in a staging cluster | [11.07](../11-advanced-production-patterns/07-chaos-engineering.md) |
| The chaos daemon runs privileged on every node | `privileged` is set on the `chaos-mesh` namespace alone; the experiments namespace stays `restricted` | [05.02](../05-security/02-pod-security.md) |
| A failover serves traffic from data nobody measured | The drill scores RTO and RPO, where RPO is the replication lag read just before promotion (an upper bound, not a count of lost writes), and passes only when the promoted primary accepts a write | [08.02](../08-day-2-operations/02-backup-and-dr.md) |

## Diagrams

### Diagram A — the on-call flow (Mermaid)

```mermaid
flowchart TB
    a["Alert fires<br/>(Prometheus rule -><br/>Alertmanager)"]
    am["Alertmanager<br/>routes by severity<br/>+ tenant + region"]
    pd["PagerDuty<br/>primary on-call"]
    sec["secondary on-call<br/>(if primary no-ack in 15m)"]
    rb["On-call opens runbook<br/>(versioned markdown<br/>in the repo)"]
    chk["Step 1: Check<br/>is it real?"]
    diag["Step 2: Diagnose<br/>which service / region / tenant?"]
    mit["Step 3: Mitigate<br/>stop the bleeding"]
    pm["Step 4: Postmortem<br/>(within 48h for P0/P1)"]
    learn["Step 5: Update the runbook<br/>+ action items"]

    a --> am
    am -->|"severity=page"| pd
    pd -->|"no ack in 15m"| sec
    pd --> rb
    sec --> rb
    rb --> chk --> diag --> mit
    mit -->|"P0/P1: required"| pm
    pm --> learn
    learn -.->|"runbook gets sharper"| rb
```

### Diagram B — incident severity matrix (ASCII)

```text
SEV  CUSTOMER IMPACT              PAGE?   CUSTOMER COMM?         POSTMORTEM?    EXAMPLES
───  ──────────────────────────   ─────   ─────────────────────  ─────────────  ───────────────────────────────
P0   >=50% of customers down,     yes     within 15 min          required       full-platform outage; data loss;
     OR data loss,                                               (mandatory)    payments stalled cluster-wide;
     OR safety/regulatory                                                       tenant isolation breach
P1   single region down,          yes     within 1 hour          required       us-east down; search broken;
     OR feature broken for ALL                                   (within 48h)   recommendations not scoring;
     tenants,                                                                   payments succeed but webhook
     OR tenant isolation issue                                                  delivery delayed
P2   single tenant affected,      slack   on-request only        NOT required   tenant X's search index lagging;
     OR workaround exists,        only                                          tenant Y over budget warning;
     OR cosmetic                                                                cosmetic UI glitch
───  ──────────────────────────   ─────   ─────────────────────  ─────────────  ───────────────────────────────
RESPONSE TIME TARGETS (the on-call SLA):
  P0  ack within 5 min, mitigate within 30 min, postmortem within 48h
  P1  ack within 15 min, mitigate within 4 hours, postmortem within 48h
  P2  ack within 1 business day, mitigate when convenient
```

### Diagram C — the chaos game-day arc (Mermaid)

```mermaid
flowchart LR
    pl["1. Plan<br/>hypothesis +<br/>safety boundary"]
    rh["2. Rehearse<br/>kind cluster<br/>(no prod)"]
    es["3. Execute<br/>staging cluster<br/>during business hours"]
    ob["4. Observe<br/>SLO dashboards<br/>+ runbook fired correctly?"]
    pm["5. Postmortem<br/>action items"]

    pl --> rh --> es --> ob --> pm
    pm -.->|"hypothesis refined"| pl
```

## Hands-on with the Bookstore Platform

### 0. Prerequisites

- ch.13.09 ran. Alertmanager + Grafana exist; alerts route to a mock
  PagerDuty receiver.
- ch.13.03 ran. Multi-region clusters exist; ApplicationSet is live.
- [Part 11 ch.07](../11-advanced-production-patterns/07-chaos-engineering.md)
  ran or Chaos Mesh is installed. Create the namespace first, labelled
  `privileged`, because the chaos daemon needs it. Save this as
  `chaos-mesh-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: chaos-mesh
  labels:
    app.kubernetes.io/part-of: bookstore-platform
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

Install into that namespace. `--create-namespace` is left out, because it
would create the namespace without these labels:

```sh
CHAOS_MESH_VERSION="2.7.0"

kubectl apply -f chaos-mesh-namespace.yaml
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --version "$CHAOS_MESH_VERSION" \
  -n chaos-mesh --wait \
  --set 'chaosDaemon.runtime=containerd' \
  --set 'chaosDaemon.socketPath=/run/containerd/containerd.sock' \
  --set 'dashboard.create=false' \
  --set 'controllerManager.enableFilterNamespace=true' \
  --set 'controllerManager.securityContext.seccompProfile.type=RuntimeDefault'
```

The two `controllerManager` values narrow the controller. With
`enableFilterNamespace`, only pods in namespaces annotated
`chaos-mesh.org/inject=enabled` can be injected, so a fault reaches a
namespace only after someone opts it in. The chart exposes one pod-level
`securityContext` for the controller manager and no container-level one. This
chapter sets the seccomp profile there. It does not set `runAsNonRoot`,
because the image runs as root with no `USER`, and the container-level fields
(`allowPrivilegeEscalation` and the dropped capabilities) have no chart value.
The dry run below shows the warnings that remain.

The chart defaults to `chaosDaemon.privileged: true` ([chart values at
v2.7.0](https://github.com/chaos-mesh/chaos-mesh/blob/v2.7.0/helm/chaos-mesh/values.yaml)).
The DaemonSet also sets
`hostPID: true` even when `privileged` is false, as the chart renders with
`privileged=false` shows. Baseline forbids host namespaces and privileged
containers, so the namespace cannot be narrower than `privileged`. The
dashboard is optional and has a web surface of its own, so this chapter turns
it off.

The chapter's captured run did not install the chart, because the shared lab
lock for heavy installs was busy. It checks the daemon and the controller
manager with a render and server-side dry runs, which creates nothing:

```sh
helm template chaos-mesh chaos-mesh/chaos-mesh --version "$CHAOS_MESH_VERSION" \
  -n chaos-mesh \
  --set 'chaosDaemon.runtime=containerd' \
  --set 'chaosDaemon.socketPath=/run/containerd/containerd.sock' \
  --set 'dashboard.create=false' \
  --set 'controllerManager.enableFilterNamespace=true' \
  --set 'controllerManager.securityContext.seccompProfile.type=RuntimeDefault' \
  --show-only templates/chaos-daemon-daemonset.yaml \
  --show-only templates/controller-manager-deployment.yaml \
  | kubectl apply --dry-run=server -f -
```

<!-- gate: output -->
```text
Warning: would violate PodSecurity "restricted:latest": host namespaces (hostPID=true), privileged (container "chaos-daemon" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "chaos-daemon" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "chaos-daemon" must set securityContext.capabilities.drop=["ALL"]; container "chaos-daemon" must not include "SYS_PTRACE" in securityContext.capabilities.add), restricted volume types (volumes "socket-path", "sys-path", "lib-modules" use restricted volume type "hostPath"), runAsNonRoot != true (pod or container "chaos-daemon" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "chaos-daemon" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
daemonset.apps/chaos-daemon created (server dry run)
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "chaos-mesh" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "chaos-mesh" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "chaos-mesh" must set securityContext.runAsNonRoot=true)
deployment.apps/chaos-controller-manager created (server dry run)
```

The output in this chapter came from a kind cluster named `sf-pilot`. Its
experiments namespace had a lab name, `p13-12-experiments`, and the output
below that names it keeps it. The captured run's Chaos Mesh namespace had a
lab name too; the transcript shows it as `chaos-mesh`. The first Warning line
is Pod Security admission reporting what `restricted` would refuse in the
daemon, and the `privileged` label is what lets the daemon through. The second
Warning is the controller manager. The chart sets its seccomp profile, but the
container still lacks `allowPrivilegeEscalation: false`, a dropped capability
set and `runAsNonRoot`, as the section above explains.

### 1. Apply the runbook tree

```sh
# The runbook tree is documentation + scripts + Chaos Mesh CRDs
ls examples/bookstore-platform/runbooks/
# README.md
# runbook-api-latency-p99.md          <- P1: catalog p99 > 500ms
# runbook-payments-failure-rate.md    <- P1: payments fail > 5%
# runbook-database-replication-lag.md <- P1: CNPG replication > 30s
# on-call-rotation.md                 <- the rotation policy
# dr-drill-script.sh                  <- the 30-min monthly drill
# chaos-gameday.md                    <- the quarterly chaos playbook
# chaos-experiments.yaml              <- Chaos Mesh Workflow (5 experiments)
# postmortem-template.md              <- blameless writeup template

# Do not apply chaos-experiments.yaml in this section. Chaos Mesh starts a
# Workflow as soon as it exists, so the game-day Workflow is created in
# section 5 only, in a staging cluster.
```

The file holds the `chaos-mesh-experiments` namespace, labelled `restricted`,
and the Workflow. This section does not apply it. The lab ran a copy of the
file with the namespace renamed, to show what the server does with it before
Chaos Mesh is installed. The namespace is created and the Workflow is refused,
because its CRD is missing. The output names that copy:

<!-- gate: output -->
```text
namespace/p13-12-experiments created
error: resource mapping not found for name: "bookstore-platform-quarterly-gameday" namespace: "p13-12-experiments" from "chaos-experiments-lab.yaml": no matches for kind "Workflow" in version "chaos-mesh.org/v1alpha1"
ensure CRDs are installed first
```

The lab also walked each field of the Workflow against the schema that the
2.7.0 chart ships in its CRDs. The walk found no field the schema lacks:

<!-- gate: output -->
```text
templateType values used: DNSChaos, HTTPChaos, IOChaos, NetworkChaos, PodChaos, Serial, Suspend
keys checked against the 2.7.0 Workflow schema: 87
keys not in the 2.7.0 Workflow schema: none
templates whose body key does not match templateType: none
```

Experiments have no privilege of their own, so `restricted` stays on their
namespace. A probe Pod that asks for `privileged` shows the boundary. The
first is a deliberate failure, and the second is the same request in the
daemon's namespace:

```sh
# Deliberate failure: a privileged Pod is refused in the experiments namespace
kubectl -n chaos-mesh-experiments run probe --image=registry.k8s.io/pause:3.10 \
  --privileged --dry-run=server -- sleep 60
```

<!-- gate: output -->
```text
Error from server (Forbidden): pods "probe" is forbidden: violates PodSecurity "restricted:latest": privileged (container "probe" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "probe" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "probe" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "probe" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "probe" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

```sh
# The daemon's namespace admits the same request
kubectl -n chaos-mesh run probe --image=registry.k8s.io/pause:3.10 \
  --privileged --dry-run=server -- sleep 60
```

<!-- gate: output -->
```text
# ...
pod/probe created (server dry run)
```

### 2. Walk a runbook end-to-end

The alert fires at 3am (illustrative output, not captured):

```text
[PAGE] BookstoreCatalogP99Latency
Severity: page
Tenant: acme-books
Region: us-east
p99 = 873ms (threshold: 500ms)
Runbook: https://github.com/your-org/bookstore-platform/blob/main/runbooks/runbook-api-latency-p99.md
Dashboard: https://grafana.bookstore-platform.example.com/d/bookstore-overview?var-tenant=acme-books
```

The on-call opens
`examples/bookstore-platform/runbooks/runbook-api-latency-p99.md` and
walks the five sections. Step 1 (Check):

```sh
kubectl --context kind-bookstore-platform-us-east -n bookstore-platform-acme-books get pods -l app=catalog
# If all Running -> the alert is real (not a deploy-in-progress)

# Confirm the metric
kubectl --context kind-bookstore-platform-us-east -n prometheus-system exec -ti prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service="catalog",tenant="acme-books"}[5m])))'
# 0.873   <- illustrative result: confirmed, real
```

Step 2 (Diagnose): the runbook walks an ordered tree (DB? CPU? Pod
restart loop? Network? GC pause?). Step 3 (Mitigate): the action that
stops the bleeding (scale catalog from 3 → 6 replicas; or roll back to
the last green deploy). Step 4: postmortem.

### 3. Run the monthly DR drill (extends ch.13.03)

```sh
# The drill script extends ch.13.03's failover (the manual version)
# into a 30-minute scripted, scored exercise.
bash examples/bookstore-platform/runbooks/dr-drill-script.sh \
  --region us-east \
  --target-region eu-west \
  --dry-run=false

# Illustrative output, not captured:
# [00:00] DR DRILL STARTED — us-east -> eu-west failover
# [00:02] Pre-flight: CNPG replication lag = 2s (target < 5s)
# [00:03] PHASE 1: cordon + drain us-east
# [03:42] PHASE 2: promote eu-west CNPG to primary
# [05:18] PHASE 3: update ApplicationSet target to eu-west
# [08:33] PHASE 4: update DNS to point at eu-west
# [12:00] PHASE 5: verify the promoted eu-west primary accepts a write
# [12:42] DRILL ENDED: the stub's Result line reads PASS
#   RTO actual:        12m42s   (target: 30m)
#   RPO actual:        3s       (target: 5m)
#   Human action time: 2m11s    (last drill: 4m02s)
# Stub: runbooks/dr-drill-<date>.md. Add the postmortem from postmortem-template.md.
```

### 4. Run a chaos game-day experiment

```sh
# The experiments namespace, labelled restricted. The Workflow in
# chaos-experiments.yaml is created in section 5, not here.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: chaos-mesh-experiments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
EOF

# Opt in each namespace this game-day may touch. With enableFilterNamespace
# (section 0), only annotated namespaces can receive faults.
kubectl annotate namespace bookstore-platform-acme-books chaos-mesh.org/inject=enabled

# Run the first experiment by hand: pod-kill on payments-gateway. A PodChaos
# runs once for its duration. Read its result before any Workflow.
kubectl -n chaos-mesh-experiments create -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: gameday-pod-kill-payments
  namespace: chaos-mesh-experiments
spec:
  action: pod-kill
  mode: one
  duration: "60s"
  selector:
    namespaces: [bookstore-platform-acme-books]
    labelSelectors:
      app: payments-gateway
EOF

# Watch the storefront stay up (the port-forward from ch.13.07 step 5 runs)
watch -n 5 'curl -s --cacert edge-ca.crt -o /dev/null -w "%{http_code} %{time_total}s\n" https://localhost:8443/static/index.html'
# Illustrative output, not captured:
# 200 0.012s
# 200 0.014s
# 200 0.011s
# ...
# (Illustrative. The storefront stays up only while payments-gateway has
#  another ready replica. This tree ships no PodDisruptionBudget for it.)

# Inspect the postmortem template
cat examples/bookstore-platform/runbooks/postmortem-template.md
```

### 5. The quarterly chaos game-day (the 5 experiments)

Creating the Workflow starts the game-day. Chaos Mesh runs its Serial entry as
soon as the object exists, so create it in a staging cluster only, and name
that cluster's context on the command. The topology in ch.13.03 has no staging
cluster: it has us-east, eu-west, ap-southeast and the management cluster. Set
`STAGING_CONTEXT` to the context of a staging cluster you run, with the same
platform stack. Read the PodChaos result from section 4 before you create the
Workflow.

```sh
kubectl --context "$STAGING_CONTEXT" apply \
  -f examples/bookstore-platform/runbooks/chaos-experiments.yaml
```

The Chaos Mesh Workflow in
`examples/bookstore-platform/runbooks/chaos-experiments.yaml` chains
5 Chaos Mesh experiments + an optional cordon-based region-loss
simulation in `dr-drill-script.sh`. The five Chaos Mesh CRs:

1. **PodChaos — pod-kill** on payments-gateway (tests the replica count and
   any PodDisruptionBudget you add first).
2. **NetworkChaos — network-delay** on catalog → orders (test timeouts + retries).
3. **IOChaos — io-latency** on the CNPG primary's data volume (test
   replication lag and failover).
4. **DNSChaos — region-DNS-loss** (DNS queries for
   `*.bookstore-platform.example.com` return an error, in one tenant
   namespace) — disrupts what the *application* sees of remote
   regions; complements the cordon-based simulation in
   `dr-drill-script.sh` which disrupts what the *cluster* sees of its
   own nodes. Tests the DR runbook + saga compensation.
5. **HTTPChaos — payments-failure** (the webhook receiver answers 500 for
   three minutes) — tests the saga compensation (ch.13.06).

Each experiment has:
- A hypothesis ("storefront stays up").
- A stop rule: the on-call deletes the Workflow when the burn-rate alert
  pages. Chaos Mesh's `statusCheck` can abort a Workflow, but only on an
  HTTP status code (the 2.7.0 Workflow CRD), not on a PromQL value, so an
  automatic abort needs a probe endpoint that this chapter does not build.
- A 10-minute observation window.
- A postmortem requirement (even if the experiment passed).

### 6. Bind the break-glass role only through the gate

`bookstore-platform-admin` is cluster-admin in all but name
([13.01](01-bookstore-2-from-toy-to-platform.md)), so a human binds it
through this gate and nothing else does:

1. The responder asks in the incident channel, with the incident ID, and
   the incident commander approves in the same thread. A bot or a shared
   account does not qualify.
2. Bind a named ClusterRoleBinding to that person's OIDC identity, with a
   label and an expiry:

```sh
INCIDENT="<incident-id>"
kubectl create clusterrolebinding "breakglass-$INCIDENT" \
  --clusterrole=bookstore-platform-admin \
  --user="<oidc-subject-of-the-responder>"
kubectl label clusterrolebinding "breakglass-$INCIDENT" \
  bookstore-platform.example.com/break-glass=true
kubectl annotate clusterrolebinding "breakglass-$INCIDENT" \
  bookstore-platform.example.com/expires-at="<UTC time, four hours out>"
```

3. At the start of each shift, and at the end of the incident, list the
   bindings that are still open, with the time each one expires:

```sh
kubectl get clusterrolebindings \
  -l bookstore-platform.example.com/break-glass=true \
  -o 'custom-columns=NAME:.metadata.name,SUBJECT:.subjects[0].name,EXPIRES:.metadata.annotations.bookstore-platform\.example\.com/expires-at'
```

<!-- gate: output -->
```text
NAME                    SUBJECT         EXPIRES
breakglass-p13-12-lab   lab-responder   2026-10-31T16:00:00Z
```

The lab used a throwaway binding of the `view` role, under the name
`breakglass-p13-12-lab` in place of `breakglass-<incident-id>`. An EXPIRES time
that has passed means the binding should already be gone.

4. Delete the binding when the incident ends, and record the time in the
   postmortem.

Kubernetes does not expire a binding on its own. The shift check reads the
annotation. The sweeper that would delete expired bindings is listed under
what we did not build.

## How it works under the hood

**Why structured runbooks — the 3am cognitive load story.** At 3am,
an on-call engineer is sleep-deprived; the on-call is the worst time
for ad-hoc reasoning. The runbook offloads the reasoning: each step
is a command + the expected output + the branching decision. The
goal is to reduce on-call to **mechanical execution**; only the rare
"the runbook doesn't cover this" case requires cognitive load. This
is why Google SRE recommends runbooks per alert; this is why v2
ships them.

**On-call rotation patterns at platform scale.** Three variables:
- **Shift length.** 1 week is common; some teams use 12-hour
  shifts for follow-the-sun. Longer = more handoff loss; shorter =
  more handoff overhead. 1 week is the median.
- **Rotation size.** A rotation of 5 means each engineer is on-
  call every 5 weeks. < 4 = burnout risk; > 10 = on-call skills
  decay between shifts. Target 5-8.
- **Tier structure.** Single-tier (one person, escalate to manager) =
  starter; primary + secondary (the v2 default) = production-shape;
  follow-the-sun = global. Each adds operational overhead.

**DR-drill scoring — the three numbers.** Every drill outputs:
- **RTO actual** (time to recovery). The clock starts when the
  failure is injected; stops when the customer flow works again.
  Compare to RTO target (v2: 30 minutes).
- **RPO actual** (data loss). How much data was committed in the
  failing region that was lost in the failover? CNPG sync
  replication keeps this < 5 minutes (often < 5 seconds);
  measured by the timestamp of the last replicated transaction.
- **Human action time**. How long was the human in the loop?
  Each subsequent drill should reduce this — automation replaces
  manual steps. The point of the monthly cadence: drive this
  number toward zero (zero = fully automated DR; the production
  goal).

**Chaos game-day pattern in detail.** Hypothesis-driven:

1. **State the hypothesis** clearly. "When one catalog Pod dies,
   the storefront stays up and the catalog p95 latency stays under
   100 ms." Not "let's see what happens."
2. **Bound the blast radius.** `mode: one`, one namespace, and a duration
   in the manifest. No production. The smallest fault that tests the
   hypothesis.
3. **Define the stop rule before the run.** For example, "5xx rate > 5 %
   in any 10-second window." Chaos Mesh's `statusCheck` can stop a
   Workflow only on an HTTP status, so the on-call stops it by hand
   unless a probe endpoint exists.
4. **Run + observe.** Watch the SLO dashboards. Did the hypothesis
   hold? If yes, the resilience control works; if no, an
   incident-in-staging that you found controlled.
5. **Postmortem.** Even passing experiments produce action items
   ("the alert fired at 873ms but the runbook says 500ms — update
   one or the other").

**Postmortem culture — blameless, structured, published widely.**
The template's sections (the file in `runbooks/postmortem-template.md`):
- **Summary** (1 paragraph; what happened, customer impact).
- **Timeline** (UTC timestamps; what was seen, what was done).
- **Root cause** (technical; the chain of events).
- **Why we did not catch it earlier** (the monitoring gap).
- **Action items** (each item has owner + due date + tracking
  ticket).
- **Lessons** (what we learned).
"Blameless" means the writeup names actions, not people; the
question is "what was the system that let this happen?" not "who
made the mistake?".

## Production notes

> **In production:** **Runbooks decay; exercise quarterly.** A
> runbook written and never exercised is wrong within 30-90 days.
> The defence: every chaos game-day runs against a specific
> runbook (the game-day's hypothesis IS the runbook's diagnose
> step); every real incident closes with a "did the runbook
> work?" question. Runbooks not exercised in 90 days carry a
> "STALE" banner.

> **In production:** **On-call burnout — limit page volume.**
> The target: < 2 pages per shift, < 1 P0 per quarter per
> engineer. Beyond that, on-call is destructive; the team will
> burn out. Mitigations: (1) **alert hygiene** — quarterly review
> of every alert; deletes the noisy ones; tunes the
> burn-rate thresholds; (2) **load shedding** — pages over a
> threshold (e.g. > 10 per shift) escalate to "the alerting is
> broken; the platform team's next sprint is to fix it"; (3)
> **dignified off-time** — no Slack expectations off-shift; the
> primary owns the page, period.

> **In production:** **The DR drill that "passed" because we
> changed the parameters.** The most common drill antipattern.
> A drill that the team has run 12 times in a row, all passing
> because someone keeps relaxing the RTO target by 5 minutes.
> The defence: **the drill targets are frozen and tracked in the
> runbook**; the engineer running the drill cannot edit them
> day-of; any target change requires a PR review.

> **In production:** **Chaos in production — earn it.** Production
> chaos is the right end-state; jumping there before staging
> chaos passes is reckless. The maturity ladder: (1) chaos in
> kind / dev, (2) chaos in staging during business hours, (3)
> chaos in staging off-hours, (4) chaos in production during
> business hours (one experiment per quarter), (5) chaos in
> production automated (Netflix Chaos Monkey shape). v2 ships
> (1) + (2); (3) onwards is platform-team-discretion + customer-
> impact-review.

> **In production:** **Postmortems published widely, not buried in
> a wiki.** A postmortem in a private wiki is invisible; a
> postmortem in a public Slack channel + the platform's `/docs/
> postmortems/` directory + a quarterly all-hands review is
> shared knowledge. The goal is not punishment; the goal is
> **the same mistake does not happen twice**.

> **In production:** **Action items tracked, not aspirational.**
> The number-one postmortem-quality regression: action items
> with no owner / no due date / no tracking ticket. Mitigation:
> the postmortem template REQUIRES owner + due date + ticket for
> each action; the platform's quarterly review tracks completion
> rate; an action-completion rate < 80 % is a process bug, not a
> people bug.

## What we did not build

The Day-2 chapter is necessarily incomplete. The platform v2 ships
the core operational story; deliberately deferred to follow-up work:

- **Full ITIL change-management.** v2 has GitOps as the change
  spine (every change is a PR; PRs are the change request +
  approval + audit). A formal ITIL CAB process layers on top for
  regulated industries; we point at it, do not implement.
- **Burn-rate alerting at every SLO.** ch.13.09 wires burn-rate
  alerts for the platform-level RED metrics; per-service SLOs +
  per-tenant SLOs + per-API SLOs are an exhaustive list this
  chapter foreshadows but does not enumerate.
- **STAMP-style postmortem analysis.** The
  [STAMP](http://psas.scripts.mit.edu/home/get_file.php?name=STAMP_primer.pdf)
  framework (system-theoretic accident model) is the rigorous
  research-grade postmortem method; v2 ships the lighter "5-why
  + timeline" template. STAMP for the platform team is a
  multi-year discipline graduate.
- **Production-traffic shadow testing.** Send a copy of
  production traffic to a canary version of the service; observe
  for behavioural diffs. KServe ships the inference-shadow
  shape (ch.13.08); the application-tier shadow is a Service
  Mesh feature (Istio `mirror`); v2 sketches it; production
  wires it.
- **Chaos-in-production framework.** Run controlled chaos in
  production continuously (Netflix Chaos Monkey shape). v2 runs
  chaos in staging only; the production transition is a
  separate maturity step that requires the SRE org to be at
  Operate-level in the FinOps language.
- **Auto-remediation.** "The alert fires; a controller
  automatically applies the mitigation; the human is informed."
  An aspirational end-state; v2 keeps the human in the loop for
  every page. Auto-remediation requires deep confidence in the
  mitigation correctness; we are honest that we are not there.
- **Automatic break-glass expiry.** Kubernetes does not expire a binding,
  and this chapter builds no sweeper for expired ones. The shift check and
  the exit step carry the control until one exists.
- **NetworkPolicy for the Chaos Mesh namespaces.** Nothing in this chapter
  restricts which pods can reach the `chaos-mesh` and
  `chaos-mesh-experiments` services. The platform team owns that policy.
  Write it before the first game-day, and prove it with a denied request,
  the way [ch.13.10](10-cost-opencost-per-tenant-finops.md) does for its
  namespace.

## Closing the platform-v2 thread

Part 13's twelve chapters built the v2 platform. Chapter by chapter,
the v1 toy became a production-shape artifact:

- **ch.01** — v1 had one service per concern; v2 has the eleven
  disciplines a platform requires.
- **ch.02** — v1 had one tenant (implicit); v2 has the
  `BookstoreTenant` API + Crossplane Composition.
- **ch.03** — v1 had one region; v2 has three regions, active-
  active, with CNPG replication + ApplicationSet fanout.
- **ch.04** — v1 had a toy HMAC; v2 has Keycloak OIDC for humans +
  IRSA for workloads + mesh-verified JWT.
- **ch.05** — v1 had no search; v2 has Meilisearch + Debezium CDC.
- **ch.06** — v1 had a fake payment; v2 has Stripe + outbox +
  Kafka + saga compensation.
- **ch.07** — v1 was bare; v2 has Istio Gateway + Coraza WAF +
  per-tenant rate limiting.
- **ch.08** — v1 had a rule-based recommender; v2 has MLflow +
  KServe + Alibi-Detect drift + Argo Events retraining.
- **ch.09** — v1 had Prometheus metrics; v2 has the three pillars
  with one collector.
- **ch.10** — v1 had no cost story; v2 has OpenCost + per-tenant
  showback + budget alerts.
- **ch.11** — v1 had four services a developer could navigate by
  filename; v2 has Backstage as the developer's entry point.
- **ch.12** — v1 had no Day-2 discipline; v2 has runbooks +
  on-call + DR drills + chaos game-days.

Every chapter applied a concept the guide had already taught (Part
06 Prometheus → ch.13.09's deepening; Part 11 ch.07 Chaos Mesh →
ch.13.12's game-day; Part 11 ch.10 Backstage → ch.13.11; Part 12
ch.06-08 KServe + Argo Workflows + MLflow → ch.13.08; Part 07
Argo CD → ch.13.03's ApplicationSet; Part 10 cloud identity →
ch.13.04's IRSA). Every footgun was named. Every cost was honest.

Part 12 ch.08 closed with the line:

> **"Kubernetes did not become an ML platform; the ML platform
> became a Kubernetes workload."**

Part 13's analog:

> **A platform is not a project you ship; a platform is the
> discipline of applying Kubernetes-the-engine honestly to a
> production-shape problem. The eleven capabilities are the
> easy part; the operational discipline of the twelfth chapter
> is the platform.**

The reader who finishes Part 13 has not built every platform on
every cloud for every team; the reader has built **one platform**
end-to-end, with every footgun named honestly. That is the
fundamental skill: **the next platform you build will be
different, and the disciplines transfer.**

For the next step:
- Appendix E ("Continuous learning paths") names the books +
  conferences + open-source communities that keep this discipline
  current.
- The source code lives in
  [`examples/bookstore-platform/`](../examples/bookstore-platform/);
  every YAML carries the chapter it lives in; every runbook is
  exercised in a chaos game-day.
- The v1 Bookstore at
  [`examples/bookstore/`](../examples/bookstore/) remains intact;
  read the two side-by-side to see the discipline gap that twelve
  chapters closed.

## Quick Reference

```sh
# Pinned install (Chaos Mesh; the other stacks are from previous chapters).
# The namespace comes first, labelled privileged: section 0 has the manifest.
kubectl apply -f chaos-mesh-namespace.yaml
CHAOS_MESH_VERSION="2.7.0"

helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh --version "$CHAOS_MESH_VERSION" \
  -n chaos-mesh --wait \
  --set 'chaosDaemon.runtime=containerd' \
  --set 'chaosDaemon.socketPath=/run/containerd/containerd.sock' \
  --set 'dashboard.create=false'

# Game-day only: create the Workflow in staging (it starts at once)
kubectl --context "$STAGING_CONTEXT" apply -f examples/bookstore-platform/runbooks/chaos-experiments.yaml

# Run the monthly DR drill (a dry run unless --dry-run=false is added)
bash examples/bookstore-platform/runbooks/dr-drill-script.sh --region us-east --target-region eu-west

# Break-glass: list the admin bindings that are still open
kubectl get clusterrolebindings -l bookstore-platform.example.com/break-glass=true
```

Minimal runbook skeleton:

```markdown
# runbook-<ALERT>.md
## Alert
- Name: <ALERT-NAME>
- Query: <PROMQL>
- Dashboard: <GRAFANA-URL>
- Severity: <P0/P1/P2>

## Check (< 60s)
1. kubectl -n <NS> get pods -l <SELECTOR>
2. promtool query instant <PROMQL>

## Diagnose (ordered)
1. If <CONDITION> -> jump to step <N>
2. ...

## Mitigate
- Command: <COMMAND>
- Safety check: <ASSERTION>

## Postmortem
- Template: ../runbooks/postmortem-template.md
- Within 48h for P0/P1.
```

Closing checklist (the Day-2 story closed when all seven are yes):

- [ ] Every active alert has a runbook in
      `examples/bookstore-platform/runbooks/`; the runbook follows the
      5-section structure.
- [ ] On-call rotation is in PagerDuty (or its equivalent); primary +
      secondary; weekly handoff meeting.
- [ ] Severity definitions written down + agreed by the team.
- [ ] Monthly DR drill scheduled; the script runs; the scoring (RTO /
      RPO / human action time) is recorded.
- [ ] Quarterly chaos game-day scheduled; the Chaos Mesh Workflow runs
      against staging; postmortems published.
- [ ] Postmortem template used for every P0/P1; action items tracked
      to completion; > 80 % closure rate.
- [ ] Runbooks not exercised in 90 days carry a STALE banner; the
      quarterly review re-exercises them.

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Synthesise the eleven prior chapters: which capability from each chapter directly enables the on-call engineer's 3am workflow, and which capability is "important but not what gets used at 3am"?**
   <details><summary>Show answer</summary>

   *Used at 3am*: ch.02 tenant labels (route the alert), ch.04 IRSA-debugged JWT (the on-call needs to authenticate), ch.06 outbox+idempotency (the engineer can replay events safely), ch.07 WAF audit logs (rule out attack vector), ch.09 Grafana per-tenant + Tempo trace + Loki logs (the diagnosis stack), ch.12 (this chapter) runbook itself. *Important but not at 3am*: ch.03 multi-region DR (the drill is monthly, not 3am), ch.05 search reindexing (a slow problem), ch.08 ML drift retrain (a daytime concern), ch.10 cost (a weekly review), ch.11 Backstage (a daytime developer surface). The runbook is the 3am UI; everything else exists so the runbook can be short and decisive.

   </details>

2. **Walk through the structure of a runbook that an on-call engineer can open and act on at 3am — what 5 sections does it need, and what's the failure mode if you omit any?**
   <details><summary>Show answer</summary>

   (1) **Alert** — what fired, the exact PromQL, the dashboard link. Without this, the engineer rummages. (2) **Likely causes** — 2-3 prioritized hypotheses with diagnostic commands. Without this, they Google. (3) **Resolution steps** — concrete kubectl/CLI commands to fix the top 1-2 causes. Without this, they ad-hoc. (4) **Escalation** — when (after 15 min, after data loss risk) to page secondary / engineering manager. Without this, they sit on it. (5) **Verify + close** — how to confirm the alert is genuinely resolved (re-check metric, watch for re-fire over 10 min). Without this, the alert flaps. A runbook missing any of these wastes 10-30 minutes per incident, and the on-call engineer's mood is the difference between "I can do another night" and "I quit."

   </details>

3. **Plan a monthly DR drill that exercises cross-region Postgres failover. What's the script's structure, what's measured, and what's the success criterion?**
   <details><summary>Show answer</summary>

   **Script**: (1) Announce drill window. (2) Snapshot pre-drill metrics (RPO baseline, replication lag). (3) Drain the writer region's network (Chaos Mesh `NetworkChaos` or AWS Console). (4) Execute the runbook: patch `spec.replica.primary` on the standby's CNPG Cluster (13.03 step 8), flip the Argo CD writer label, update DNS. (5) Verify writes resume in new region. (6) Restore the old region as a new standby. (7) Postmortem. **Measured**: RTO (declare-to-writes-resume time), RPO (data lost), Mean Time to Detection, human-action time per step. **Success criterion**: RTO < 5 min, RPO < 60s, every step in the runbook accurate (no "wait, the command was different"), team confidence on a 1-5 scale > 4. Run monthly because (a) staff turnover, (b) infrastructure drifts, (c) the runbook rots if not exercised.

   </details>

4. **Plan a quarterly chaos game-day. What experiments do you run, what's the bounded blast radius, and what's the learning outcome?**
   <details><summary>Show answer</summary>

   **Experiments** (sequenced for compounding stress): (1) Pod-kill `catalog` 50% — does HPA absorb? (2) Network latency 200ms on `catalog → postgres` — does the SLO hold? (3) Stress CPU on storefront — does HPA scale, does PDB hold during deploy? (4) Kill the Karpenter controller — do nodes still scale? (5) Combine: pod-kill + network latency + a deploy simultaneously. **Blast radius**: staging cluster, not prod; bounded by namespace selector; aborted automatically if Bookstore SLO breaches. **Learning outcome**: a list of findings (PDB too loose, retry budget too tight, runbook step missing), each filed as a bug and tracked. The game-day is the chaos-engineering discipline ([Part 11 ch.07](../11-advanced-production-patterns/07-chaos-engineering.md)) applied as a coordinated team event — the team practices working an incident together when it isn't actually one.

   </details>

5. **Close the loop: incident → postmortem → SLO budget → backlog. Walk through one cycle.**
   <details><summary>Show answer</summary>

   (1) **Incident**: catalog 5xx at 14:32 EU region, 35 min duration, ~12k requests failed. (2) **Detection-to-mitigation timeline**: alert fired 14:34 (good), on-call paged 14:35, root cause found 14:48 (Postgres connection pool exhausted), mitigated 15:07 (bumped pool size). (3) **Postmortem (blameless)**: write-up — root cause, timeline, what went well, what went poorly, action items. (4) **SLO budget**: 35 min × 0.5% of EU traffic ≈ 12k errors against monthly budget of ~80k errors. Now at 75% budget — flag to product/eng. (5) **Backlog**: action items become tickets — PGB pool size monitoring + alert, runbook for "pool exhausted" added, load-test gate for pool size in CI. (6) **Quarterly review**: did action items close? Did SLO trend improve? The loop's whole point is that incidents make the system better; without closing the loop, you incident-and-repeat.

   </details>

6. **The "what we did NOT build" list — pick three things the v2 platform deliberately does not include, and justify each.**
   <details><summary>Show answer</summary>

   Open-ended; honest answers: (1) **No service mesh enforced everywhere** — we ambient-mesh the bookstore namespace but don't enforce mesh on platform-system; the cost/complexity vs benefit isn't there for the small platform. (2) **No automated production model promotion** — drift triggers a retrain, but production rollout is human-gated. We don't trust the eval gate to be safe enough for "deploy without a human." (3) **No multi-master Postgres** — active-passive with manual failover is the chosen RTO/RPO. Multi-master adds operational complexity that outweighs the ~3 min RTO improvement at our scale. (4) **No comprehensive cost showback yet** — OpenCost reports but we don't bill tenants per-cluster-hour. Other reasonable picks: no compliance-as-code (SOC2 evidence collection), no zero-trust micro-segmentation, no fully automated chaos in prod (we keep it staging-only). The discipline is: every "did not build" is a deliberate trade with a written reason — not an oversight.

   </details>

7. **Reflection: looking across Parts 00-13, what's the single most important Kubernetes idea that ties the whole guide together?**
   <details><summary>Show answer</summary>

   Open-ended; common reflections: "**Desired state + reconcile loop**" — every controller (deployment, HPA, Argo CD, Crossplane, KServe, operator) is the same pattern at different layers. Once you see it, Kubernetes stops being a list of resource types and starts being a single idea applied recursively. "**Composition**" — Pod is built from Container + SecurityContext + Volume + Probes; Deployment is built from Pods + replicas + strategy; the platform is built from Deployments + Crossplane + Argo CD; every abstraction up the stack is the same compositional model. "**The seam is the API server**" — workloads, infrastructure, identity, policy, all converge on apiserver objects; if you can describe it as a CRD, you can compose it. The point: the guide is one idea taught at 13 levels of zoom. Pick the framing that resonates and use it as your mental model going forward.

   </details>

8. **Chaos Mesh needs privilege that the rest of the guide forbids.
   Which namespace carries it, which namespace carries the experiments,
   and what stops an experiment from placing a privileged Pod in the
   experiments namespace?**
   <details><summary>Show answer</summary>

   The daemon's namespace, `chaos-mesh`, is labelled `privileged` for
   enforce, because the chart's DaemonSet sets `hostPID: true` and runs a
   privileged container. The experiments namespace stays `restricted`:
   the Workflow and the chaos objects need no privilege of their own, and
   admission refuses a privileged Pod placed there, as the probe in
   hands-on section 1 shows. The exception is one namespace with a
   registry entry that expires, so it stays visible and bounded.

   </details>

## Further reading

- **Google SRE Book ch.11 — Being On-Call**
  <https://sre.google/sre-book/being-on-call/>; the discipline of
  on-call this chapter applies.
- **Google SRE Book ch.14 — Managing Incidents**
  <https://sre.google/sre-book/managing-incidents/>; the incident-
  response model behind this chapter's severity matrix.
- **Google SRE Book ch.15 — Postmortem Culture**
  <https://sre.google/sre-book/postmortem-culture/>; the blameless-
  postmortem discipline.
- **Chaos Mesh docs**
  <https://chaos-mesh.org/docs/>; the experiments + Workflow CRDs.
- **PagerDuty Incident Response guide**
  <https://response.pagerduty.com/>; the production-grade incident
  playbook this chapter draws from.
- **Rosso et al., *Production Kubernetes* ch.14 — Application
  Considerations**; the resilience-controls validation this
  chapter automates.
- **Ibryam & Huß, *Kubernetes Patterns* 2e — *Self Healing***;
  the discipline of explicit recovery + replication this chapter's
  resilience controls express.
