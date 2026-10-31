#!/usr/bin/env bash
# Collect what explains a failed lab run: Pods that are not ready, their
# events and logs, and the state of the nodes. The output goes to the file
# named by the first argument and is uploaded as an artifact. It reads only
# object status, events and container logs, never a Secret.
set -u

out=$1
{
  echo "== nodes"
  kubectl get nodes -o wide
  kubectl top nodes 2>&1 | head -10
  echo
  echo "== host"
  free -m
  df -h /
  uptime
  echo
  echo "== Pods that are not Running and ready"
  kubectl get pods -A --no-headers 2>/dev/null \
    | awk '{split($3,a,"/")} ($4=="Completed") {next} ($4!="Running" || a[1]!=a[2]) {print $1, $2, $3, $4}'
  echo
  echo "== recent warning events"
  kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -60
  echo
} > "$out" 2>&1

kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{split($3,a,"/")} ($4=="Completed") {next} ($4!="Running" || a[1]!=a[2]) {print $1, $2}' \
  | head -12 \
  | while read -r ns pod; do
      {
        echo "== describe $ns/$pod"
        kubectl -n "$ns" describe pod "$pod" 2>&1 | sed -n '/^Containers:/,$p' | head -90
        echo "== logs $ns/$pod (last 40 lines of each container)"
        kubectl -n "$ns" logs "$pod" --all-containers --tail=40 2>&1 | head -120
        echo
      } >> "$out" 2>&1
    done
