# Chaos Game-Day — Quarterly Playbook

The quarterly chaos game-day. Hypothesis-driven, blast-radius-bounded,
postmortem-closed. Runs against the **staging** cluster (never
production at v2's maturity level). Five experiments + observation
windows + postmortems.

## Schedule

- **Frequency:** quarterly (every ~12 weeks).
- **Duration:** half-day (4 hours), with 30-minute experiment slots +
  10-minute observation windows.
- **Cluster:** staging (`kind-bookstore-platform-staging`); NEVER
  production.
- **Time:** during business hours (10:00-14:00 UTC); the team is
  awake; we WANT the runbook to be exercised by humans.

## Roles

- **Game-day lead.** Owns the day; runs the script; calls aborts.
- **Observer.** Watches the SLO dashboards; logs reactions; OK-or-
  abort calls.
- **Runbook driver.** Pretends to be the on-call; uses ONLY the
  runbook (no out-of-band knowledge); shows what works + what is
  ambiguous.
- **Recorder.** Captures the timeline; writes the postmortem stub.
- **Team observers.** Anyone else — silent unless asked.

## Safety boundary

- Staging only.
- One experiment at a time.
- Maximum blast radius:
  - Pod-level: `mode: one` (one Pod).
  - Network: 1 minute of injected delay/loss.
  - I/O: 1 minute of throttle.
  - Region-loss: simulated by cordoning a node group, not a real
    region.
- Abort condition: a Prometheus query that fails the experiment
  early (e.g. "5xx rate > 50 % for 30 s" → abort).
- Manual abort: the game-day lead can call abort at any time.

## The five experiments

Each experiment is declared in `chaos-experiments.yaml` (a Chaos Mesh
Workflow). Each has:

1. A **hypothesis** ("storefront stays up").
2. A **safety boundary** ("one Pod; 60 s").
3. An **abort condition** (a Prometheus query).
4. An **observation window** (10 min after the fault clears).
5. A **postmortem requirement** (even if the experiment passed).

### Experiment 1 — pod-kill (payments-gateway)

- **Hypothesis:** When one `payments-gateway` Pod is killed in
  `bookstore-platform-acme-books`, the storefront's `/healthz` stays
  at 200 OK, and the catalog's p99 latency stays under 100 ms. The
  PodDisruptionBudget keeps `minAvailable: 2`.
- **Inject:** Chaos Mesh `PodChaos` with `action: pod-kill, mode: one,
  duration: 60s`.
- **Abort:** 5xx rate > 5 % for 30 s.
- **Observed:** storefront stays up; PDB preserves replica count.
- **Why it matters:** rolling restarts + node failures look like this.

### Experiment 2 — network-delay (catalog → orders)

- **Hypothesis:** When 200ms latency is injected on the
  catalog→orders network path, the catalog's p99 stays under 500 ms
  (the timeout + retry logic handles it).
- **Inject:** Chaos Mesh `NetworkChaos` with `action: delay,
  latency: 200ms, duration: 5m`.
- **Abort:** p99 > 2 s for 1 min.
- **Observed:** retries fire; p99 stays bounded; no 5xx spike.
- **Why it matters:** cross-region calls + noisy neighbours look like
  this.

### Experiment 3 — io-stress (CNPG node)

- **Hypothesis:** When I/O stress is applied to the CNPG primary's
  node, the database's connection pool stays under 80 % usage; the
  catalog and orders services see < 1 s p99.
- **Inject:** Chaos Mesh `StressChaos` with `stressors: io: workers:
  4, duration: 2m`.
- **Abort:** CNPG replication lag > 60 s.
- **Observed:** I/O degraded; replication slows but doesn't break;
  read replicas serve some traffic.
- **Why it matters:** disk saturation in cloud-managed disks is
  common; this is the resilience drill.

### Experiment 4 — region-DNS-loss (simulated cross-region outage)

- **Hypothesis:** When cross-region DNS resolution fails (a Chaos
  Mesh `DNSChaos` returns NXDOMAIN for
  `*.bookstore-platform.example.com`), the saga compensates and the
  DR runbook completes in < 30 minutes; eu-west becomes primary;
  checkout works against eu-west.
- **Inject (primary):** Chaos Mesh `DNSChaos` with `action: error,
  mode: all, patterns: ["*.bookstore-platform.example.com"]`,
  scoped to pods labeled `app.kubernetes.io/part-of:
  bookstore-platform`.
- **Inject (complementary):** the game-day lead also runs
  `kubectl cordon` on all us-east nodes + drain — disrupting what
  the *cluster* sees of its own nodes, while DNSChaos disrupts what
  the *application* sees of remote regions. The two are designed
  to be exercised together.
- **Abort:** runbook driver cannot recover in 60 minutes; the lead
  calls abort + restores.
- **Observed:** the runbook driver follows
  `dr-drill-script.sh`; RTO is measured; RPO is measured.
- **Why it matters:** the actual disaster scenario.

### Experiment 5 — payments-gateway-failure (Stripe 500)

- **Hypothesis:** When the Stripe webhook returns 500 to 30 % of
  callbacks, the saga compensation in payments-worker fires; failed
  orders are rolled back; no order is left in `payment_pending` for
  more than 5 minutes.
- **Inject:** Custom toxiproxy / mock-stripe pod returning HTTP 500
  with probability 0.3.
- **Abort:** payments-worker queue depth > 1000 (a backlog explosion).
- **Observed:** the saga's compensation transactions appear in the
  outbox; the failed orders are correctly rolled back.
- **Why it matters:** the payment failure mode the v1 toy could not
  reproduce; v2 must survive it.

## Runbook drill component

For experiments 1, 2, 3, and 5, the runbook driver follows the
relevant runbook ONLY:

- Experiment 1 → `runbook-api-latency-p99.md` (the PDB held; the
  alert may not fire; the runbook should still document the
  scenario).
- Experiment 2 → `runbook-api-latency-p99.md` (timeout + retry
  path).
- Experiment 3 → `runbook-database-replication-lag.md`.
- Experiment 5 → `runbook-payments-failure-rate.md`.

The driver's job is to **identify ambiguity** in the runbook. If a
step is unclear or the wrong command, that is an action item.

## Observation windows

After each experiment clears, wait **10 minutes** before starting
the next. The observation window catches:

- Delayed effects (a backlog draining; a slow-burning alert).
- The "everything looks fine but a critical metric is silently
  wrong" case.
- The on-call's recovery (was the alert silenced? did it re-fire?).

## Postmortem

For each experiment:

- **Hypothesis met?** Yes / No.
- **Resilience control held?** Which one — PDB / retry / timeout /
  saga.
- **Runbook gaps found?** Each gap → action item.
- **Surprise findings?** Anything unexpected.
- **Action items:** each with owner + ticket + due date.

Template:
[postmortem-template.md](postmortem-template.md). One postmortem
file per experiment; file at
`runbooks/chaos-postmortem-$(date +%F)-experiment-N.md`.

## Trend tracking

Each quarterly game-day produces a row in the team's resilience
dashboard:

| Quarter | Pass count | Fail count | Action items | Action-item closure rate |
|---------|------------|------------|--------------|--------------------------|
| Q1 2026 | 4/5        | 1/5        | 7            | 5/7 closed by Q2         |
| Q2 2026 | 5/5        | 0/5        | 3            | 3/3 closed by Q3         |
| Q3 2026 | TBD        | TBD        | TBD          | TBD                      |

**Target:** > 80 % action-item closure rate by the next game-day.

## Maturity path

The maturity ladder for chaos in production (v2's current rung is
**rung 2**):

1. **rung 1**: chaos in kind / dev.
2. **rung 2**: chaos in staging during business hours. (v2 today)
3. **rung 3**: chaos in staging off-hours.
4. **rung 4**: chaos in production during business hours, one
   experiment per quarter, customer-impact-review-required.
5. **rung 5**: chaos in production automated (the Netflix Chaos
   Monkey shape).

Each rung is a discrete promotion; the team must hit > 90 %
action-item-closure on the previous rung first.

## Last game-day

- **Date:** 2026-04-15.
- **Result:** 4/5 pass (experiment 4 timed out; runbook needs work).
- **Postmortem:** `chaos-postmortem-2026-04-15.md`
  (not shipped in this template; the file exists for each real
  game-day).
- **Next:** 2026-07-15.

## Owners

- **Platform Lead:** owns this playbook + the schedule.
- **Game-day lead:** rotates each quarter.
- **Action items:** the assigned owner; tracked in the platform's
  GitHub project board.
