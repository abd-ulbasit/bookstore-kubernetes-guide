#!/usr/bin/env bash
# Lab 08.02: backup security and the Velero objects, checked on a kind cluster.
# Tier A (kind), with the Velero controller and node agent not run.
#
# Run this ONLY against a kind cluster you own, from any directory, and only
# while you hold the shared heavy-install lock: the script installs the Velero
# CRDs (cluster-scoped) and removes them at the end. It creates its own
# namespaces with a p08-02- prefix, applies the chapter's own Namespace,
# NetworkPolicy and RBAC blocks with that prefix, reads a generated demo value
# back the way a backup stores it, and deletes everything it created.
#
# It does not install the Velero controller, the node agent or an object store.
# The script renders the pinned chart with the chapter's security values, checks
# what the render produces, and asks the API server to validate the three Velero
# objects against the CRDs with strict server-side validation.
set +e

PY="${PY:-python3}"
GUIDE="$(cd "$(dirname "$0")/../../.." && pwd)"
CHAPTER="$GUIDE/08-day-2-operations/02-backup-and-dr.md"
PFX=p08-02
NS_BOOK=$PFX-bookstore
NS_VELERO=$PFX-velero
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$GUIDE/examples/bookstore/operators/velero-backup.yaml" \
   "$GUIDE/examples/bookstore/operators/velero-schedule.yaml" "$WORK/" || exit 2
cd "$WORK" || exit 2

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

# Run a command, retrying while the API server is busy. Only the final output
# is printed, so a retry does not leave error noise in the transcript.
retry_cmd() {
  local out n=0
  while :; do
    out=$("$@" 2>&1) && break
    n=$((n+1)); [ "$n" -ge 10 ] && break
    sleep 3
  done
  printf '%s\n' "$out"
}

# Apply the manifest on stdin, retrying while the API server is busy.
apply_retry() {
  local manifest
  manifest="$(cat)"
  printf '%s\n' "$manifest" | retry_cmd kubectl apply -f -
}

# Print the chapter's YAML blocks that contain $1, with the reader's namespace
# names replaced by the lab's, so the lab applies the chapter's own manifests.
chapter_yaml() {
  "$PY" -I - "$CHAPTER" "$1" "$NS_VELERO" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
needle, lab_ns = sys.argv[2], sys.argv[3]
for block in re.findall(r"```yaml\n(.*?)```", text, re.S):
    if needle in block:
        block = re.sub(r"(?m)^(\s*namespace: )velero$", r"\g<1>" + lab_ns, block)
        block = re.sub(r"(?m)^(kind: Namespace\nmetadata:\n  name: )velero$", r"\g<1>" + lab_ns, block)
        print(block.rstrip())
        print("---")
PYEOF
}

echo "# Transcript for 08-day-2-operations/02-backup-and-dr.md, lab steps 1 to 9."
echo "# Tier A: a kind cluster on Kubernetes v1.37.0, kubectl v1.37.2."
echo "# Recorded by running examples/security-lab/labs/08-02.sh."
echo "# The output in the chapter came from a lab cluster with a different name, and"
echo "# its namespaces carried the p08-02- prefix. The commands in the chapter use the"
echo "# reader's names (bookstore, velero); this transcript shows the lab's names,"
echo "# and the substitution is made only where the script builds a manifest."
echo "#"
echo "# Not run: the Velero controller, the node agent, an object store, a backup and"
echo "# a restore. The Velero CRDs were installed under the shared heavy-install lock"
echo "# and removed at the end (step 9). The chart was rendered, not installed."
echo "#"
echo "# What did not work the first time: the probe Pod needs the namespace's default"
echo "# ServiceAccount, which appeared a few seconds late, so the script waits for it."
echo "# The Velero image has no shell, so the probe mounts the image as a volume (the"
echo "# image-volume feature, which this cluster has) and reads /etc/passwd from it."
echo "#"

echo "## step 1: pins, checked against the registries and the chart repository"
run <<'CMD'
helm show chart vmware-tanzu/velero --version 12.2.2 | grep -E '^(appVersion|version):'
CMD
run <<'CMD'
timeout 120 docker buildx imagetools inspect velero/velero:v1.18.4 --format '{{.Manifest.Digest}}'
CMD
run <<'CMD'
timeout 120 docker buildx imagetools inspect velero/velero-plugin-for-aws:v1.14.4 --format '{{.Manifest.Digest}}'
CMD

