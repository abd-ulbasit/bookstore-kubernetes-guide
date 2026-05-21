# `incident/` — Incident response artefacts

> The files in this directory operationalize the incident-response
> lifecycle: **detect → triage → resolve → learn**. Each file maps to
> one phase + the human role that owns it. The chapters
> [15.10](../../../15-day-to-day-production-ops/10-incident-response-and-on-call.md)
> and [15.11](../../../15-day-to-day-production-ops/11-day-to-day-production-ops.md)
> are the walkthroughs; the files here are the artefacts you run.

## The four phases

The lifecycle has four phases. Confusing them is the most common
incident-response failure mode in our experience.

| Phase     | Goal                                | Owner                  | Time scale     | Artefact in this dir            |
|-----------|-------------------------------------|------------------------|----------------|---------------------------------|
| Detect    | Discover the issue exists           | Alertmanager + PD      | seconds        | `pagerduty-integration.yaml`    |
| Triage    | Decide severity + claim IC          | On-call primary + IC   | first 5 min    | `severity-matrix.md`            |
| Resolve   | Stop the customer-visible impact    | On-call + responders   | 5 min - 4 hrs  | `incident-channel-bot-config.md`|
| Learn     | Prevent the same incident recurring | IC + author + team     | days to weeks  | `postmortem-template.md` + `sample-postmortem-2026-04-15.md` |

**Detect** is automated; humans don't show up here unless the page
fires. **Triage** is where the on-call enters the loop. **Resolve** is
where the team enters the loop. **Learn** is where the organization
enters the loop.

The most common mistake: jumping from Detect straight to Resolve,
skipping Triage. The page fires; the on-call starts debugging; nobody
declares the severity, nobody opens a status-page entry, nobody
claims the IC role. By the time anyone realizes "this is a P0,"
20 minutes have passed and the customer-comm SLA is breached.
**Triage is 5 minutes; do not skip it.**

## The files

```
incident/
├── README.md                            # this file
├── severity-matrix.md                   # P0/P1/P2/P3 + response SLAs
├── pagerduty-integration.yaml           # Alertmanager + AlertmanagerConfig
├── incident-channel-bot-config.md       # PD -> Slack -> Zoom -> Statuspage
├── oncall-handoff-template.md           # weekly Monday handoff doc
├── postmortem-template.md               # blameless postmortem (with 5 Whys)
└── sample-postmortem-2026-04-15.md      # fully worked example
```

### `severity-matrix.md` (Triage)

The P0/P1/P2/P3 ladder. Defines the response-time SLA, customer-comm
requirements, and postmortem rules for each severity. The on-call's
first 5-minute question is "what severity is this?" — this doc has
the answer.

### `pagerduty-integration.yaml` (Detect)

The Alertmanager `AlertmanagerConfig` that routes alerts from
Prometheus to PagerDuty. Splits P0/P1/P2/P3 onto separate PagerDuty
services with different escalation policies. Includes:
- Route tree (severity-based)
- Inhibition rules (suppress lower-sev when higher-sev fires)
- Receiver configuration per severity
- A sample `PrometheusRule` showing the required labels +
  annotations every alert must have

### `incident-channel-bot-config.md` (Resolve)

How to wire PagerDuty -> Slack channel auto-creation -> Zoom bridge ->
status-page update. Discusses the three off-the-shelf platforms
(Incident.io, FireHydrant, Rootly) without prescribing one + the
minimum-viable wire-up if you can't yet adopt a paid tool. The IC-claim
flow is the most-overlooked piece; it gets its own section.

### `oncall-handoff-template.md` (Resolve, continuity)

The Monday 10:00 UTC handoff doc. Closes the "the incoming on-call
didn't know about the open issue from last week" anti-pattern.
Structured sections: open incidents, recent postmortems, planned
changes, known flapping alerts.

### `postmortem-template.md` (Learn)

The blameless postmortem template. Sections: metadata, summary,
customer impact, timeline, root cause (5 Whys), contributing factors,
what went right, what went wrong, action items, lessons, related
artefacts, customer communication, publication checklist, sign-off.
The 5 Whys is explicit; the action-item table requires owner +
ticket + due date + priority for every item.

### `sample-postmortem-2026-04-15.md` (Learn, by example)

A fully worked sample postmortem: 39-min P0 checkout outage during
the Spring Sale flash promotion. Shows the discipline the template
asks for — dense timeline, 5 Whys all the way to a system-level
cause, 8 action items with all 4 fields populated, what-went-right
as long as what-went-wrong. Teaching material; read it once before
writing your first real postmortem.

## How this fits with the rest of the platform

- **Detect:** alerts fire from PrometheusRules (lives in
  `examples/bookstore-platform/observability/`); routed by
  Alertmanager (config in `pagerduty-integration.yaml` here).
- **Triage:** the runbook for every alert lives in
  [`../runbooks/`](../runbooks/). The on-call opens the runbook from
  the PagerDuty `runbook_url` annotation.
- **Resolve:** the incident channel auto-created via the wire-up in
  `incident-channel-bot-config.md`. The on-call walks the runbook's
  5-section structure (Alert / Check / Diagnose / Mitigate /
  Postmortem).
- **Learn:** the postmortem written from the timeline; action items
  tracked. The platform lead reviews closure rate monthly (chapter
  15.11).
- **Handoff:** the Monday handoff doc (template here) closes the
  weekly continuity gap.

## What this does NOT cover

This directory covers the **incident** side of operations. It does NOT
cover:

- **Day-to-day operational reviews** — cost, capacity, scaling, on-call
  metrics — covered in chapter 15.11.
- **Proactive practices** — chaos game-days, DR drills — covered in
  [`../runbooks/`](../runbooks/) and chapter 13.12.
- **Change management** — PR-to-prod lifecycle — covered in chapters
  15.01-15.09.

The four phases in this directory are the **reactive** side of
production operations; the proactive side is "do the work to make
incidents rarer in the first place."

## Maturity ladder

The four phases mature at different rates. A typical team progresses:

1. **First 30 days:** Detect works (alerts route to PD); Triage is
   informal (Slack DM); Resolve is heroic (whoever's online);
   Learn is "we'll talk about it in the next standup."
2. **First 90 days:** Detect well-tuned (alert hygiene review
   ongoing); Triage has the severity matrix; Resolve has a runbook
   per alert; Learn ships the first 3-5 postmortems.
3. **First 12 months:** Detect runs in the green (page rate steady
   below 2/shift); Triage automated (incident channel auto-creates;
   IC claim prompt); Resolve has 80 % action-item closure; Learn is
   a habit (postmortems published within 5 days at >90 % rate).
4. **2+ years:** Detect has shadow-traffic + chaos coverage; Triage
   needs almost no human decisions (severity auto-assigned from the
   alert + service tier); Resolve is mostly auto-remediation for the
   common cases; Learn drives the platform roadmap (action items
   become the next quarter's features).

The bookstore platform v2 ships level 2 and points at level 3.
Level 4 is where Netflix/Google live; we name it honestly as the
graduation goal.
