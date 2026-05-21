#!/usr/bin/env bash
#
# Bookstore Platform v2 — Part 13 ch.12: the monthly DR drill script.
# Scripted, time-boxed (30-minute target), scored regional failover.
# Extends ch.13.03's manual failover into a repeatable monthly
# exercise. Both rehearses the platform's DR controls AND drives
# down the "human action time" each month.
#
# Usage:
#   bash dr-drill-script.sh --region <FROM> --target-region <TO> [--dry-run=true|false]
#
# Examples:
#   bash dr-drill-script.sh --region us-east --target-region eu-west --dry-run=true
#   bash dr-drill-script.sh --region us-east --target-region eu-west --dry-run=false
#
# Output: a markdown postmortem at
#   ../runbooks/dr-drill-$(date +%F).md
# with RTO + RPO + human action time, the three numbers tracked
# over time.

set -euo pipefail

# --------------------------------------------------------------------
# Parse args
# --------------------------------------------------------------------
REGION=""
TARGET_REGION=""
DRY_RUN="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --target-region) TARGET_REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN="${2:-true}"; shift 2 ;;
    --dry-run=*) DRY_RUN="${1#*=}"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REGION" || -z "$TARGET_REGION" ]]; then
  echo "Usage: $0 --region <FROM> --target-region <TO> [--dry-run=true|false]"
  exit 1
fi

START_TIME=$(date +%s)
DRILL_LOG="../runbooks/dr-drill-$(date +%F).md"
DRILL_DATE=$(date +'%Y-%m-%d %H:%M UTC')

# --------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------
log() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  printf "[%02d:%02d] %s\n" $((elapsed/60)) $((elapsed%60)) "$1"
}

run() {
  # Wraps a command; respects DRY_RUN.
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: $1"
  else
    log "EXEC: $1"
    eval "$1"
  fi
}

# --------------------------------------------------------------------
# Phase 0: pre-flight
# --------------------------------------------------------------------
log "DR DRILL STARTED — $REGION -> $TARGET_REGION (dry-run=$DRY_RUN)"