echo "## step 2: the user the Velero image runs as, read from its /etc/passwd"
kubectl delete namespace "$NS_VELERO" --ignore-not-found --wait=true >/dev/null 2>&1
run <<CMD
kubectl apply -f - <<'YAML'
$(chapter_yaml "kind: Namespace" | sed -n '1,/^---$/p' | sed '$d')
YAML
CMD
for i in $(seq 1 150); do kubectl get sa default -n "$NS_VELERO" >/dev/null 2>&1 && break; sleep 2; done
run <<'CMD'
kubectl apply -n p08-02-velero -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: uid-probe
  namespace: p08-02-velero
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
      command: ["sh", "-c", "grep '^cnb:' /img/etc/passwd | cut -d: -f1,3,4"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      volumeMounts:
        - name: img
          mountPath: /img
          readOnly: true
  volumes:
    - name: img
      image:
        reference: docker.io/velero/velero@sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b
        pullPolicy: IfNotPresent
YAML
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/uid-probe -n p08-02-velero --timeout=280s
kubectl logs uid-probe -n p08-02-velero
kubectl delete pod uid-probe -n p08-02-velero --now
CMD

echo "## step 3: the chapter's NetworkPolicy and restorer RBAC blocks"
run <<CMD
kubectl apply -f - <<'YAML'
$(chapter_yaml "name: default-deny-all")
YAML
CMD
run <<CMD
kubectl apply -f - <<'YAML'
$(chapter_yaml "kind: Role")
YAML
CMD

echo "## step 4: the chart rendered with the chapter's security values, and its CRDs installed"
run <<'CMD'
helm template velero vmware-tanzu/velero -n velero --version 12.2.2 \
  --set image.digest=sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b \
  --set-json 'podSecurityContext={"runAsNonRoot":true,"runAsUser":1002,"runAsGroup":1000,"seccompProfile":{"type":"RuntimeDefault"}}' \
  --set-json 'containerSecurityContext={"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}' \
  --set deployNodeAgent=true --set snapshotsEnabled=false \
  --set credentials.existingSecret=velero-cloud-credentials \
  --set 'configuration.backupStorageLocation[0].name=default' \
  --set 'configuration.backupStorageLocation[0].provider=aws' \
  --set 'configuration.backupStorageLocation[0].bucket=example' \
  --set 'configuration.backupStorageLocation[0].config.region=us-east-1' \
  --set 'configuration.backupStorageLocation[0].config.s3Url=https://s3.example.com' \
  --set 'configuration.backupStorageLocation[0].config.s3ForcePathStyle=true' \
  --include-crds > velero-render.yaml && echo "rendered $(grep -c '^kind:' velero-render.yaml) objects"
CMD
run <<'CMD'
"$PY" -I - velero-render.yaml <<'PYEOF'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
crds = [d for d in docs if d.get("kind") == "CustomResourceDefinition"]
with open("velero-crds.yaml", "w") as f:
    yaml.safe_dump_all(crds, f)
print(f"{len(crds)} CustomResourceDefinitions written")
PYEOF
retry_cmd kubectl apply -f velero-crds.yaml
CMD

echo "## step 5: the restore grant, asked of the API server"
run <<'CMD'
kubectl auth can-i create restores.velero.io -n p08-02-velero --as=alice
kubectl auth can-i create restores.velero.io -n p08-02-velero --as=alice --as-group=velero-restorers
kubectl auth can-i get secrets -n p08-02-bookstore --as=alice --as-group=velero-restorers
CMD

echo "## step 6: a generated value in a Secret, read back as a backup stores it"
run <<CMD
retry_cmd kubectl create namespace $NS_BOOK
retry_cmd kubectl label namespace $NS_BOOK pod-security.kubernetes.io/enforce=restricted
CMD
run <<CMD
retry_cmd kubectl create secret generic db-demo -n $NS_BOOK --from-literal=password="\$(openssl rand -hex 16)"
CMD
run <<CMD
kubectl get secret db-demo -n $NS_BOOK -o jsonpath='{.data}'; echo
CMD
run <<CMD
kubectl get secret db-demo -n $NS_BOOK -o jsonpath='{.data.password}' | base64 -d; echo
CMD

echo "## step 7: the Velero Deployment in the render, with the chapter's security values"
run <<'CMD'
"$PY" -I - velero-render.yaml <<'PYEOF'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc or doc.get("kind") != "Deployment" or doc["metadata"]["name"] != "velero":
        continue
    pod = doc["spec"]["template"]["spec"]
    c = pod["containers"][0]
    sc = pod["securityContext"]
    cs = c["securityContext"]
    print("image:", c["image"])
    print("pod securityContext: runAsNonRoot=%s runAsUser=%s runAsGroup=%s seccomp=%s" % (
        sc["runAsNonRoot"], sc["runAsUser"], sc["runAsGroup"], sc["seccompProfile"]["type"]))
    print("container securityContext: allowPrivilegeEscalation=%s readOnlyRootFilesystem=%s drop=%s" % (
        cs["allowPrivilegeEscalation"], cs["readOnlyRootFilesystem"], ",".join(cs["capabilities"]["drop"])))
PYEOF
CMD

echo "## step 8: the three Velero objects, validated by the API server with strict field checks"
run <<CMD
chapter_yaml "kind: Restore" > restore-all.yaml
"\$PY" -I - restore-all.yaml restore.yaml <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
docs = [d for d in re.split(r"(?m)^---$", text) if "kind: Restore" in d]
open(sys.argv[2], "w", encoding="utf-8").write(docs[0])
PYEOF
"\$PY" -I - velero-backup.yaml velero-schedule.yaml <<'PYEOF'
import re, sys
for name in sys.argv[1:]:
    text = open(name, encoding="utf-8").read()
    text = re.sub(r"(?m)^(  namespace: )velero\\b", r"\\g<1>$NS_VELERO", text)
    open(name, "w", encoding="utf-8").write(text)
PYEOF
kubectl apply --dry-run=server --validate=strict -f velero-backup.yaml -f velero-schedule.yaml -f restore.yaml
CMD
run <<'CMD'
sed 's/^spec:$/spec:\n  namespaceMappng: {}/' restore.yaml > restore-typo.yaml
kubectl apply --dry-run=server --validate=strict -f restore-typo.yaml
CMD

echo "## step 9: delete what this lab created"
retry_cmd kubectl delete -f velero-crds.yaml --ignore-not-found --wait=true >/dev/null
run <<CMD
retry_cmd kubectl delete namespace $NS_BOOK $NS_VELERO --wait=true --timeout=240s
CMD
echo "# lab 08-02 finished"
