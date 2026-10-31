#!/usr/bin/env bash
# Check that a Pod built on a musl image can resolve a cluster name, and fix
# the nodes if it cannot.
#
# Docker copies the runner VM's resolver file into every kind node, search
# domain included. A Pod inherits the search domain from its node. A cluster
# name such as catalog.bookstore.svc.cluster.local has four dots, fewer than
# the Pod's ndots of 5, so the resolver tries each search domain first. The
# VM's search domain goes to the upstream resolver, and musl's resolver (the
# curl and busybox images) stops at an answer that is neither a success nor
# a clean NXDOMAIN, so curl reports "Could not resolve host" for a name that
# CoreDNS would have answered. Go programs and glibc programs go on to the
# next candidate and work, which is why the Bookstore's own Pods are fine.
# This script tests that reading and does not assume it: the job log shows the
# resolver files and the answers before and after.
#
# The fix is to drop the search line from each node's resolver file before any
# lab Pod starts. Pods read the file when they are created.
#
# The files print to the job log only, never to a transcript.
set -uo pipefail

CURL=curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b  # 8.10.1

# Run curl in a Pod with the Bookstore's hardening (non-root, read-only root,
# no capabilities, RuntimeDefault seccomp). The Pod is not attached to: a
# container that exits at once loses the race with an attach. Wait for the Pod
# to end, print its log, and delete it.
probe() {
  local name=$1 url=$2 phase
  kubectl delete pod "$name" --ignore-not-found --now >/dev/null 2>&1
  kubectl run "$name" --restart=Never --image="$CURL" \
    --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":100,"runAsGroup":101,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$name"'","image":"'"$CURL"'","command":["curl","-sS","-m","10","-o","/dev/null","-w","%{http_code}\\n","'"$url"'"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null 2>&1
  for _ in $(seq 1 45); do
    phase=$(kubectl get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2
  done
  kubectl logs "$name" 2>&1
  kubectl delete pod "$name" --now >/dev/null 2>&1
}

# The HTTP status line of a probe's log, or nothing.
status_of() { printf '%s\n' "$1" | grep -E '^[0-9]{3}$' | head -1; }

# The Pod's own resolver file and what busybox's resolver makes of a few names.
look() {
  kubectl delete pod dnslook --ignore-not-found --now >/dev/null 2>&1
  kubectl run dnslook --restart=Never --image="$CURL" --command -- sh -c '
    echo "--- the Pod resolver file"; cat /etc/resolv.conf
    for n in kubernetes.default.svc.cluster.local kubernetes.default.svc.cluster.local. github.com; do
      echo "--- nslookup $n"; nslookup "$n" 2>&1 | tail -3
    done' >/dev/null 2>&1
  for _ in $(seq 1 45); do
    case "$(kubectl get pod dnslook -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded|Failed) break ;; esac
    sleep 2
  done
  kubectl logs dnslook 2>&1 | head -40
  kubectl delete pod dnslook --now >/dev/null 2>&1
}

url=https://kubernetes.default.svc.cluster.local/healthz
node=$(docker ps --format '{{.Names}}' | grep -m1 -- '-worker$')
echo "--- a kind node's resolver file"
docker exec "$node" cat /etc/resolv.conf
echo "--- before: HTTP status for $url from a hardened curl Pod"
beforelog=$(probe dnscheck "$url")
echo "$beforelog"
before=$(status_of "$beforelog")
echo "--- before: what the Pod sees"
look
if [ -n "$before" ] && [ "$before" != 000 ]; then
  echo "name resolution works as it is"
  exit 0
fi
echo "--- dropping the search line from each node's resolver file"
for n in $(docker ps --format '{{.Names}}' | grep -E -- '-(control-plane|worker[0-9]*)$'); do
  docker exec "$n" sh -c 'grep -v "^search" /etc/resolv.conf > /tmp/resolv.new && cat /tmp/resolv.new > /etc/resolv.conf'
done
docker exec "$node" cat /etc/resolv.conf
echo "--- after: HTTP status for $url"
afterlog=$(probe dnscheck2 "$url")
echo "$afterlog"
after=$(status_of "$afterlog")
echo "--- after: what the Pod sees"
look
[ -n "$after" ] && [ "$after" != 000 ]
