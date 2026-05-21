# On-call handoff — Week of YYYY-MM-DD

> The weekly Monday-10:00-UTC handoff document. The outgoing primary
> hands the page to the incoming primary using this template; the
> incoming primary cannot start their shift without reading this doc
> end-to-end. Lives in `docs/handoffs/YYYY-MM-DD.md` (created from
> this template; archived after the shift).

The handoff doc closes the most common on-call failure mode: **the
incoming on-call did not know about the open issue from last week**.
With a structured handoff, the incoming on-call starts their shift
with the full operational context, not a blank slate.

## Shift metadata

- **Week of:** YYYY-MM-DD (Monday) to YYYY-MM-DD (next Sunday).
- **Outgoing primary:** \<name\>
- **Outgoing secondary:** \<name\>
- **Incoming primary:** \<name\>
- **Incoming secondary:** \<name\>
- **Handoff completed:** YYYY-MM-DD HH:MM UTC.
- **Handoff format:** sync meeting (Monday 10:00 UTC) + this doc.

## Outgoing-week summary

### Pages received

| Sev | Count this week | Count last week | Notes                          |
|-----|----------------|-----------------|--------------------------------|
| P0  | 0              | 1               | (none this week — celebrate!)   |
| P1  | 2              | 3               | both acked within SLA          |
| P2  | 4              | 5               | one was a known-flapping alert |
| P3  | 11             | 14              | trending down — alert hygiene working |

Total pages: 17 (last week: 23). The trend is healthy if the count
is dropping; flag if rising. **Target: < 2 P0+P1 / shift.** If
exceeded, raise at the handoff meeting + flag to the platform lead.

### Active incidents (open at handoff)

For each open incident:

```text
INC-2026-05-19-001 — Catalog p99 latency drift
  Severity: P1 (downgraded from P0 on 2026-05-19)
  Status: mitigated; root cause investigation ongoing
  Owner: <eng-name>
  Slack channel: #inc-2026-05-19-001
  Postmortem due: 2026-05-26
  What the incoming on-call needs to know:
    - The mitigation (scaled catalog to 8 replicas) is still in
      effect; do NOT scale back down without coordinating with
      the owner.
    - There is a related alert (BookstoreCatalogPodMemorySpike)
      that may re-fire this week; the alert is REAL — page if it
      fires, but the runbook step is "wait for the postmortem
      action items to land."
```

(Repeat for each open incident. If no open incidents, write "None.")

### Recent postmortems

Postmortems published in the last 14 days that the incoming on-call
should know about:

| Date       | Incident ID         | Title                                              | Owner       | Status |
|------------|---------------------|----------------------------------------------------|-------------|--------|
| 2026-05-12 | INC-2026-05-10-002  | Search index rebuild stalled                       | Eve         | published; AI A1-A3 open |
| 2026-05-08 | INC-2026-05-05-001  | Kafka consumer-group rebalance loop                | Bob         | published; AIs all open |

For each: the incoming on-call should at least skim the postmortem +
note the action items that might affect this week's operations.

### Ongoing investigations (no incident, but worth watching)

Things that aren't yet pageable but are on the team's radar:

- \<observation 1: e.g. "memory usage on payments-gateway has been
  trending up by ~2 %/week for 3 weeks; we don't know why yet; the
  alert threshold is far away but worth watching"\>
- \<observation 2\>

### Planned changes this coming week

| Date        | What                                          | Owner       | Risk      | Rollback plan |
|-------------|-----------------------------------------------|-------------|-----------|---------------|
| 2026-05-21  | Deploy catalog v2.14 (multi-tenant query fix) | Bob         | low       | Argo Rollouts canary; auto-rollback on SLO |
| 2026-05-22  | Karpenter NodePool memory bump (8GB -> 16GB)  | Carol       | medium    | Terraform revert |
| 2026-05-23  | Stripe API key rotation (production)          | Dave        | high      | Vault prior-version restore; runbook X |
| 2026-05-24  | Monthly DR drill (us-east -> eu-west)         | Eve         | low       | drill is a drill; no production impact |

For each: the incoming on-call should know the timing + who to ping if
something goes wrong + the rollback approach.

