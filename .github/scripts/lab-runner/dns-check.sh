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
#
# The fix is to drop the search line from each node's resolver file before any
# lab Pod starts. Pods read the file when they are created.
#
# The files print to the job log only, never to a transcript.
set -uo pipefail

CURL=curlimages/curl@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b  # 8.10.1

probe() {
  kubectl run dnscheck --rm -i --restart=Never --quiet --image="$CURL" -- \
    curl -sk -m 10 -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc.cluster.local/healthz 2>&1 | tail -1
}

echo "--- a kind node's resolver file"
docker exec "$(docker ps --format '{{.Names}}' | grep -m1 -- '-worker$')" cat /etc/resolv.conf
echo "--- before: HTTP status for kubernetes.default.svc.cluster.local from a curl Pod"
before=$(probe)
echo "$before"
if [ "$before" != 000 ] && [ -n "$before" ]; then
  echo "name resolution works as it is"
  exit 0
fi
echo "--- dropping the search line from each node's resolver file"
for n in $(docker ps --format '{{.Names}}' | grep -E -- '-(control-plane|worker[0-9]*)$'); do
  docker exec "$n" sh -c 'grep -v "^search" /etc/resolv.conf > /tmp/resolv.new && cat /tmp/resolv.new > /etc/resolv.conf'
done
echo "--- after"
after=$(probe)
echo "$after"
[ "$after" != 000 ] && [ -n "$after" ]
