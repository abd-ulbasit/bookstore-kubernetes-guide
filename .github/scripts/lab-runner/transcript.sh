#!/usr/bin/env bash
# Build a lab transcript from a runner recording: the evidence header, then the
# recording with the runner's paths and colour codes taken out. The leak check
# of the evidence gate (G7) then reads the result, and a leak fails the step.
#
#   transcript.sh LAB CHAPTER SCRIPT RAW OUT
#
#   LAB      the lab name, for example 06-01
#   CHAPTER  the chapter path under full-guide/, for the header
#   SCRIPT   the lab script name under examples/security-lab/labs/
#   RAW      the recording the script wrote to standard output
#   OUT      the transcript to write
#
# The environment supplies RUN_URL, RUN_ATTEMPT, GITHUB_SHA and the paths
# GITHUB_WORKSPACE, RUNNER_TEMP and HOME that the runner uses.
set -euo pipefail

lab=$1 chapter=$2 script=$3 raw=$4 out=$5
here=$(cd "$(dirname "$0")" && pwd)

os=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
kernel=$(uname -r)
cpus=$(nproc)
mem_gib=$(awk '/MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo)
kubectl_v=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || true)
kind_v=$(kind version 2>/dev/null | awk '{print $2}' || true)
helm_v=$(helm version --short 2>/dev/null | sed 's/+.*//' || true)
docker_v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
node_v=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
runtime_v=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || true)
nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)

{
  echo "# Runner recording for ${chapter}."
  echo "# It ran on a GitHub Actions runner, not on the lab host. Run URL:"
  echo "# ${RUN_URL} (attempt ${RUN_ATTEMPT:-1})"
  echo "# Commit: ${GITHUB_SHA}"
  echo "# Tier A: a kind cluster of ${nodes} nodes, Kubernetes ${node_v} (kind ${kind_v},"
  echo "# node image pinned by digest in examples/security-lab/kind), kubectl"
  echo "# ${kubectl_v}, Helm ${helm_v}. Node runtime: ${runtime_v}."
  echo "# Host: ${os}, kernel ${kernel}, ${cpus} vCPU, about ${mem_gib} GiB of"
  echo "# memory, Docker ${docker_v}. Recorded by running"
  echo "# examples/security-lab/labs/${script} from the workflow lab-on-runner.yml."
  echo "# Paths of the runner's checkout and temporary directory are written as"
  echo "# <repo> and <tmp>. Terminal colour codes are removed, and tabs become spaces"
  echo "# (tab stops every 4 columns, as the evidence gate reads a chapter's code"
  echo "# blocks). Nothing else is edited."
  echo "#"
} > "$out"

sed -E \
  -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
  -e "s#${GITHUB_WORKSPACE}#<repo>#g" \
  -e "s#${RUNNER_TEMP}#<tmp>#g" \
  -e "s#${HOME}#<home>#g" \
  "$raw" | expand -t 4 >> "$out"

python3 -I - "$here/../gates" "$out" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import evidence_gate
text = open(sys.argv[2], encoding="utf-8").read()
found = evidence_gate.leaks(text)
for item in found:
    print(f"leak in the transcript: {item}", file=sys.stderr)
sys.exit(1 if found else 0)
PY
echo "transcript for ${lab}: $(wc -l < "$out") lines, no leaks found by the evidence gate" >&2
