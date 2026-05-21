# Incident severity matrix — Bookstore Platform v2

> The contract between the platform team, the on-call rotation, and the
> business. Every alert that fires has a severity. Every severity has a
> response-time SLA + a customer-communication requirement + a postmortem
> rule. **This matrix is the document the on-call reads first; everything
> else flows from here.**

The matrix is the source of truth for Alertmanager routing
(`incident/pagerduty-integration.yaml`), PagerDuty escalation policies,
and the postmortem template's `Severity` field.

## Severity ladder

(War room = synchronous video bridge — Zoom/Meet/Slack huddle — opened for P0 incidents.)

| Sev | Customer impact                                            | Page? | Customer comm    | War room | Postmortem  | Examples |
|-----|------------------------------------------------------------|-------|------------------|----------|-------------|----------|
| P0  | >=50 % of customers down OR data loss OR safety / regulatory | PagerDuty + phone call | 15 min on status page + email | within 30 min | mandatory; published within 5 business days | full-platform outage; checkout broken; tenant isolation breach; data corruption confirmed |
| P1  | single region down OR feature broken for ALL tenants OR tenant isolation suspected | PagerDuty page | 1 hour on status page | within 1 hour if not resolved | required within 5 business days | us-east down; search returning empty; recommendations down; webhook delivery >30 min lagged |
| P2  | single tenant affected OR workaround exists OR error rate elevated but bounded | PagerDuty low-urgency page (business hours) | on request | no | optional; team discretion | tenant X's search index lagging; tenant Y over budget warning; payments retries elevated |
| P3  | cosmetic OR internal-only OR maintenance reminder | Slack only | none | no | no | dashboard panel broken; backup retention warning; alert hygiene reminder |

`>=50 %` is the formal P0 threshold. In practice, **any payments-cluster-wide
failure or any tenant-isolation breach is P0 regardless of the percentage**,
because the regulatory exposure (PCI for payments; SOC 2 for isolation) is
non-negotiable.

## Response-time SLA

| Sev | Acknowledge | Mitigate (customer-visible impact ends) | Postmortem published | All-clear declared by |
|-----|-------------|----------------------------------------|---------------------|----------------------|
| P0  | 5 min       | 30 min                                 | 5 business days      | Incident Commander |
| P1  | 15 min      | 4 hours                                | 5 business days      | On-call primary |
| P2  | 1 business day | next business day                   | n/a                  | On-call primary |
| P3  | next sprint planning | next sprint                   | n/a                  | Team owner |

The clock starts when PagerDuty pages. **Acknowledge** is the PD ack button —
not a Slack message; not a "saw it on my phone"; the literal API ack that
stops the escalation timer. **Mitigate** is when the customer-visible
impact is over; the root-cause fix can wait. **Postmortem published** means
posted in `#bookstore-platform-postmortems`, linked in the GitHub Wiki, and
action-items filed.

## What "page" means

| Page channel               | Severity routed | Quiet hours? | Escalation                            |
|----------------------------|-----------------|--------------|---------------------------------------|
| PagerDuty high-urgency     | P0              | never        | primary -> secondary at 5 min -> platform lead at 15 min -> CTO at 30 min |
| PagerDuty page             | P1              | never        | primary -> secondary at 15 min -> platform lead at 1 hour |
| PagerDuty low-urgency      | P2              | yes (suppress 22:00-06:00 local) | primary only; no escalation |
| Slack `#bookstore-alerts`  | P3              | yes          | none |

