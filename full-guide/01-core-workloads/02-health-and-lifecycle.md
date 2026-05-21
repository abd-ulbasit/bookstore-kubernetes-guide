# 02 — Health and lifecycle

> Liveness, readiness, and startup probes; the four probe handlers and every
> tuning parameter; `postStart`/`preStop` hooks; `SIGTERM` +
> `terminationGracePeriodSeconds` and the graceful-shutdown contract — applied
> by making the catalog Pod self-diagnosing and shutdown-safe.

**Estimated time:** ~15 min read · ~30 min hands-on
**Prerequisites:** [Part 01 ch.01](01-pods.md) — Pod phases and conditions
**You'll know after this:** • choose between liveness, readiness, and startup probes for a service · • configure all four probe handlers (httpGet, tcpSocket, exec, grpc) and tune timing parameters · • implement `preStop` hooks and respect `terminationGracePeriodSeconds` · • write a graceful-shutdown handler that drains connections before SIGKILL · • debug a Pod that fails or flaps on its probes

<!-- tags: core-objects, probes, liveness, readiness, lifecycle, graceful-shutdown -->

## Why this exists

[ch.01](01-pods.md) showed a Pod's `phase` is coarse and the `Ready` condition
is what actually gates traffic. But who *sets* `Ready`, and how does Kubernetes
know a process is **alive but wedged** (deadlocked, leaked all goroutines) vs.
**alive but not yet usable** (still loading cache, DB not connected) vs. simply
**not done starting**? The container "running" tells you the *process* exists,
not that the *application* works. Without health signals Kubernetes would route
users to a hung Pod and never restart a process stuck in an infinite loop.

