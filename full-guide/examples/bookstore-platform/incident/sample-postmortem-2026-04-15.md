# Postmortem — Checkout 5xx Spike During Spring Sale (INC-2026-04-15-001)

> **Reader's guide:** this is a fully worked example postmortem, written
> against the [postmortem template](postmortem-template.md), for a real-
> shape incident on the Bookstore Platform. It is teaching material: read
> it side-by-side with the template to see what "good" looks like.
> Names, tickets, dollar figures are illustrative.

## Metadata

- **Incident ID:** INC-2026-04-15-001
- **Title:** Checkout 5xx spike during Spring Sale flash promotion
- **Date / Time (UTC):**
  - First alert: 2026-04-15 14:03 UTC
  - All-clear: 2026-04-15 14:42 UTC
  - Duration of customer-visible impact: 39 minutes
- **Severity:** P0 (>=50 % of customers affected; checkout broken; revenue-bearing path)
- **Affected tenants:** all (`acme-books`, `globex-press`, `initech-reads`, `umbrella-publishing`, plus 6 free-tier tenants)
- **Affected regions:** us-east-1 (primary), us-west-2 (cascaded via shared ALB)
- **Affected services:** payments-gateway, checkout-orchestrator, storefront (degraded UX from upstream errors)
- **Detection method:** automated alert (`BookstoreCheckoutErrorRateHigh`)
- **Incident Commander (IC):** Carol Mendez @ platform-team
- **On-call primary at time of incident:** Bob Park @ team-payments
- **On-call secondary at time of incident:** Dave Lin @ team-platform
- **Recorder (timeline scribe):** Eve Nakamura @ team-payments
- **Author of this postmortem:** Carol Mendez

## Summary

Between 14:03 and 14:42 UTC on 2026-04-15, the Bookstore Platform's
checkout path returned HTTP 502 for an estimated 78 % of requests in
us-east-1, cascading to us-west-2 via the shared `payments-gateway`
deployment. Root cause: the `payments-gateway` pods were OOMKilled by
the kernel after a flash-promotion traffic spike pushed cart payloads
past the gateway's in-memory parser buffer; the per-request size limit
was 64 MB on the gateway but 1 MB on the storefront, allowing
oversized carts to reach the gateway. Approximately 4,200 checkout
attempts failed; estimated $58,000 in deferred revenue and $12,000 in
SLA credits owed to enterprise tenants. We mitigated by scaling the
`payments-gateway` deployment from 4 to 12 replicas and reducing the
request-body limit to 1 MB at the gateway. Prevention: an admission-
controller invariant check across the storefront -> gateway
request-size contract (Action Item A1).

## Customer impact

- **Number of customers affected:** ~4,200 unique customers across all 10 tenants (we measure unique session IDs that hit `POST /api/checkout` and received a 502 between 14:03 and 14:42 UTC).
- **Tenants affected (named):**
  - `acme-books` (Enterprise tier; got proactive email at 14:35)
  - `globex-press` (Enterprise tier; got proactive email at 14:35)
  - `initech-reads` (Enterprise tier; got proactive email at 14:38)
  - `umbrella-publishing` (Enterprise tier; got proactive email at 14:38)
  - 6 free-tier tenants (no proactive comm per their contract; visible on status page)
- **Revenue impact:**
  - Deferred revenue: ~$58,000 (4,200 attempts × average cart $13.80)
  - SLA credits owed: ~$12,000 (Enterprise tier 99.95% SLA breach; 39 min > 21-min monthly budget)
  - Refund / reorder discounts offered: ~$3,400 (10 % "we're sorry" discount on first 250 customers who emailed support)
- **Data impact:** **None.** No orders entered an inconsistent
  state. The outbox-pattern (ch.13.06) means failed checkouts never
  write to the orders table; Stripe was not charged for any of the
  failed attempts (verified via Stripe dashboard reconciliation
  2026-04-16). The saga-compensation flow was not invoked because
  no payment intent was ever created.