**Quiet hours suppression** applies only to P2 (the on-call's SLA is "next
business day" anyway). P0 and P1 page at all hours; that is what on-call
means.

## Customer-communication requirements

Every P0 and P1 incident has a customer-communication artifact:

- **Status page** at `status.bookstore-platform.example.com` — public,
  Statuspage / Statusgator / Cachet / Atlassian Statuspage style. Updated
  by the Incident Commander (P0) or on-call primary (P1).
- **Email to affected tenants** — for P0 only; the IC drafts; legal +
  customer-success sign off; sent within 1 hour of the all-clear.
- **Postmortem published** — the public-facing version of the postmortem
  (sanitized of internal vendor names + dollar figures) goes on the status
  page within 7 business days of the incident.

The two customer-comm anti-patterns we explicitly forbid:

1. **The "silent fix"** — the team rolls back, customer impact ends, and no
   status-page entry is ever created. **Forbidden.** Every P0/P1 must have
   a public-facing artifact; the audit trail is non-negotiable.
2. **The "all clear too soon"** — a status-page entry that goes to "resolved"
   while customers are still seeing residual errors. The rule: status-page
   "resolved" requires a 15-minute clean-window of green metrics + customer
   verification (a tenant on Slack confirming).

## Postmortem requirements (the 5-business-day rule)

The biggest postmortem anti-pattern is the "we'll write it next week"
trap — next week never comes; the incident's details fade; the postmortem
either never appears or appears two months later with half the timeline
guessed from Slack search.

The rule: **published in `#bookstore-platform-postmortems` within 5
business days of the all-clear, no exceptions.** Concretely:

- Day 0 (incident day): the on-call drafts the timeline DURING the
  incident — every command run, every observation, with UTC timestamps.
- Day 1: draft Summary + Impact + Timeline; circulate to the IC and the
  on-call secondary.
- Day 2-3: root cause + contributing factors + action items.
- Day 4: review with the platform lead.
- Day 5: published.

If the deadline slips, the postmortem itself becomes a P3 alert
(`postmortem_overdue`) tracked by the platform lead. The 5-day rule is
strict because postmortems that miss the window almost never get
published. (We measured: at the 7-day mark, the publish rate dropped to
40 %; at the 14-day mark, 12 %. 5 days is the inflection point.)

> **48h vs. 5-day:** Part 13 ch.12 sets a 48-hour deadline — that is the
> **draft-by** target (timeline + summary written while details are fresh).
> This section's 5-business-day deadline is the **publish-by** target
> (action items filed, owners assigned, platform lead signed off).
> Both deadlines apply; they operate at different granularities of the
> same discipline.

## When a P-level changes mid-incident

Severities can escalate (P1 -> P0) or de-escalate (P0 -> P1) as new
information arrives. The rules:

- **Escalation** (P1 -> P0): any responder can escalate; the page goes to
  the P0 escalation policy; war room opens; status-page entry upgraded.
  The on-call records the escalation in the timeline with the trigger
  (e.g. "16:42 UTC — we discovered the issue affects all tenants, not just
  acme-books; escalated to P0").
- **De-escalation** (P0 -> P1): requires the IC's explicit decision +
  agreement from the on-call primary. Recorded in the timeline. The
  customer-communication artifacts STAY at P0's bar even if the technical
  severity drops (the tenants who saw a status-page P0 banner need closure
  on that banner, not silent demotion).

## Triggering events — which alert maps to which severity

The Alertmanager labels (in `incident/pagerduty-integration.yaml`) carry
the severity. The mapping from alert name to severity is reviewed
quarterly during alert-hygiene review.

| Alert                                         | Default sev | Why                                                |
|-----------------------------------------------|-------------|----------------------------------------------------|
| `BookstoreGatewayDown`                        | P0          | every customer affected; checkout path down |
| `BookstoreCheckoutErrorRateHigh`              | P0          | payments-affecting; revenue + PCI exposure |
| `BookstoreTenantIsolationBreach`              | P0          | regulatory; SOC 2 + tenant contract |
| `BookstoreRegionDown`                         | P1          | single region; multi-region active-active should absorb |
| `BookstoreSearchUnavailable`                  | P1          | feature broken cluster-wide; checkout still works |
| `BookstorePaymentsWebhookLag`                 | P1          | payments succeed; webhook delivery delayed (tenants notice) |
| `BookstoreCatalogP99Latency`                  | P1          | feature degradation; user-visible |
| `BookstoreDatabaseReplicationLag`             | P1          | precursor to data-loss; CNPG sync replication issue |
| `BookstoreTenantBudgetExceeded`               | P2          | single tenant; workaround = budget bump |
| `BookstoreNodeMemoryPressure`                 | P2          | Karpenter should self-heal; alert is the safety net |
| `BookstoreCertExpiringSoon`                   | P3          | cert-manager should auto-renew; reminder only |
| `BookstoreBackupRetentionDriftFromPolicy`     | P3          | Velero retention mismatched with policy |

The full mapping lives in
[`../runbooks/`](../runbooks/) — each runbook header carries the alert
name + severity + the rationale.

## On-call burnout protection

Pages-per-shift is itself a metric:

| Pages / shift | Status      | Action |
|---------------|-------------|--------|
| 0-2           | normal      | none |
| 3-5           | elevated    | mention at next handoff |
| 6-10          | high        | mandatory alert-hygiene review in this sprint |
| 11-20         | critical    | platform lead pauses non-essential alerts (Alertmanager silence with documented expiry); root-cause review |
| >20           | rotation broken | the rotation itself is a P1; platform team's next sprint is to fix the noise |

This metric ties to the on-call review cadence in chapter 15.11.

## Review cadence

- **Quarterly alert-hygiene review** — every alert reviewed; noisy ones
  deleted; severities adjusted; thresholds re-tuned against actual page
  volume.
- **Annual severity-matrix review** — does the matrix still match the
  business? (After a major product release, the P0/P1 boundary often
  needs revising.)

Last reviewed: 2026-05-01. Next review: 2026-08-01. Owner: platform lead.
