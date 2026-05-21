# Postmortem — \<INCIDENT-TITLE\>

> Blameless. Action-item-driven. Published widely. **The goal is that
> the same mistake does not happen twice.** This template is the fuller
> version of [`../runbooks/postmortem-template.md`](../runbooks/postmortem-template.md)
> with explicit **5 Whys** + structured action-item tracking, used for
> any P0/P1 incident per the severity matrix.

## Metadata

- **Incident ID:** INC-YYYY-MM-DD-NNN
- **Title:** \<one line; the headline a non-engineer can read\>
- **Date / Time (UTC):**
  - First alert: YYYY-MM-DD HH:MM
  - All-clear: YYYY-MM-DD HH:MM
  - Duration of customer-visible impact: \<HH:MM\>
- **Severity:** P0 | P1
- **Affected tenants:** \<list or "all"\>
- **Affected regions:** \<list\>
- **Affected services:** \<list\>
- **Detection method:** automated alert | customer report | internal observation | DR drill discovery
- **Incident Commander (IC):** \<name\> @ \<team\>
- **On-call primary at time of incident:** \<name\>
- **On-call secondary at time of incident:** \<name\>
- **Recorder (timeline scribe):** \<name\>
- **Author of this postmortem:** \<name\>

## Summary (1 paragraph)

A 2-4 sentence executive summary. **What happened, who was affected,
what the root cause was, how we mitigated it.** Read it in 30 seconds.
The detail lives below. A non-engineer should be able to follow this
paragraph.

Example shape:

> Between HH:MM and HH:MM UTC on YYYY-MM-DD, \<feature\> was \<degraded /
> unavailable\> for \<affected scope\>. Root cause was \<technical cause
> in plain language\>. Customer impact: \<concrete numbers\>. We
> mitigated by \<action\> and prevented recurrence by \<action item\>.

## Customer impact

- **Number of customers affected:** \<exact count if known; estimate otherwise\>.
- **Tenants affected (named):** \<list; mark which got proactive comm\>.
- **Revenue impact:** \<estimated $ — orders lost, refunds issued, SLA credits owed\>.
- **Data impact:** \<none | corrupted | lost — be specific; the postmortem reader needs to know if data is OK\>.
- **SLO impact:** \<error budget consumed: how much of the monthly budget\>.
- **Status-page entry:** \<URL\>.
- **Customer-comm artifacts:** \<email IDs, status page updates, support tickets\>.

## Timeline (UTC)

The IC or recorder maintains this DURING the incident. Every entry has a
UTC timestamp. Cite specifics: command output, Slack message links,
PagerDuty incident ID. **A postmortem written from a sparse timeline is
guesswork; a postmortem written from a dense timeline writes itself.**

| Time   | Event                                                          | Source / link |
|--------|----------------------------------------------------------------|---------------|
| HH:MM  | \<first observation; what fired; who saw it first\>            | \<link\>       |
| HH:MM  | \<PagerDuty page sent; receiver\>                              | \<PD incident ID\> |
| HH:MM  | \<primary acked\>                                              | \<PD\>         |
| HH:MM  | \<runbook opened; which one\>                                  | \<runbook link\> |
| HH:MM  | \<Step 1 (Check) — what was observed; PASS/FAIL\>              |               |
| HH:MM  | \<Step 2 (Diagnose) — branching decision; chosen path\>        |               |
| HH:MM  | \<incident escalated (if applicable); to whom; why\>           |               |
| HH:MM  | \<IC announced; war room opened (URL)\>                        |               |
| HH:MM  | \<first status-page update posted\>                            | \<status-page link\> |
| HH:MM  | \<Step 3 (Mitigate) — what was tried; outcome\>                |               |
| HH:MM  | \<additional mitigation tried; outcome\>                       |               |
| HH:MM  | \<root cause identified (working hypothesis)\>                 |               |
| HH:MM  | \<customer-visible impact ended (metrics returned to green)\>  | \<dashboard\>  |
| HH:MM  | \<status-page update: monitoring\>                             |               |
| HH:MM  | \<status-page update: resolved (after 15-min clean window)\>   |               |
| HH:MM  | \<all-clear declared by IC\>                                   |               |
| HH:MM  | \<incident channel closed; recorder finalized timeline\>       |               |

## Root cause (5 Whys)