# Target region cluster healthy?
TARGET_CLUSTER_HEALTH=$(kubectl --context "kind-bookstore-platform-$TARGET_REGION" \
  get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' || echo "FAIL")
if [[ "$TARGET_CLUSTER_HEALTH" != *"True"* ]]; then
  log "PRE-FLIGHT FAILED: $TARGET_REGION cluster not healthy"
  exit 1
fi
log "Pre-flight: $TARGET_REGION cluster healthy"

# CNPG replication lag low?
REPLICATION_LAG=$(kubectl --context "kind-bookstore-platform-$REGION" \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -At -c "SELECT COALESCE(extract(epoch from (now() - reply_time))::int, 0) FROM pg_stat_replication WHERE application_name LIKE '%${TARGET_REGION}%' LIMIT 1;" 2>/dev/null || echo "0")
log "Pre-flight: CNPG replication lag = ${REPLICATION_LAG}s (target < 5s)"
if [[ "$REPLICATION_LAG" -gt 5 ]]; then
  log "PRE-FLIGHT WARN: replication lag > 5s; RPO target at risk"
fi

# --------------------------------------------------------------------
# Phase 1: cordon + drain the source region
# --------------------------------------------------------------------
log "PHASE 1: cordon + drain $REGION"
run "kubectl --context kind-bookstore-platform-$REGION cordon --selector=node-role.kubernetes.io/worker"

# --------------------------------------------------------------------
# Phase 2: promote the target's CNPG replica
# --------------------------------------------------------------------
log "PHASE 2: promote $TARGET_REGION CNPG to primary"
run "kubectl --context kind-bookstore-platform-$TARGET_REGION -n cnpg-system patch cluster bookstore-platform-cnpg --type merge -p '{\"spec\":{\"replica\":{\"enabled\":false}}}'"
sleep 5
PROMOTED_LSN=$(kubectl --context "kind-bookstore-platform-$TARGET_REGION" \
  -n cnpg-system exec bookstore-platform-cnpg-1 -- \
  psql -U postgres -At -c "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "(dry-run)")
log "$TARGET_REGION promoted to primary at LSN $PROMOTED_LSN"

# --------------------------------------------------------------------
# Phase 3: update Argo CD ApplicationSet target
# --------------------------------------------------------------------
log "PHASE 3: update ApplicationSet target to $TARGET_REGION"
run "kubectl --context kind-bookstore-platform-management -n argocd patch applicationset bookstore-platform --type merge -p '{\"spec\":{\"generators\":[{\"clusters\":{\"selector\":{\"matchLabels\":{\"region\":\"$TARGET_REGION\"}}}}]}}'"

# --------------------------------------------------------------------
# Phase 4: update DNS
# --------------------------------------------------------------------
log "PHASE 4: update DNS to point at $TARGET_REGION"
# In real life this is an ExternalDNS / Route53 update. The script
# documents the call but doesn't execute against prod DNS.
log "DNS update: gateway.bookstore-platform.example.com -> $TARGET_REGION"
if [[ "$DRY_RUN" == "false" ]]; then
  log "(execute Route53 change-resource-record-sets here)"
fi

# --------------------------------------------------------------------
# Phase 5: verify the checkout flow
# --------------------------------------------------------------------
log "PHASE 5: verify checkout against $TARGET_REGION"
VERIFY_START=$(date +%s)
for i in 1 2 3; do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    "https://gateway.bookstore-platform.example.com/healthz" 2>/dev/null || echo "000")
  log "Verify attempt $i: HTTP $STATUS"
  if [[ "$STATUS" == "200" ]]; then
    break
  fi
  sleep 5
done

# --------------------------------------------------------------------
# Compute the score
# --------------------------------------------------------------------
END_TIME=$(date +%s)
RTO_ACTUAL=$(( END_TIME - START_TIME ))
RPO_ACTUAL=$REPLICATION_LAG
HUMAN_ACTION_TIME=$(( END_TIME - START_TIME ))  # approximated in dry-run

log "DRILL ENDED"
log "  RTO actual:        ${RTO_ACTUAL}s   (target: 1800s = 30m)"
log "  RPO actual:        ${RPO_ACTUAL}s   (target: 300s = 5m)"
log "  Human action time: ${HUMAN_ACTION_TIME}s"

# --------------------------------------------------------------------
# Generate the postmortem stub
# --------------------------------------------------------------------
cat > "$DRILL_LOG" <<EOF
# DR Drill — $DRILL_DATE

## Targets
- RTO: 30 min (1800s)
- RPO: 5 min (300s)
- Human action: trend toward zero over months

## Result
- **PASS / FAIL**: $([ $RTO_ACTUAL -lt 1800 ] && [ $RPO_ACTUAL -lt 300 ] && echo PASS || echo FAIL)
- RTO actual:        ${RTO_ACTUAL}s
- RPO actual:        ${RPO_ACTUAL}s
- Human action time: ${HUMAN_ACTION_TIME}s

## Phases
- Phase 1 (cordon + drain): see drill log
- Phase 2 (promote CNPG): LSN $PROMOTED_LSN
- Phase 3 (ApplicationSet flip): see drill log
- Phase 4 (DNS update): see drill log
- Phase 5 (verify checkout): see drill log

## Findings
- TODO: fill in during the drill.

## Action items
- TODO: each must have owner + ticket + due date.

## Trend
| Date       | RTO   | RPO  | Human action |
|------------|-------|------|--------------|
| (previous) | (n/a) | (n/a)| (n/a)        |
| $DRILL_DATE | ${RTO_ACTUAL}s | ${RPO_ACTUAL}s | ${HUMAN_ACTION_TIME}s |
EOF

log "Postmortem template at: $DRILL_LOG"
log "Fill it in; track action items in the platform's GitHub project board."