## Open alerts (steady state)

These alerts are firing now and are NOT pageable (they are P3 or
silenced); the incoming on-call should be aware so they don't get
confused by them showing in Grafana.

| Alert                                       | First seen  | Severity | Status                                |
|---------------------------------------------|-------------|----------|---------------------------------------|
| BookstoreCertExpiringSoon (lego-acme)       | 2026-05-15  | P3       | cert-manager will auto-renew on 2026-05-25 |
| BookstoreBackupRetentionDriftFromPolicy     | 2026-05-10  | P3       | Velero policy update PR open: #5832    |

## Known flapping alerts

Alerts that have a habit of flapping this week. The incoming on-call
should NOT panic if these fire briefly:

- `BookstoreNodeMemoryPressure` on the karpenter-payments-arm pool —
  flaps during the marketing-email send (15:00 UTC daily); known
  pattern; action item to tune the threshold (PLAT-1342) is in progress.

## Runbooks updated this week

| Runbook                                              | Change                                  | Owner |
|------------------------------------------------------|-----------------------------------------|-------|
| `runbook-payments-failure-rate.md`                   | Step 2.4 clarified (the Stripe 502 case) | Bob   |
| `runbook-api-latency-p99.md`                         | Added step for CNPG primary failover    | Carol |

The incoming on-call should re-read these (the diffs are small) before
the shift starts.

## Tools / dashboards that changed

- New Grafana dashboard: `bookstore-platform-oom-events` (rolled out
  Monday from action item INC-2026-04-15-001 A3); useful for triaging
  pod OOMKills.
- PagerDuty service `bookstore-payments-p0` renamed to
  `bookstore-checkout-p0` (Alertmanager config updated; no behavioural
  change).

## Notes from the outgoing on-call

Free-text section. Anything the outgoing primary wants the incoming
primary to know that doesn't fit into a structured section above.
Examples:

- "Bob is on PTO Wed-Thu; if you need a payments expert, ping Eve."
- "The `team-payments` Slack channel has been busy with the Q2 OKR
  planning — pages will be answered, but ambient activity is high."
- "If `BookstoreCheckoutErrorRateHigh` fires this week, suspect the
  Stripe API key rotation first — it's the highest-risk change."

## Acknowledgment

The incoming primary acknowledges they have read and understood the
above by:

- [ ] Read the open incidents section.
- [ ] Skimmed the recent postmortems linked.
- [ ] Reviewed the planned-changes table.
- [ ] Re-read the runbooks listed under "Runbooks updated this week."
- [ ] Verified they can ack a test page from PagerDuty (use the test
      service `bookstore-test-pager`; ack within 60 sec).
- [ ] (Optional) Walked the catalog dashboard panel-by-panel with the
      outgoing primary in the handoff sync.

**Incoming primary signature:** \<name\> at YYYY-MM-DD HH:MM UTC.

## The handoff meeting agenda (Monday 10:00 UTC, 30 min)

1. **Open incidents** (5 min) — outgoing walks the incoming through.
2. **Recent postmortems** (5 min) — outgoing flags the top 1-2.
3. **Planned changes** (5 min) — outgoing names the high-risk ones.
4. **Open alerts + flapping alerts** (5 min) — outgoing names known.
5. **Q&A** (5 min) — incoming asks.
6. **Test page** (5 min) — incoming acks a test page from PagerDuty;
   confirms the rotation switch in PagerDuty's UI.

If the meeting runs short, that's a good sign — it means the doc
above is sufficient. If it runs long, ask "what's missing from the
doc?" and update the template.

## Why this exists (the handoff anti-pattern)

The most common on-call failure: **the incoming on-call gets a page
in their first hour, opens the runbook, and discovers the issue is
a known-ongoing investigation from last week that they had no idea
about**. The outgoing on-call had it under control; the incoming
on-call thinks it's a new incident; the diagnosis restarts from
scratch; the customer impact is 2x what it would have been with a
proper handoff.

The defence is THIS doc + the Monday sync. Without both, the on-call
rotation has 52 weekly fresh starts instead of one continuous
operational discipline.

See chapter 15.10 — Incident response & on-call — for the broader
operational rhythm this fits into.