- **SLO impact:** Checkout's monthly error budget (allowed: 21 minutes of >0.1 % errors; 99.95 % SLO) was consumed entirely + overspent by 18 minutes. Error budget alert (`BookstoreCheckoutSLOBurnRate`) fired at 14:08 and again at 14:21. Budget recovery: ~28 days.
- **Status-page entry:** https://status.bookstore-platform.example.com/incidents/2026-04-15-checkout-degraded (link illustrative).
- **Customer-comm artifacts:** 4 enterprise emails sent (Carol drafted, customer-success reviewed, sent within 1 hour of all-clear); 1 public-facing status-page entry with 3 updates; 38 support tickets opened, all responded to within 2 hours.

## Timeline (UTC)

| Time   | Event                                                                              | Source / link |
|--------|------------------------------------------------------------------------------------|---------------|
| 13:55  | Spring Sale promotion went live (planned event; runbook noted "expect 3x traffic for 2 hours") | [marketing-calendar #1842](https://...) |
| 13:58  | Storefront traffic ramped from 800 RPS to 2,400 RPS in 3 minutes                   | [Grafana ramp](https://...) |
| 14:01  | First oversized cart submitted: customer with 1,847 items in cart → 47 MB JSON     | [Loki query](https://...) |
| 14:02  | First OOMKill on `payments-gateway` pod `payments-gateway-7d4f-q2p8`               | [k8s event](https://...) |
| 14:03  | `BookstoreCheckoutErrorRateHigh` alert fired (P0; error rate breached 5 % threshold)    | [Alert rule](https://...) |
| 14:03  | PagerDuty paged primary Bob Park (high-urgency)                                    | PD incident `Q7N8K2` |
| 14:04  | Bob acked the page from his phone                                                  | PD ack at 14:04:18 |
| 14:05  | Bob opened [`runbook-payments-failure-rate.md`](../runbooks/runbook-payments-failure-rate.md) | runbook link |
| 14:06  | Bob ran `kubectl get pods -n bookstore-platform-payments` — saw 4 pods, 3 of them with restartCount ≥ 2 in the last 5 min | runbook Step 1 PASS (real alert, not flapping) |
| 14:07  | Bob created incident Slack channel `#inc-2026-04-15-001`                            | [Slack channel](https://...) |
| 14:08  | `BookstoreCheckoutSLOBurnRate` fired (burn rate >14.4× SLO; 1-hour budget consumed in 4 min) | Alert |
| 14:09  | Bob paged the secondary, Dave Lin: "need a hand; checkout is OOMing"               | PD escalation manual |
| 14:09  | Status-page entry created (manual; Bob): "Investigating checkout errors"           | [status-page v1](https://...) |
| 14:11  | Dave joined; began Step 2 (Diagnose) of the runbook — checked Grafana payments dashboard | Grafana |
| 14:11  | Dave observed: pod memory plot showed 4 GB peak (limit was 2 GB) before OOMKill    | [memory chart](https://...) |
| 14:12  | Bob announced "I'm escalating to a war room; please respect the IC role" — IC role unclaimed at this point | Slack message |
| 14:13  | Carol Mendez (platform lead) joined the Slack channel after seeing the P0 in #platform-leadership | Slack |
| 14:14  | Carol took the IC role: "Carol IC. Bob, you're on diagnosis. Dave, on mitigation. Eve, recording. Status comms through me." | Slack message |
| 14:15  | Zoom war room opened: `https://zoom.us/j/...` (Incident.io auto-created)            | Zoom |
| 14:16  | Carol posted status-page update v2: "Checkout currently degraded; investigating"   | [status-page v2](https://...) |
| 14:18  | Dave proposed mitigation: scale `payments-gateway` from 4 → 12 replicas (more capacity to absorb OOM-driven restarts) | Slack |
| 14:19  | Carol approved; Bob ran `kubectl scale deployment payments-gateway --replicas=12 -n bookstore-platform-payments` | Slack + terminal |
| 14:20  | Karpenter provisioned 1 new node to fit the additional pods (~90 sec)              | [Karpenter event](https://...) |
| 14:22  | 12 replicas all `Running`; error rate dropped from 78 % to 31 %                   | Grafana |
| 14:24  | Bob noticed in the Loki log stream: "request body too large to parse: 47 MB"; recognized the oversized-cart pattern | Loki query |
| 14:26  | Bob proposed a second mitigation: reduce `payments-gateway` body-size limit from 64 MB to 1 MB (matches storefront) | Slack |
| 14:27  | Carol authorized; Bob edited the ConfigMap, did a rolling restart                  | `kubectl edit cm payments-gateway-config`; `kubectl rollout restart deployment payments-gateway` |
| 14:30  | Restart complete; error rate began dropping below 5 %                              | Grafana |
| 14:31  | Carol posted status-page v3: "Mitigation deployed; monitoring"                     | [status-page v3](https://...) |
| 14:33  | Error rate at 0.4 % (within SLO budget for steady-state); back to expected levels  | Grafana |
| 14:35  | Carol began drafting customer email; customer-success reviewed                     | Email draft |
| 14:38  | 4 enterprise emails sent to acme-books, globex-press, initech-reads, umbrella-publishing | Email logs |
| 14:42  | 12-min clean window of green metrics complete; Carol declared all-clear            | Slack message |
| 14:42  | Status-page resolved entry posted                                                  | [status-page v4](https://...) |
| 14:55  | Incident Slack channel pinned for postmortem; Eve finalized timeline                | Slack |
| 14:58  | Postmortem doc started (this document) — first draft outline within 16 minutes of all-clear | This file |

## Root cause (5 Whys)

**Problem:** Checkout returned 5xx for 39 minutes during the Spring Sale promotion, affecting ~4,200 customers across all 10 tenants.

**Why 1 — Why did checkout return 5xx?**
The `payments-gateway` pods were OOMKilled by the kernel within 5
seconds of receiving certain requests; the kernel killed the process,
the kubelet restarted the pod, but during the 30-second restart window
the request load (~2,400 RPS) overwhelmed the remaining 3 pods, which
also began OOMKilling. The error rate spiked because requests routed
to pods that were dying or restarting received TCP RSTs (502s at the
ingress).

**Why 2 — Why were the pods OOMKilled?**
Each pod's memory usage spiked to ~4 GB (limit: 2 GB) when parsing
oversized JSON cart payloads. The `payments-gateway` parses the
entire cart payload in memory before validation; a 47 MB JSON payload
with deeply nested item structures expanded to ~3.2 GB in the
in-memory representation. Combined with the gateway's normal ~600 MB
working-set, this exceeded the 2 GB limit.

**Why 3 — Why was a 47 MB cart payload reaching the gateway?**
The storefront enforces a 1 MB request-body limit (cart size,
inclusive of headers), but the `payments-gateway` accepted bodies up
to 64 MB (the Go `http.MaxBytesReader` default). The customer's cart
was assembled via the API directly (bypassing the storefront UI;
probably a misconfigured tenant integration) and the cart payload
contained 1,847 line items with full metadata = 47 MB. The gateway
saw it, accepted it (under its 64 MB limit), and tried to parse it.

**Why 4 — Why did the gateway have a higher limit than the storefront?**
The 1 MB limit existed in the storefront from day 1. The
`payments-gateway` was rewritten in Q1 2026 (the Go service that
replaced the legacy Java implementation) and the new service used the
Go `http.MaxBytesReader` default (64 MB) instead of being configured
to match the storefront's limit. The rewrite PR was reviewed and
approved; the reviewers did not catch the limit drift because the
limit configuration was not in either service's contract definition.

**Why 5 — Why didn't we catch the cross-service drift?**
There is no mechanism to enforce cross-service configuration
invariants. The storefront's request-size limit and the
payments-gateway's request-size limit are independent configurations
maintained by independent teams. Code reviews focus on per-service
changes; cross-service invariants (e.g. "request-size limit at the
edge must be ≥ request-size limit at every downstream service") are
invisible to the reviewer of a single PR. We have similar invariants
that ARE enforced — e.g. the OpenAPI spec generation pipeline enforces
that every API exposed by the gateway is documented — but we have no
configuration-invariant checker.

**Root cause statement:**
The Bookstore Platform has no mechanism to enforce cross-service
configuration invariants. The `payments-gateway` Q1 rewrite drifted
from the storefront's 1 MB request-size limit to the Go default of 64
MB; the drift was invisible to reviewers because no test, lint, or
admission check exists for cross-service invariants. The Spring Sale
traffic spike + a single oversized cart was the trigger; the missing
invariant check was the cause.

### Contributing factors

- **Contributing factor 1 — pod memory limit too tight for the actual
  workload.** Even if the request-size limit had matched, the
  `payments-gateway`'s 2 GB memory limit was set 18 months ago for a
  smaller request profile. The Q1 rewrite increased the working-set
  size; nobody re-VPA'd the limit. A 4 GB limit would have absorbed
  the oversized request without OOMKilling (though the request would
  still have been malformed).
- **Contributing factor 2 — IC role unclaimed for 12 minutes (14:02 to
  14:14).** Bob attempted to debug AND coordinate AND communicate, all
  three poorly. The status-page entry was 13 minutes late (the P0 SLA
  is "within 15 minutes"; we cleared the bar by 2 minutes). The
  proper IC pattern is one of the responders explicitly takes the IC
  role within 5 minutes of the page.
- **Contributing factor 3 — chaos game-day gap.** The chaos workflow
  has a `payments-failure` experiment (HTTP 500 from Stripe webhook)
  and a `pod-kill` experiment (kills 1 pod), but no experiment for
  "pod OOMKilled under sustained load." The OOMKill blast radius
  pattern is meaningfully different from a pod-kill: in OOMKill, the
  TARGET pod is unhealthy AND the load that killed it is still
  arriving at the survivors.

### Why we did not catch this earlier

- **The alert that should have caught this:** A `BookstorePodOOMKilledRecent`
  alert would have fired on the FIRST OOMKill at 14:02 — a full minute
  before the customer-visible error rate breached the SLO. We do not
  have this alert. (Action item A2.)
- **The dashboard panel that would have shown this:** The
  `bookstore-payments` Grafana dashboard has a memory-usage panel, but
  no OOMKill-event panel. The on-call relies on `kubectl get events`
  during triage rather than seeing OOMKill events in real time on the
  dashboard. (Action item A3.)
- **The chaos experiment that would have surfaced this:** A
  StressChaos experiment that consumes memory inside the
  `payments-gateway` pod (up to 95 % of the limit) under a load-test
  driver would have OOMKilled the pod in staging weeks ago. We do not
  have this experiment. (Action item A4.)
- **The pre-launch readiness check that should have run:** A flash
  promotion of expected 3x traffic should have triggered a load-test
  rehearsal in staging; the standard promotion-readiness checklist
  was not run because Spring Sale was "just another promotion."
  (Action item A5.)

## What went right

- **The outbox pattern saved us from data corruption.** No order made
  it into a half-committed state; Stripe was never charged for any
  failed checkout. The architectural decision in ch.13.06 paid off
  exactly as designed.
- **The runbook `runbook-payments-failure-rate.md` Step 1 (Check) and
  Step 2 (Diagnose) led Bob to the OOMKill pattern within 9 minutes**
  — fast enough that a competent on-call who had never seen this
  failure mode could still resolve it without expert help.
- **Karpenter provisioned the new node in 90 seconds** to absorb the
  scaled-up replica count. The cluster autoscaling design (Part 10 ch.06 — node autoscaling)
  delivered on its promised behaviour.
- **The two-mitigation approach worked.** Mitigation 1 (scale-up)
  reduced the blast radius from 78 % to 31 % within 3 minutes;
  mitigation 2 (size limit reduction) closed the remaining 31 %
  within 5 minutes. Mitigation 1 alone wouldn't have been enough; the
  team correctly identified that more capacity wouldn't fix the
  underlying parser issue and added mitigation 2.
- **Carol took the IC role explicitly at 14:14 and the response
  improved immediately** — status-page updates, customer email,
  recorder role all flowed from a single coordinator.
- **The status-page communication was prompt enough** that no
  enterprise tenant escalated to support before Carol's proactive
  email reached them.

## What went wrong

- **No alert for OOMKill events.** The most important monitoring gap.
  We learned about the OOMKill at 14:02 via the cascading 5xx alert
  at 14:03; with a direct OOMKill alert we would have learned at
  14:02, 1 minute earlier.
- **IC role unclaimed for 12 minutes.** The runbook says "if you can't
  both diagnose AND communicate, escalate to claim an IC"; Bob did
  not claim, and no other responder did, until Carol joined.
- **Status-page entry was 13 minutes late vs. the 15-min SLA target.**
  Inside the SLA but barely; if a similar incident took 4 more minutes
  to set up, we would have breached our customer-communication
  contract.
- **The 64 MB request-body limit lived for 4 months** between the Q1
  rewrite and this incident, invisible to every reviewer of every PR
  in that period. The PR reviewer pattern does not catch
  cross-service drift.
- **No flash-promotion load test was run.** The marketing calendar
  knew Spring Sale was coming; the platform team did not coordinate
  with marketing on a pre-promotion load-test rehearsal.
- **Dashboard didn't show OOMKills.** Memory-usage panel showed the
  spike RETROACTIVELY but not the OOMKill event itself; Bob had to
  `kubectl get events` to find them.

## Action items

| ID  | Description                                                                                       | Owner       | Ticket           | Due        | Priority | Status |
|-----|---------------------------------------------------------------------------------------------------|-------------|------------------|------------|----------|--------|
| A1  | Write a CI lint that asserts `storefront.maxRequestBytes <= payments-gateway.maxRequestBytes`     | Bob Park    | PLAT-1284        | 2026-04-29 | P1       | open   |
| A2  | Add `BookstorePodOOMKilledRecent` PrometheusRule (alerts within 60 sec of any OOMKill in `bookstore-platform-*` namespaces) | Dave Lin    | PLAT-1285        | 2026-04-22 | P1       | open   |
| A3  | Add an OOMKill-event panel to the `bookstore-payments` Grafana dashboard                          | Eve Nakamura| PLAT-1286        | 2026-04-22 | P2       | open   |
| A4  | Add a `StressChaos` memory experiment to the chaos workflow (95 % of memory limit; observe whether pod self-heals or OOMKills) | Bob Park    | PLAT-1287        | 2026-05-13 | P3       | open   |
| A5  | Create a pre-promotion readiness checklist (load-test, capacity review, runbook walkthrough) and add it to the marketing-platform coordination doc | Carol Mendez| PLAT-1288        | 2026-05-06 | P2       | open   |
| A6  | Re-VPA the `payments-gateway` memory limit based on the new working-set profile from the rewrite  | Bob Park    | PLAT-1289        | 2026-04-29 | P2       | open   |
| A7  | Add a "claim the IC role" Slack bot trigger on every P0 page (Incident.io action `incident_commander_check`) | Dave Lin    | PLAT-1290        | 2026-05-13 | P2       | open   |
| A8  | Document the IC role + claim discipline more prominently in `runbook-payments-failure-rate.md` and link from every P0 runbook | Carol Mendez| PLAT-1291        | 2026-04-22 | P3       | open   |

**Closure target:** > 80 % closure by the quarterly review on 2026-07-15.
The platform lead (Carol) reports closure rate at the monthly
postmortem review (see ch.15.11 — postmortem review).

## Lessons

- **Cross-service configuration invariants need automated enforcement.**
  This is not a code-review failure; it is a system design failure.
  Action item A1 ships the first such check; we will inventory the
  other cross-service invariants in PLAT-1292 (separate ticket) and
  ship checks for each.
- **OOMKill is a distinct failure mode that deserves its own alert.**
  We had alerts for "pod restarting too often" but not for "pod
  OOMKilled" — the two failure modes overlap but are not identical.
  OOMKill alerts give us 30-60 seconds of head start over the
  cascading 5xx alert.
- **The IC role must be claimed within 5 minutes of a P0 page, by
  ANY responder.** Bob did not claim; Carol joined and claimed. The
  next P0 should not depend on a senior person happening to be
  online; the on-call's runbook must call this out explicitly.
- **Pre-promotion load tests are part of platform-team responsibility,
  even when marketing owns the promotion.** The platform team is the
  one who pays the page; the platform team is the one who
  coordinates load-test rehearsals.
- **The PDB / replicaCount / outbox pattern combo worked.** The
  resilience controls did exactly what they were designed to do; the
  failure was a configuration drift the controls could not see.

## Related artefacts

- **Runbooks consulted:** [`runbook-payments-failure-rate.md`](../runbooks/runbook-payments-failure-rate.md)
- **Dashboards consulted:** `https://grafana.bookstore-platform.example.com/d/bookstore-payments` (illustrative)
- **Alerts that fired:** `BookstoreCheckoutErrorRateHigh` (14:03 UTC), `BookstoreCheckoutSLOBurnRate` (14:08 UTC), `BookstoreCheckoutSLOBurnRate` (14:21 UTC re-fire)
- **PagerDuty incident:** `Q7N8K2` (https://your-org.pagerduty.com/incidents/Q7N8K2)
- **Incident Slack channel:** `#inc-2026-04-15-001`
- **War-room Zoom recording:** stored in Drive; access on request
- **Commits / PRs related:**
  - Q1 rewrite that introduced the 64 MB default: PR #4128 (2026-01-23)
  - Mitigation: ConfigMap edit recorded in [`runbooks/runbook-payments-failure-rate.md`](../runbooks/runbook-payments-failure-rate.md)
  - Fix forward: PR #5921 (2026-04-16; sets explicit 1 MB limit)
- **Chaos experiments related:** existing `payments-failure` (HTTP 500); proposed `payments-oom-stress` (Action A4)

## Customer communication

- **Status-page entries:**
  - v1 (14:09): "Investigating checkout errors"
  - v2 (14:16): "Checkout currently degraded; investigating"
  - v3 (14:31): "Mitigation deployed; monitoring"
  - v4 (14:42): "Resolved"
- **Email to affected tenants:** drafted 14:35, final 14:36, sent 14:38 to enterprise tenants (acme-books, globex-press, initech-reads, umbrella-publishing) — recipient list: each tenant's incident-contact per CRM.
- **Support tickets opened by customers:** 38 total; 100 % responded to within 2 hours; 250 customers offered a 10 % discount on next purchase.
- **Public-facing postmortem published?** Yes — sanitized version published to status page on 2026-04-21 (6 business days, slightly past target; tracked as a process improvement under A5).

## Publication checklist

- [x] Posted in `#bookstore-platform-postmortems` Slack channel (2026-04-19).
- [x] Linked in the platform's GitHub Wiki / `docs/postmortems/INC-2026-04-15-001.md`.
- [x] Filed in the platform's GitHub Project board (postmortem-tracking).
- [x] Action items have owners + due dates + tracking tickets.
- [x] Discussed at the platform all-hands on 2026-04-23.
- [x] Public-facing version posted to status page on 2026-04-21.
- [x] Customer-success notified; no tenant required additional direct comm beyond the initial enterprise email.

## Sign-off

| Role               | Name           | Date       |
|--------------------|----------------|------------|
| Incident Commander | Carol Mendez   | 2026-04-19 |
| Platform Lead      | Carol Mendez   | 2026-04-19 |
| Eng Director       | Frank Okolo    | 2026-04-20 |
| CTO                | Grace Iwata    | 2026-04-21 |

---

## Reader's takeaway

This postmortem demonstrates the discipline the template asks for:

1. **The 5 Whys went all the way to a system-level cause** — the
   absence of cross-service invariant enforcement — rather than
   stopping at "Bob should have caught it in code review."
2. **Every action item has all four fields** (owner, ticket, due date,
   priority). Items without all four don't ship; the platform lead
   pushes back during postmortem review.
3. **What-went-right is as long as what-went-wrong.** The resilience
   patterns that worked deserve as much attention as the gaps; if you
   only document failures, the team forgets why the patterns matter.
4. **The timeline is dense, not narrative.** UTC timestamps, specific
   commands, specific links. A reader new to this incident can
   reconstruct what happened in 10 minutes.
5. **The customer-impact section uses real numbers.** $58,000 deferred
   + $12,000 credits + $3,400 in discounts = $73,400 total impact.
   Numbers drive prioritization of the action items in the next
   sprint.
6. **The author is the IC, not the on-call who handled the alert.**
   This is by design: the IC has the cross-functional view; the
   on-call has the technical view; the postmortem needs both, but
   the IC has the better starting position for the summary +
   customer-impact sections.
