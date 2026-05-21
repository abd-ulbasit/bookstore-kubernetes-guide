# On-Call Rotation — Bookstore Platform v2

The on-call policy. Rotations + escalation + severity definitions +
the response-time SLA. This file is the contract between the platform
team and the team-on-call; changes require a PR + sign-off from the
platform lead.

## Rotation pattern

- **Primary + secondary**, 1-week shifts, Monday 10:00 UTC handoff.
- **5-engineer rotation** — on-call frequency = once every 5 weeks.
  Below 4 engineers = burnout risk; above 10 engineers = skills decay.
- **Time-off-during-shift** policy: notify the secondary, push the
  handoff if needed, no Slack expectations off-shift.

## Severity definitions

| Sev | Customer impact                                            | Page? | Customer comm    | Postmortem  | Examples |
|-----|------------------------------------------------------------|-------|------------------|-------------|----------|
| P0  | >=50 % of customers OR data loss OR safety/regulatory      | yes   | 15 min           | mandatory   | full outage; tenant isolation breach |
| P1  | single region OR feature broken for all tenants OR isolation issue | yes | 1 hour | within 48 h | us-east down; search broken; replication lag |
| P2  | single tenant OR workaround exists OR cosmetic             | slack | on-request only  | not required | tenant X over-budget; UI glitch |

## Response-time SLA

| Sev | Acknowledge | Mitigate | Postmortem |
|-----|-------------|----------|------------|
| P0  | 5 min       | 30 min   | 48 h       |
| P1  | 15 min      | 4 h      | 48 h       |
| P2  | 1 business day | when convenient | n/a |

The clock starts when PagerDuty pages; "acknowledge" is the PD ack
button. "Mitigate" = the customer-visible impact is over; the
root-cause fix can wait for the postmortem.

## Escalation

1. **Primary** pages.
2. If primary does not ack in 15 min → **Secondary** pages.
3. If secondary does not ack in 15 min → **Platform Lead** pages.
4. If platform lead does not ack in 15 min → **CTO** pages.

`PagerDuty schedule ID: PXXXXX-bookstore-platform-primary`
`PagerDuty escalation policy: PYYYYY-bookstore-platform-escalation`

## Handoff meeting

Every Monday at 10:00 UTC. Outgoing primary briefs incoming primary on:

- Open incidents (any unclosed in PagerDuty).
- Recent postmortems + action items.
- Known issues that may page during the shift.
- Scheduled changes during the week (deploys, DR drills, chaos
  game-days).

Handoff doc template:
`handoff-template.md` — not shipped here;
generated each week by the platform team.

## Off-shift expectations

- **No Slack response expected.** The on-call's Slack is paged via
  PagerDuty integration; the rest is opt-in.
- **No `@team-platform` pings off-shift.** The escalation policy
  exists; use it.
- **Holidays + PTO covered.** The platform lead arranges coverage;
  the engineer on PTO is removed from the rotation for the week.

## Postmortem culture

Blameless. The template is in
[postmortem-template.md](postmortem-template.md). The discipline:

- Required within 48 h for any P0 or P1.
- Action items have an owner + a ticket + a due date.
- Published widely (Slack + the platform's GitHub Wiki + the
  quarterly all-hands review).
- > 80 % action-item-completion rate is the team metric.

## Page-volume alerting

If the on-call rotation receives > 10 pages per shift, the rotation
itself becomes a P2 alert (the alerting is broken; the platform
team's next sprint is to fix it). Mitigations:

1. **Quarterly alert hygiene review.** Every alert reviewed; noisy
   ones deleted; burn-rate thresholds re-tuned.
2. **Load shedding.** If volume > 20 pages / shift, the platform
   lead pauses non-essential alerts via Alertmanager silence (with
   a documented expiry).

## Rotation roster

The active rotation is in PagerDuty
([schedule URL](https://your-org.pagerduty.com/schedules/PXXXXX)).
Mirrored here as static documentation for the audit trail; PagerDuty
is the source of truth.

| Week of  | Primary       | Secondary     |
|----------|---------------|---------------|
| 2026-05-19 | alice@team-payments | bob@team-catalog |
| 2026-05-26 | carol@team-search   | dave@team-platform |
| 2026-06-02 | eve@team-catalog    | alice@team-payments |
| 2026-06-09 | bob@team-catalog    | carol@team-search |
| 2026-06-16 | dave@team-platform  | eve@team-catalog |

## Follow-the-sun (future)

The current pattern works at < 50 engineers in one to two time zones.
Above that, the platform graduates to follow-the-sun:

- us-east team: 14:00-22:00 UTC.
- eu-west team: 06:00-14:00 UTC.
- ap-southeast team: 22:00-06:00 UTC.

Each region maintains its own primary + secondary rotation; pages
route by time of day. This requires three independently-funded
regional teams; not v2's scope.

## Owners

- **Platform Lead:** owns this document.
- **PagerDuty admin:** owns the schedule + escalation policy.
- **The rotation:** owns the pages.

Last reviewed: 2026-05-01. Next review: 2026-08-01.