The technical chain of events that allowed the incident. We use **5 Whys**
because the surface explanation almost never names the system-level cause.
Each "why" drives one level deeper. Stop when the answer is "we made a
deliberate trade-off" or "the system was designed this way" — that is the
true root.

> **Example application of 5 Whys:**
>
> **Problem:** Checkout returned 5xx for 28 minutes.
>
> **Why 1 — Why did checkout return 5xx?**
> The payments-gateway pod was OOMKilled by the kernel.
>
> **Why 2 — Why was it OOMKilled?**
> Memory usage spiked when a customer submitted a 50 MB cart payload that
> exceeded the gateway's in-memory parser buffer.
>
> **Why 3 — Why was there no size limit?**
> The gateway's request-size limit was set to 64 MB (default) instead of
> a tighter 1 MB; the 1 MB limit existed in the storefront but was not
> propagated to the gateway.
>
> **Why 4 — Why was the limit not propagated?**
> The two services use independent configurations; the limits drifted
> when the gateway was rewritten in Q1 and the storefront's limit was
> never copied over.
>
> **Why 5 — Why didn't we catch the drift?**
> We have no configuration-consistency check across services with the
> same logical contract. Code reviews focus on per-service changes;
> cross-service invariants are invisible.
>
> **Root cause:** No mechanism to enforce cross-service configuration
> invariants. The OOMKill is a symptom; the missing invariant check is
> the system-level cause.

Use this structure. Stop at the deepest "why" that admits an action item.

- **Why 1 — \<surface question\>**
  \<answer\>

- **Why 2 — \<deeper question\>**
  \<answer\>

- **Why 3 — ...**

- **Why 4 — ...**

- **Why 5 — ...**

- **Root cause statement:**
  \<one or two sentences naming the system-level cause\>

### Contributing factors

The 5-Whys identifies the primary cause. Contributing factors are the
secondary system gaps that allowed the primary cause to become an
incident.

- **Contributing factor 1:** \<e.g. monitoring gap — the alert that
  should have fired earlier didn't, because…\>.
- **Contributing factor 2:** \<e.g. runbook gap — the runbook for this
  alert was last updated 18 months ago and the dashboard panel had
  moved\>.
- **Contributing factor 3:** \<e.g. communication gap — the IC was not
  named for the first 12 minutes\>.

### Why we did not catch this earlier

This is the most important section. **Every incident is a monitoring
failure.** If the alert had fired sooner, the incident would have been
shorter or smaller. Name the monitoring gap:

- **The alert that should have caught this:** \<alert name, why it
  didn't fire — wrong query, wrong threshold, wrong service, no alert
  exists\>.
- **The dashboard panel that would have shown this:** \<which panel,
  why it wasn't checked — not in the runbook, not on the on-call's
  standard dashboard set\>.
- **The chaos experiment that would have surfaced this:** \<which
  experiment, why we don't run it — not in the workflow, scope too
  narrow\>.

## What went right

Specific things to celebrate. Public acknowledgment of what worked is as
important as naming what didn't — it reinforces the resilience patterns
the team should keep investing in.

- \<the runbook step that resolved the page in 2 minutes\>.
- \<the alert that fired correctly within 30 seconds of the threshold breach\>.
- \<the chaos game-day rehearsal three weeks ago that meant the team knew exactly which command to run\>.
- \<the PDB / replicaCount / circuit breaker that contained the blast radius\>.

## What went wrong

Specific gaps. **Systems, not people.** Every human action a responder
took was the rational choice given the information available at the
time. The question is: "what system let that choice be the most
rational one?"

- \<the runbook did not cover the case where X\>.
- \<the alert fired but routed to the wrong PagerDuty service\>.
- \<the dashboard panel was broken — broken for 6 weeks, nobody noticed\>.
- \<the IC was not named for 12 minutes; the on-call primary tried to debug AND communicate AND coordinate, doing all three poorly\>.

## Action items

Each item: a clear deliverable + an explicit owner + a tracking ticket +
a due date. **No item without all four.** Items missing any field are
the postmortem reviewer's job to fix before the doc is published.