Equally, the *end* of a Pod's life is a contract, not an event. When Kubernetes
removes a Pod (rollout, scale-down, eviction) it must let in-flight requests
finish and the process flush state — otherwise every deploy drops connections.
This chapter is the **liveness/readiness/startup** triad plus the **termination
sequence**: the two halves that make a workload survivable in production. They
are exactly the [Health Probe](#further-reading) and [Managed
Lifecycle](#further-reading) patterns.

## Mental model

Kubernetes cannot read your app's mind, so the app must **answer three
questions on demand**, and Kubernetes acts on the answers:

- **Liveness — "are you wedged?"** Fail repeatedly → kubelet **kills and
  restarts the container** (same Pod, same node). For unrecoverable internal
  hangs only.
- **Readiness — "should you get traffic *right now*?"** Fail → the Pod is
  **removed from Service endpoints** (no traffic) but **not restarted**. For
  transient "busy / dependency down / draining" states. This is the probe that
  sets the `Ready` condition from [ch.01](01-pods.md).
- **Startup — "have you finished booting?"** While it has not yet succeeded,
  **liveness and readiness are suspended**. For slow-starting apps, so a long
  boot is not misread as a liveness failure.

Symmetrically, shutdown is a **negotiated drain**, not a `kill -9`: Kubernetes
says "please stop" (`SIGTERM`), waits up to a grace period while you finish
in-flight work and fail readiness so traffic drains, and only then forces the
issue (`SIGKILL`). Healthy in production = *correctly answers the three probes*
**and** *shuts down within the grace period*.

## Diagrams

### Probe outcomes: restart vs. endpoint removal (Mermaid)

```mermaid
sequenceDiagram
    participant K as kubelet (on the node)
    participant C as container (catalog)
    participant EP as EndpointSlice controller / Service

    Note over K,C: startup probe runs FIRST; liveness+readiness suspended until it passes
    K->>C: GET /healthz  (startup)
    C-->>K: 200  ⇒ startup OK, enable liveness+readiness

    loop every periodSeconds
        K->>C: GET /healthz  (liveness)
        C-->>K: 200  ⇒ alive, do nothing
        K->>C: GET /readyz   (readiness)
        C-->>K: 200  ⇒ Ready=True
        K->>EP: Pod is Ready ⇒ keep in endpoints (gets traffic)
    end

    Note over C: dependency drops (DB down)
    K->>C: GET /readyz
    C-->>K: 503  (failureThreshold times)
    K->>EP: Ready=False ⇒ REMOVE from endpoints (no traffic, NOT restarted)

    Note over C: process deadlocks (event loop stuck)
    K->>C: GET /healthz (liveness)
    C--xK: timeout/err (failureThreshold times)
    K->>C: SIGTERM → (grace) → SIGKILL, then RESTART container
```

### Termination sequence: preStop → SIGTERM → grace → SIGKILL (Mermaid)

```mermaid
sequenceDiagram
    participant API as API server
    participant K as kubelet
    participant EP as EndpointSlice ctrl
    participant App as app process (PID 1)

    API->>K: Pod deletion (deletionTimestamp set; grace clock starts)
    par drain path (concurrent!)
        API->>EP: Pod terminating ⇒ remove from endpoints
        EP-->>EP: Services stop sending NEW traffic
    and stop path
        K->>App: run preStop hook (native sleep 5) — blocks before SIGTERM
        K->>App: SIGTERM  (app: stop accepting, drain in-flight, exit)
    end
    alt app exits before grace period ends
        App-->>K: process exits 0  ⇒ Pod removed cleanly
    else grace period (terminationGracePeriodSeconds) elapses
        K->>App: SIGKILL (forced) ⇒ in-flight work lost
    end
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** Continues
the Pod from [ch.01](01-pods.md)
([`02-catalog-pod-sidecar.yaml`](../examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml)).
The catalog app **already implements the right endpoints** (verified in its
source): `GET /healthz` is always `200 {"status":"ok"}` (liveness),
`GET /readyz` returns `503` when a configured DB/cache is unreachable else `200`
(readiness). It also handles `SIGTERM` with a 15 s graceful HTTP drain. We add
the probes and a `preStop` hook to the Pod template; we are *wiring* Kubernetes
to signals the app already emits.

### 1. Add probes + a preStop hook

We evolve the Pod template in place (still the `catalog` object, label
unchanged). The probe-and-lifecycle block is added to the `catalog` container of
`02-catalog-pod-sidecar.yaml`. The relevant addition:

```yaml
    - name: catalog
      image: bookstore/catalog:dev
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
      env:
        - name: PORT
          value: "8080"

      # --- Health: the app already exposes these exact routes -------------
      startupProbe:                # gate: "has it finished booting?"
        httpGet: { path: /healthz, port: http }
        periodSeconds: 5
        failureThreshold: 30       # up to 5s*30 = 150s to start before we give up
        # while startup has not yet succeeded, liveness & readiness are PAUSED

      livenessProbe:               # "is it wedged?" fail ⇒ restart container
        httpGet: { path: /healthz, port: http }
        initialDelaySeconds: 0     # startupProbe already covers slow boot
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3        # 3 consecutive fails (~30s) ⇒ kill+restart
        successThreshold: 1        # liveness MUST be 1 (API rejects >1)

      readinessProbe:              # "send traffic now?" fail ⇒ out of endpoints
        httpGet: { path: /readyz, port: http }
        periodSeconds: 5
        timeoutSeconds: 2
        failureThreshold: 3        # 3 fails ⇒ removed from Service endpoints
        successThreshold: 1        # back to 1 success ⇒ re-added

      # --- Lifecycle: graceful drain on shutdown -------------------------
      lifecycle:
        preStop:
          # NATIVE sleep handler (Beta/on-by-default in 1.30, GA in 1.33).
          # Runs BEFORE SIGTERM. Gives the EndpointSlice controller time to
          # pull this Pod from Services so no NEW request arrives during the
          # app's own in-flight drain. We do NOT use `exec` here: the catalog
          # image is gcr.io/distroless/static:nonroot — it has NO shell AND
          # NO coreutils, so an `exec` preStop running `/bin/sh` *or*
          # `/bin/sleep` would error and the grace delay would be silently
          # skipped. The native `sleep` handler needs no in-image binary.
          sleep:
            seconds: 5
  # Pod-level: how long after SIGTERM before SIGKILL. Must exceed
  # preStop + the app's own drain (the app drains HTTP for up to 15s).
  terminationGracePeriodSeconds: 30
```

The full evolved file is saved alongside the others; the probe block above is
the increment this chapter adds. Apply and watch the conditions move:

```sh
# from the repo root (full-guide/)
kubectl apply -f examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml
kubectl get pod catalog -w        # READY 0/2 → 2/2 once startup+readiness pass
kubectl describe pod catalog | sed -n '/Conditions:/,/Events:/p'
```

### 2. Watch readiness gate traffic (without restarting)

`/readyz` returns `200` here because no `DB_DSN`/`REDIS_ADDR` is set (the app
serves sample data and reports ready). Probe behavior is observable in events:

```sh
kubectl get pod catalog \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
#   Ready=True / ContainersReady=True  ← set by the readiness probe
kubectl describe pod catalog | grep -A2 -i 'startup\|liveness\|readiness' | head
```

When the DB *is* added in [Part 03](../03-config-and-storage/02-secrets.md),
`/readyz` will flip to `503` until Postgres is reachable — the Pod will run but
receive no traffic, exactly the readiness contract, with **no restart**.

### 3. Observe graceful termination

```sh
# In one terminal, watch the app's own logs (it logs the SIGTERM + drain):
kubectl logs -f catalog -c catalog &
# Delete with the default grace period and time it:
time kubectl delete pod catalog
#   logs show: "shutdown signal received" "signal":"terminated"
#              → "shutdown complete"  (graceful HTTP drain, app exited 0)
#   deletion takes ~preStop(5s)+drain, well under the 30s grace cap
```

Compare with a forced kill to *see* the difference:

```sh
kubectl apply -f examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml
kubectl delete pod catalog --grace-period=0 --force   # SIGKILL immediately
#   NO "shutdown complete" line — in-flight requests would have been dropped.
#   (Never use --force in production except for truly stuck Pods.)
kubectl apply -f examples/bookstore/raw-manifests/02-catalog-pod-sidecar.yaml  # restore
```

## Probe handlers and every parameter

A probe is **handler + schedule**. Four handlers:

| Handler | Succeeds when | Use for |
|---|---|---|
| `httpGet` | HTTP status 200–399 to `path:port` | HTTP servers (catalog uses this) |
| `tcpSocket` | TCP connect to `port` succeeds | non-HTTP TCP (e.g. a DB port) |
| `exec` | a command in the container exits `0` | CLI healthcheck; no HTTP server |
| `grpc` | the gRPC health service returns `SERVING` (GA 1.27+) | gRPC services |

Schedule/tuning fields (apply to all three probe *kinds*):

| Field | Meaning | Note |
|---|---|---|
| `initialDelaySeconds` | wait after container start before first probe | prefer a `startupProbe` over a large value here |
| `periodSeconds` | seconds between probes (default 10) | tighter = faster detection, more load |
| `timeoutSeconds` | per-probe timeout (default 1) | raise for slow handlers; too low = false failures |
| `failureThreshold` | consecutive failures before acting (default 3) | liveness: kill; readiness: deendpoint |
| `successThreshold` | consecutive successes to be "passing" (default 1) | **must be 1 for liveness & startup** |
| `terminationGracePeriodSeconds` (probe-level) | override Pod grace for a liveness-triggered kill | optional, per-probe |

The three probe **kinds** use the same fields but mean different things:

- **`startupProbe`** runs first; until it succeeds once, `livenessProbe` and
  `readinessProbe` do not run. Effective max boot time =
  `failureThreshold × periodSeconds`. Use it instead of a big
  `initialDelaySeconds` so a *post-boot* hang is still caught quickly.
- **`livenessProbe`** failure ⇒ kubelet kills the container; `restartPolicy`
  decides if it comes back. **Too aggressive a liveness probe is a classic
  outage cause** (a slow dependency makes every replica fail liveness and
  restart-loop simultaneously). Liveness should test *only the process itself*,
  never downstream dependencies.
- **`readinessProbe`** failure ⇒ Pod removed from all Service EndpointSlices;
  it keeps running and is re-added on success. This is the *only* probe that
  may legitimately check dependencies (DB/cache reachable), and is how rolling
  updates ([ch.04](04-replicasets-and-deployments.md)) avoid sending traffic to
  not-yet-ready new Pods.

## Lifecycle hooks

`lifecycle.postStart` and `lifecycle.preStop` (each `exec`, `httpGet`, or
`sleep`):

- **`postStart`** runs immediately *after* the container is created, **not**
  ordered against the entrypoint (they race). It must finish before the
  container is considered `Running`/started; a failing `postStart` kills the
  container. Rarely needed (use init/native-sidecar containers for setup) — but
  useful for registering with an external system.
- **`preStop`** runs *before* `SIGTERM` is sent and **blocks** it until the
  hook returns (bounded by the grace period). The canonical use is a short
  delay (here `sleep: { seconds: 5 }`) to bridge the **race** between "Pod
  marked terminating" and "kube-proxy on every node actually stops sending it
  traffic": you want endpoint removal to propagate *before* the app stops
  accepting connections, otherwise some requests hit a closing socket. (A
  `sleep` preStop is the standard, slightly blunt, fix; a mesh/handler that
  waits for connection drain is the precise one.)

> **Why the native `sleep` handler, not `exec`.** A `preStop` can be `exec`,
> `httpGet`, or **`sleep`**. The obvious "sleep" —
> `exec: { command: ["/bin/sleep","5"] }` — **does not work on distroless/static images**: the
> Bookstore Go images are `gcr.io/distroless/static:nonroot`, which contain
> *only* the app binary — no shell **and no coreutils**, so neither `/bin/sh`
> nor `/bin/sleep` exists. An `exec` preStop pointing at a missing binary
> fails, and Kubernetes then proceeds straight to `SIGTERM` — the grace delay
> is **silently skipped**, quietly defeating the very drain this hook exists
> for. The native **`lifecycle.preStop.sleep`** handler (Beta and on by
> default in 1.30, **GA in 1.33** — well within this guide's v1.30+ target)
> is implemented by the kubelet itself and needs **no in-image binary**, so
> it works on distroless. Always prefer it for the "pause before SIGTERM"
> pattern.

The full shutdown order: deletion → (`deletionTimestamp` set, grace clock
starts; endpoint removal begins **in parallel**) → `preStop` runs to completion
→ `SIGTERM` to PID 1 → app drains in-flight & exits → if grace elapses first,
`SIGKILL`. **`terminationGracePeriodSeconds`** (Pod-level, default 30) must be
≥ `preStop` duration **+** the app's own drain time, or `SIGKILL` truncates the
drain.

> The graceful-shutdown **contract** the app must uphold (the Bookstore catalog
> does): on `SIGTERM`, *stop accepting new work, finish in-flight work, release
> resources, exit 0* — all within the grace period. Kubernetes guarantees the
> signal and the window; the application must do the draining. A process that
> ignores `SIGTERM` is always `SIGKILL`ed and always drops connections on every
> deploy.

## How it works under the hood

- **The kubelet runs probes locally, not the API server.** The kubelet on the
  node executes every probe against the container directly (no network hop
  through the control plane). Probe results update
  `status.containerStatuses[].ready` and the Pod's `Ready` condition; the
  **EndpointSlice controller** ([Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md))
  watches that and adds/removes the Pod IP from Service EndpointSlices. So
  "readiness controls traffic" is two decoupled loops: kubelet writes
  readiness; endpoint controller reacts. There is inherent propagation delay
  (probe period + watch + kube-proxy program time) — the reason for the
  `preStop` sleep.
- **Restart from liveness is local and backed-off.** A liveness kill restarts
  the container *in place* (same Pod/IP) with exponential backoff capped at
  5 min (`CrashLoopBackOff`) — identical mechanism to a crash
  ([ch.01](01-pods.md)). Liveness does **not** reschedule to another node.
- **`SIGTERM` goes to PID 1 of the container.** Whether the app receives it
  depends on it being PID 1 (or a proper init forwarding signals). Distroless
  static images run your binary as PID 1, so the Go `signal.Notify` handler
  fires directly — which is why the Bookstore drains cleanly.
- **Startup probe gating is a kubelet state machine.** The kubelet tracks
  "startup satisfied" per container; liveness/readiness probe goroutines do not
  even start until it flips, guaranteeing slow boots can't be misclassified as
  liveness failures.
- **Termination concurrency.** Endpoint removal and the preStop/SIGTERM path
  run **concurrently** the moment the Pod gets a `deletionTimestamp`. Nothing
  serializes "traffic fully stopped" before "SIGTERM sent" — that ordering is
  *approximated* by the `preStop` sleep, which is why it exists.

## Production notes

> **In production:** make **liveness shallow, readiness deep**. Liveness must
> probe only "is this process internally functional" (a cheap in-process
> check). If liveness transitively pings the DB, a brief DB blip restarts every
> replica at once → a self-inflicted full outage. Dependency checks belong in
> **readiness** (lose traffic, recover automatically) — never in liveness.

> **In production:** always set a **`startupProbe`** for anything with a
> non-trivial boot (JVM warmup, large cache load, migrations). Sizing liveness
> `initialDelaySeconds` for worst-case boot makes post-boot hangs slow to
> detect; a startup probe decouples the two.

> **In production:** size `terminationGracePeriodSeconds` to the **real**
> worst-case in-flight request time **plus** the `preStop` sleep, and have the
> app actually drain on `SIGTERM`. Long-running requests (uploads, streaming,
> slow DB) need a larger grace period; otherwise every rollout
> ([ch.04](04-replicasets-and-deployments.md)) and node drain
> ([Part 08](../08-day-2-operations/01-cluster-lifecycle.md)) drops them.

> **In production:** the **`preStop` sleep is load-bearing**, not cargo-cult.
> Without it, the window between "Pod terminating" and "every node's kube-proxy
> stopped routing to it" causes a burst of connection-refused errors on every
> deploy. 5–15 s is typical; tune to your dataplane's propagation.

> **In production:** EKS/GKE/AKS behave the same for probes (kubelet-local), but
> **cloud Load Balancers have their own health checks** with independent
> timing. A Pod can be Kubernetes-Ready while the cloud LB still considers the
> node unhealthy (or vice-versa). Align LB health-check path/intervals with the
> readiness probe and account for both drains on rollout (covered in
> [Part 02 ch.04](../02-networking/04-ingress.md) /
> [Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md)).

## Quick Reference

```sh
kubectl describe pod <P>                                   # probe results + Events
kubectl get pod <P> -o jsonpath='{.status.conditions}'     # Ready / ContainersReady
kubectl get events --field-selector involvedObject.name=<P> --sort-by=.lastTimestamp
kubectl delete pod <P>                                     # graceful (default grace)
kubectl delete pod <P> --grace-period=0 --force            # SIGKILL (emergency only)
kubectl explain pod.spec.containers.livenessProbe --recursive
```

Minimal health+lifecycle skeleton:

```yaml
containers:
  - name: app
    image: <img>
    ports: [ { name: http, containerPort: 8080 } ]
    startupProbe:   { httpGet: { path: /healthz, port: http }, periodSeconds: 5,  failureThreshold: 30 }
    livenessProbe:  { httpGet: { path: /healthz, port: http }, periodSeconds: 10, failureThreshold: 3 }
    readinessProbe: { httpGet: { path: /readyz,  port: http }, periodSeconds: 5,  failureThreshold: 3 }
    lifecycle:
      preStop: { sleep: { seconds: 5 } }   # native handler (beta & default-on at 1.30, GA 1.33); works on distroless
# Pod level:
terminationGracePeriodSeconds: 30
```

Checklist:

- [ ] Liveness checks only the process; never a downstream dependency
- [ ] Readiness reflects "can serve now" incl. dependency reachability
- [ ] `startupProbe` present for any non-trivial boot time
- [ ] `successThreshold: 1` for liveness and startup (others rejected)
- [ ] `preStop` sleep to cover endpoint-removal propagation
- [ ] App handles `SIGTERM` (drain + exit 0) within the grace period
- [ ] `terminationGracePeriodSeconds` ≥ preStop + worst-case drain

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Why is "liveness checks the DB" a classic outage anti-pattern, and where should that check actually live?**
   <details><summary>Show answer</summary>

   If liveness pings the DB, a brief DB outage makes every replica fail liveness, the kubelet kills and restarts each, they restart-loop simultaneously — the cluster amplifies the DB blip into a full self-inflicted outage with no human action. Liveness must check only intra-process health (event loop alive, mutexes not deadlocked). Dependency reachability belongs in readiness, where failure drops the Pod from endpoints *without* restart (see §Production notes and §Probe handlers).

   </details>

2. **A teammate observes ~1 second of `connection refused` errors on every rollout. The app handles SIGTERM correctly. What's the most likely cause and what one-line manifest change fixes it?**
   <details><summary>Show answer</summary>

   The endpoint-removal propagation race: the Pod gets `deletionTimestamp` and SIGTERM concurrently, but kube-proxy on every node hasn't yet flushed its rules — new traffic still arrives at a closing socket. Fix with `lifecycle.preStop.sleep.seconds: 5` (native sleep handler) so endpoint removal propagates before the app stops accepting (see §Lifecycle hooks and §Production notes, "preStop sleep is load-bearing").

   </details>

3. **The catalog image is `gcr.io/distroless/static:nonroot`. Why does `lifecycle.preStop.exec: { command: ["/bin/sleep","5"] }` *silently* fail (no grace delay) on it, and what's the right replacement?**
   <details><summary>Show answer</summary>

   Distroless static has no shell *and no coreutils* — there is no `/bin/sleep`. An `exec` preStop pointing at a missing binary fails, Kubernetes proceeds directly to SIGTERM, and the grace delay is silently skipped. Use the native `lifecycle.preStop.sleep: { seconds: 5 }` handler (beta default-on in 1.30, GA 1.33) implemented by the kubelet itself — no in-image binary required (see §Why the native `sleep` handler).

   </details>

4. **The catalog Pod sets `failureThreshold: 30` and `periodSeconds: 5` on its startup probe but a much shorter liveness `failureThreshold: 3`. Explain the design — what would break if you tried to encode boot time via a large `initialDelaySeconds` on liveness instead?**
   <details><summary>Show answer</summary>

   Startup gates liveness/readiness — they don't run until startup passes (effective boot window = 5×30 = 150s here). After boot, liveness runs at its tight cadence so a post-boot hang is caught in ~30s. Encoding boot via large `initialDelaySeconds` on liveness means *post-boot* hangs also take that long to detect — slow detection of real wedges. Startup decouples slow boot from fast hang detection (see §Probe handlers and parameters).

   </details>

5. **Hands-on extension: with the catalog Pod running, run `kubectl delete pod catalog` in one terminal and `kubectl logs -f catalog -c catalog &` in another. Time it. Then re-apply and run `kubectl delete pod catalog --grace-period=0 --force`. What's the observable difference and what does it prove?**
   <details><summary>What you should see</summary>

   Graceful: you see `shutdown signal received` then `shutdown complete`, takes ~5s preStop + a bit of drain, deletion completes well under 30s. Force: no `shutdown complete` line — the process is SIGKILLed, any in-flight requests would be dropped. This proves the graceful-shutdown contract is real: the app drains because it received SIGTERM with time to handle it, not because Kubernetes did something magical (see §3. Observe graceful termination).

   </details>

## Further reading

- **Lukša, _Kubernetes in Action_ 2e, ch.6 — "Managing the Pod lifecycle"** —
  liveness/readiness/startup probes, lifecycle hooks, and graceful shutdown.
- **Ibryam & Huß, _Kubernetes Patterns_ 2e** — *Health Probe* (ch.4) and
  *Managed Lifecycle* (ch.5): the contract an app must implement to be a
  well-behaved Kubernetes citizen.
- Official:
  <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>
  and
  <https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/>
  (hooks + termination).
