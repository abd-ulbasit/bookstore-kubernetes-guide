# Incident-channel automation — wiring PagerDuty → Slack → Zoom → Status page

> Every P0/P1 page should produce: a dedicated Slack channel, a Zoom
> bridge, a status-page entry, and an Incident Commander prompt — all
> within 90 seconds of the page, with zero on-call typing. This file
> describes how those pieces wire together using off-the-shelf incident-
> management platforms (Incident.io, FireHydrant, Rootly), without
> prescribing one.

The discipline behind this automation is the discipline of **mechanical
execution at 3am** from Part 13 ch.12: take every step that an exhausted
on-call would otherwise have to remember, and move it into automation
that runs before the on-call even types the first command.

## What the automation does

The trigger is a PagerDuty incident creation event (P0 or P1).
Downstream of that single trigger, the automation:

1. **Creates a dedicated Slack channel** — `#inc-YYYY-MM-DD-NNN`. The
   channel name encodes the date + sequence number so postmortem
   linking + audit trail is one-glance.
2. **Pages the on-call + auto-invites the right team** — pulls the
   service owner from Backstage; invites the team's `@oncall` group +
   the platform lead.
3. **Opens a Zoom bridge** — auto-generates a Zoom meeting URL; posts
   to the channel. Optional Slack huddle as a low-friction alternative.
4. **Creates a status-page entry** — posts an "Investigating" entry on
   the public status page; the IC can update with one Slack command.
5. **Prompts for IC role claim** — posts a "Who is the IC?" message
   that any responder can claim with a reaction or button.
6. **Posts the runbook + dashboard URLs** — pulled from the
   PagerDuty incident details (the `runbook_url` + `dashboard_url`
   annotations from `pagerduty-integration.yaml`).
7. **Starts the timeline** — every message in the channel gets a UTC
   timestamp; the postmortem timeline can be auto-extracted from the
   channel history.
8. **Tracks the postmortem deadline** — schedules a reminder for
   YYYY-MM-DD + 5 business days; pages the on-call primary if the
   postmortem is overdue.

## The three off-the-shelf options

The bookstore platform spec does not prescribe one — the operational
discipline matters more than the tool. The shortlist:

### Incident.io

- **Strengths:** Slack-native; very fast time-to-value; "post a status
  page update" works via Slack slash commands; IC role-tracking is
  built in; auto-generates a Confluence/Notion postmortem stub.
- **Trade-offs:** Slack-only (no Teams support yet — was on the roadmap
  as of 2026); pricing per-responder-per-month.
- **Wire-up:** PagerDuty -> Incident.io via Incident.io's "PagerDuty
  integration" (built-in); Incident.io -> Slack via OAuth; Incident.io
  -> Statuspage via API key; Incident.io -> Zoom via OAuth.

### FireHydrant

- **Strengths:** runbook-driven (defines the steps each severity should
  take); strong on the "runbook automation" axis; good for teams that
  already write runbooks in markdown.
- **Trade-offs:** UI heavier than Incident.io; needs a couple of weeks
  of configuration to land the runbook taxonomy.
- **Wire-up:** PagerDuty -> FireHydrant via webhook; FireHydrant ->
  Slack via OAuth + bot; FireHydrant -> Statuspage via API key.

### Rootly

- **Strengths:** very strong Jira/Linear integration; built-in
  postmortem templates with the "5 Whys" structure; "incident
  retrospective" workflow built in.
- **Trade-offs:** smaller community than Incident.io; per-responder
  pricing.
- **Wire-up:** PagerDuty -> Rootly via Rootly's native PD integration;
  Rootly -> Slack via OAuth.

The platform team typically picks one in the first 90 days (per
ch.15.11). Migration between them is doable but costs ~2 weeks; the
real cost is reconfiguring the runbook automation.

## The wiring (vendor-neutral)

The diagram below shows the data flow. The same shape applies regardless
of which platform owns the orchestrator role.

```text
┌─────────────────┐
│  Prometheus     │
│  alert fires    │
└────────┬────────┘
         │
         ↓
┌─────────────────┐         ┌──────────────────┐
│  Alertmanager   │────────→│  PagerDuty       │
│  (routing)      │   API   │  (paging)        │
└─────────────────┘         └────────┬─────────┘
                                     │ webhook
                                     ↓
                            ┌──────────────────┐
                            │  Incident.io /   │
                            │  FireHydrant /   │
                            │  Rootly          │
                            │  (orchestrator)  │
                            └────────┬─────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
              ↓                      ↓                      ↓
       ┌──────────────┐       ┌──────────────┐       ┌──────────────┐
       │  Slack       │       │  Zoom        │       │  Statuspage  │
       │  (channel +  │       │  (war room)  │       │  (customer   │
       │  bot)        │       │              │       │  comm)       │
       └──────────────┘       └──────────────┘       └──────────────┘
              │                                              │
              │ messages tagged                              │ public-facing
              │ with UTC                                     │ updates by IC
              ↓                                              ↓
       ┌──────────────┐                              ┌──────────────┐
       │  Timeline    │                              │  Customer    │
       │  (auto-      │                              │  sees comm   │
       │  extracted)  │                              │              │
       └──────────────┘                              └──────────────┘
              │
              ↓
       ┌──────────────┐
       │  Postmortem  │
       │  (5-day      │
       │  deadline)   │
       └──────────────┘
```

## What each piece costs to set up

For the platform v2, expect roughly:

| Step                                    | Effort | Owner       |
|-----------------------------------------|--------|-------------|
| Pick the platform (Incident.io / FireHydrant / Rootly) | 1 week of evaluation | platform lead |
| Wire PagerDuty -> orchestrator          | 1 day  | on-call lead |
| Wire orchestrator -> Slack              | 1 day  | platform eng |
| Wire orchestrator -> Zoom               | 1 day  | platform eng |
| Wire orchestrator -> Statuspage         | 1 day  | platform eng |
| Configure incident-channel template     | 2 days | on-call lead |
| Configure IC-role-claim flow            | 1 day  | on-call lead |
| Configure runbook auto-post             | 1 day  | on-call lead |
| Configure postmortem deadline reminder  | 1 day  | on-call lead |
| Test end-to-end with a fake page        | 1 day  | on-call lead |

**Total:** ~2 weeks of platform-eng time + 1 week of evaluation. Pricing
varies per platform; budget $30-150/responder/month for a 5-10 person
on-call rotation.

## The minimum viable wire-up

If the team can't yet adopt a paid orchestrator, the minimum viable
automation uses only PagerDuty + Slack + a small bot:

1. **PagerDuty webhook to a Slack bot** — every PD incident creation
   pings the bot.
2. **Bot creates a Slack channel** — using the Slack `conversations.create`
   API; channel name follows the `inc-YYYY-MM-DD-NNN` pattern.
3. **Bot posts the PD details** — alert name, severity, affected
   service, runbook URL, dashboard URL.
4. **Bot pings the on-call** — using a `@oncall-payments` Slack group
   (the group's membership rotates via a small cron job).
5. **Manual:** the on-call opens the Zoom bridge manually; updates the
   status page manually.

This delivers ~60 % of the value of a paid orchestrator at ~5 % of the
ongoing cost. Most teams graduate from this to a paid orchestrator
within 6-12 months once the page volume justifies the spend.

## The IC-role claim flow (the hardest piece to get right)

The "IC claim" is the most-overlooked piece. Without it, every P0
incident has a confused first 10 minutes where 3 engineers try to
debug AND coordinate AND communicate, doing all three poorly. The
[sample postmortem 2026-04-15](sample-postmortem-2026-04-15.md) shows
the 12-minute IC-claim gap that delayed every downstream action.

The flow:

1. Orchestrator posts in the incident channel: **"Who is the Incident
   Commander? React with :raised_hand: to claim."**
2. First responder to react becomes the IC.
3. Orchestrator updates the channel title with the IC's name.
4. IC's first three actions (the IC checklist):
   - Acknowledge by typing "IC: \<name\>" in the channel.
   - Assign the recorder (who keeps the timeline).
   - Assign the comms lead (who updates the status page + drafts the
     customer email).

If no one claims within 5 minutes, the orchestrator escalates: posts
**"IC role unclaimed for 5 minutes — escalating to platform lead."**
The platform lead is paged.

## The status-page automation

Status-page updates can be one of three modes:

1. **Manual via Slack slash command** — IC types `/status update
   "Mitigation deployed; monitoring"`; orchestrator posts to the
   status page. Lowest friction; works for ~80 % of incidents.
2. **Templated via runbook** — runbook has pre-canned status-page
   templates for each phase (investigating / identified / monitoring /
   resolved); IC selects via dropdown. Good for repeat failure modes.
3. **Fully automated for the "common case"** — for known incidents
   (e.g. specific alert names), the orchestrator can auto-post the
   status-page entry. Use sparingly; auto-posts that get the
   customer-comm wrong are worse than no auto-post.

The bookstore platform uses mode 1 by default; mode 2 for the top-5
recurring failure modes; mode 3 only for the "we know exactly what
this is" cases (e.g. scheduled-maintenance announcements).

## Postmortem deadline tracking

The orchestrator schedules a reminder 5 business days after the incident
all-clear. The reminder:

1. Pings the postmortem author (set at incident close).
2. If no postmortem doc exists, files a `postmortem_overdue` P3 alert
   that pages the on-call primary.
3. The platform lead's weekly dashboard surfaces the overdue
   postmortem count.

This automation is what makes the "5 business days" rule in the
[severity matrix](severity-matrix.md) operational. Without it, the
rule is aspirational; with it, the rule is enforced.

## Anti-patterns this automation prevents

- **The "I'll just debug in DMs" anti-pattern.** Without a dedicated
  channel, the responders fragment across DMs, the timeline is
  unreconstructible, the postmortem is guesswork. The auto-created
  channel forces channel-discipline.
- **The "I forgot to update the status page" anti-pattern.** Without
  automation, status-page updates rely on the IC remembering — and at
  3am, the IC is debugging, not remembering. The auto-prompts
  ("update the status page" reminder at 5/15/30 min) close this gap.
- **The "we never wrote the postmortem" anti-pattern.** Without the
  5-day reminder, ~60 % of postmortems never ship (we measured during
  the platform v1 phase). With the reminder + the postmortem_overdue
  P3 alert, the closure rate rose to ~92 %.

## When to revisit this wiring

- After every P0/P1 incident, the postmortem asks "did the automation
  help or get in the way?" If the answer is "got in the way," that's
  an action item.
- Quarterly: review the orchestrator's spend vs. the page volume.
  If the page rate is dropping (good!), the per-responder pricing
  may be more than the value delivered.
- After any change to the severity matrix or the runbook structure,
  the auto-runbook-post needs re-validating.

See [chapter 15.10](../../../15-day-to-day-production-ops/10-incident-response-and-on-call.md)
for the chapter that walks through this end-to-end.