| ID  | Description                                            | Owner          | Ticket           | Due        | Priority | Status |
|-----|--------------------------------------------------------|----------------|------------------|------------|----------|--------|
| A1  | \<add the alert that should have caught this\>         | \<eng-name\>   | \<JIRA-PROJ-NNN\>| YYYY-MM-DD | P1       | open   |
| A2  | \<update runbook X step 3 to clarify command\>         | \<eng-name\>   | \<ticket\>       | YYYY-MM-DD | P2       | open   |
| A3  | \<add chaos experiment for this failure mode\>         | \<eng-name\>   | \<ticket\>       | YYYY-MM-DD | P3       | open   |
| A4  | \<write a defender for the cross-service invariant\>   | \<eng-name\>   | \<ticket\>       | YYYY-MM-DD | P1       | open   |
| A5  | \<add status-page automation to reduce IC overhead\>   | \<eng-name\>   | \<ticket\>       | YYYY-MM-DD | P2       | open   |

**Priority guide:**
- **P1 action item:** prevents recurrence; ship this sprint.
- **P2 action item:** reduces the impact of recurrence; ship next sprint.
- **P3 action item:** monitoring / runbook / documentation improvement;
  ship this quarter.

**Target:** > 80 % action-item closure rate by the postmortem's quarterly
review (see ch.15.11 — postmortem review). The platform lead tracks the
closure rate as a team metric.

## Lessons

A short list of takeaways. NOT prescriptive ("we must do X") — those are
in the action items. The lessons section is for the **insights** that
emerged from the incident.

- \<the PDB held; the resilience pattern worked as designed\>.
- \<the runbook's diagnose tree is missing the case where Stripe returns 502 instead of 500\>.
- \<we do not have a chaos experiment for the saga-compensation flow under partial-failure\>.
- \<the IC role wasn't claimed for 12 minutes; we need an automated "you are the IC" Slack ping when a P0 fires\>.

## Related artefacts

- **Runbooks consulted:** \<links to the runbook files used during triage\>.
- **Dashboards consulted:** \<links to Grafana dashboards\>.
- **Alerts that fired:** \<list of alert names + their PrometheusRule paths\>.
- **PagerDuty incident:** \<PD URL\>.
- **Incident Slack channel:** \<#inc-YYYY-MM-DD-NNN URL\>.
- **War-room Zoom recording:** \<URL if recorded\>.
- **Commits / PRs related:** \<the change that triggered the incident; the fix; the action-item PRs\>.
- **Chaos experiments related:** \<if this incident inspired or relates to a chaos experiment\>.

## Customer communication

- **Status-page entries:**
  - \<URL of initial entry\>
  - \<URL of update 1\>
  - \<URL of resolution\>
- **Email to affected tenants:** \<draft + final + recipients + send time\>.
- **Support tickets opened by customers:** \<count + IDs\>.
- **Public-facing postmortem published?** Y / N — link if yes.

## Publication checklist

- [ ] Posted in `#bookstore-platform-postmortems` Slack channel.
- [ ] Linked in the platform's GitHub Wiki / `docs/postmortems/`.
- [ ] Filed in the platform's GitHub Project board (postmortem-tracking).
- [ ] Action items have owners + due dates + tracking tickets.
- [ ] Scheduled for discussion at the next platform all-hands.
- [ ] Public-facing version (sanitized) posted to status page if P0.
- [ ] Customer-success notified if any tenant requires direct comm.

## Sign-off

| Role               | Name        | Date       |
|--------------------|-------------|------------|
| Incident Commander | \<name\>    | YYYY-MM-DD |
| Platform Lead      | \<name\>    | YYYY-MM-DD |
| Eng Director       | \<name\>    | YYYY-MM-DD |
| (P0 only) CTO      | \<name\>    | YYYY-MM-DD |

---

## A note on blamelessness

This document names systems, not people. Every action a human took was
the rational choice given the information they had at the time. If a
human action contributed to the incident, the question is "what system
let that choice be the most rational one?" — never "who do we blame?".

The action items are about the system. **Never about a person.** A
postmortem that recommends "Alice should be more careful" is a broken
postmortem; the corresponding fix is "Alice should have a tool / check /
review that makes carelessness impossible."

## A note on the 5 Whys

The 5 Whys is a tool, not a rule. Sometimes you stop at 3 Whys because
the root is clear. Sometimes you go to 7 Whys because the chain is deep.
The discipline is: **keep asking until the answer is a system-level
truth, not a surface symptom**. The number "5" comes from Toyota's
original method; the spirit is "deep enough to act on, not so deep that
the action item is too abstract to ship."
