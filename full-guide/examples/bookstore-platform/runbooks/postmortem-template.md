# Postmortem — \<INCIDENT-TITLE\>

> Blameless. Action-item-driven. Published widely. **The goal is that
> the same mistake does not happen twice.**

## Metadata

- **Incident ID:** INC-YYYY-MM-DD-NNN
- **Date / Time (UTC):** YYYY-MM-DD HH:MM
- **Duration:** \<HH:MM start - HH:MM end\>
- **Severity:** P0 | P1 | P2
- **Affected tenants:** \<list\>
- **Affected regions:** \<list\>
- **On-call primary:** \<name\>
- **On-call secondary:** \<name\>
- **Incident commander:** \<name\>
- **Recorder:** \<name\>

## Summary (1 paragraph)

A 2-4 sentence executive summary. What happened, who was affected,
what the root cause was, and what we did. Read it in 30 seconds. The
detail lives below.

## Impact

- **Customer impact:** \<concrete; e.g. "1,234 orders failed; ~$45K
  revenue affected"\>.
- **Tenant impact:** \<which tenants; whether bilaterally
  communicated\>.
- **Internal impact:** \<which teams paged; how many engineer-hours\>.
- **Data integrity:** \<lost? corrupted? OK?\>.
- **SLO impact:** \<error budget consumed: how much\>.
- **Status page:** \<link to the status-page entry\>.

## Timeline (UTC)

| Time   | Event                                                |
|--------|------------------------------------------------------|
| HH:MM  | \<thing observed; specific\>                         |
| HH:MM  | \<thing done; specific\>                             |
| HH:MM  | \<page sent; receiver\>                              |
| HH:MM  | \<runbook opened; which one\>                        |
| HH:MM  | \<mitigation tried; outcome\>                        |
| HH:MM  | \<root cause identified\>                            |
| HH:MM  | \<customer-visible impact ended\>                    |
| HH:MM  | \<all-clear declared\>                               |

## Root cause

A clear, technical, blameless explanation of what went wrong. Aim
for the **system-level** cause, not the human-error story.

- **Trigger:** \<what made it happen now\>.
- **Latent condition:** \<the bug / gap that was already there\>.
- **Contributing factor 1:** \<e.g. an alert that did not fire\>.
- **Contributing factor 2:** \<e.g. a runbook step that was wrong\>.
- **Why didn't we catch this earlier?** \<the monitoring gap; the
  testing gap; the chaos game-day gap\>.

## What went right

- Specific things to celebrate. The runbook that worked; the alert
  that fired; the chaos game-day rehearsal that prepared us; the
  team member who diagnosed in 5 min.

## What went wrong

- Specific gaps. NOT people; systems. "The runbook did not cover X."
  "The alert fired but routed wrong." "The dashboard panel was
  broken."

## Action items

Each item: a clear deliverable + an owner + a ticket + a due date.

| ID  | Description                                  | Owner     | Ticket           | Due        | Status      |
|-----|----------------------------------------------|-----------|------------------|------------|-------------|
| A1  | Add an alert for the missing monitoring gap   | \<name\>  | \<ticket-id\>    | YYYY-MM-DD | open        |
| A2  | Update runbook X step 3 to clarify command   | \<name\>  | \<ticket-id\>    | YYYY-MM-DD | open        |
| A3  | Add Chaos Mesh experiment for the scenario   | \<name\>  | \<ticket-id\>    | YYYY-MM-DD | open        |
| A4  | Communicate the contract change to tenants  | \<name\>  | \<ticket-id\>    | YYYY-MM-DD | open        |

**Target:** > 80 % action-item closure rate by the next quarterly
review.

## Lessons

A short list of takeaways. NOT prescriptive ("we must do X"); more
"we learned Y". Examples:

- The PDB held; the resilience pattern worked.
- The runbook's diagnose tree is missing the case where Stripe
  returns 502 instead of 500.
- We do not have a chaos experiment for the saga-compensation
  flow; we should add one.

## Related artefacts

- **Runbooks used:** \<links\>.
- **Dashboards consulted:** \<links\>.
- **Alerts that fired:** \<list\>.
- **Slack thread:** \<link\>.
- **PagerDuty incident:** \<link\>.
- **Chaos experiments related:** \<list\>.

## Publication

- [ ] Posted in `#bookstore-platform-status`.
- [ ] Linked in the platform's GitHub Wiki / `docs/postmortems/`.
- [ ] Discussed in the next platform all-hands.
- [ ] Action items added to the GitHub project board.

## Sign-off

| Role | Name | Date |
|------|------|------|
| Incident Commander | \<name\> | YYYY-MM-DD |
| Platform Lead      | \<name\> | YYYY-MM-DD |
| (Optional) CTO     | \<name\> | YYYY-MM-DD |

---

**A note on blamelessness.** This document names systems, not
people. Every action a human took was the rational choice given
the information they had at the time. If a human action contributed
to the incident, the question is "what system let that choice be
the most rational one?", not "who do we blame?". The action items
are about the system; never about a person.
