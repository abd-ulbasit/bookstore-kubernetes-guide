#!/usr/bin/env bash
# Lab 08.02: backup security and the Velero install, checked on a kind cluster.
# Tier A (kind). The Velero controller runs; a backup and a restore do not.
#
# Run this ONLY against a kind cluster you own, from any directory, and only
# while you hold the shared heavy-install lock: the script installs the Velero
# chart, which creates cluster-scoped objects (the velero.io CRDs and a
# ClusterRoleBinding), and removes them at the end. It creates its own
# namespaces with a p08-02- prefix, applies the chapter's own Namespace,
# LimitRange, NetworkPolicy and RBAC blocks with that prefix, installs the chart
# with the chapter's default (CSI snapshot) values against a placeholder object
# store that does not resolve, reads the running Deployment back, checks the
# node-agent exception with a server dry run, reads a generated demo value back
# the way a backup stores it, and deletes everything it created.
#
# It does not run an object store, a snapshot-capable CSI driver, a backup or a
# restore, and it does not apply the chapter's privileged exception namespace.
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

# The chart's objects are cluster-scoped, so refuse to start over somebody
# else's Velero.
if kubectl get crd -o name 2>/dev/null | grep -q '\.velero\.io$' \
   || kubectl get clusterrolebinding velero-server >/dev/null 2>&1; then
  echo "refusing to run: this cluster already has Velero objects" >&2
  exit 2
fi

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

# Print the chapter's YAML blocks that contain $1, with the reader's namespace
# names replaced by the lab's, so the lab applies the chapter's own manifests.
# With "first" as $2, print only the first matching block.
chapter_yaml() {
  "$PY" -I - "$CHAPTER" "$1" "$NS_VELERO" "${2:-all}" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
needle, lab_ns, mode = sys.argv[2], sys.argv[3], sys.argv[4]
for block in re.findall(r"```yaml\n(.*?)```", text, re.S):
    if needle in block:
        block = re.sub(r"(?m)^(\s*namespace: )velero$", r"\g<1>" + lab_ns, block)
        block = re.sub(r"(?m)^(kind: Namespace\nmetadata:\n  name: )velero$", r"\g<1>" + lab_ns, block)
        print(block.rstrip())
        print("---")
        if mode == "first":
            break
PYEOF
}

echo "# Transcript for 08-day-2-operations/02-backup-and-dr.md, lab steps 1 to 9."
echo "# Tier A: a kind cluster on Kubernetes v1.37.0, kubectl v1.37.2, Helm v4.1.4."
echo "# Recorded by running examples/security-lab/labs/08-02.sh."
echo "# The output in the chapter came from a lab cluster with a different name, and"
echo "# its namespaces carried the p08-02- prefix. The commands in the chapter use the"
echo "# reader's names (bookstore, velero); this transcript shows the lab's names,"
echo "# and the substitution is made only where the script builds a manifest."
echo "# The chapter's velero namespace is restricted on its default path, so the lab"
echo "# name p08-02-velero carries no label above restricted and needs no entry in"
echo "# the exceptions registry. The chapter's privileged exception namespace is not"
echo "# applied here."
echo "#"
echo "# Run: the Velero chart on the CSI snapshot path, in a restricted namespace,"
echo "# with a placeholder object store that does not resolve. The controller and"
echo "# its plugin ran and reported the storage location unavailable. The chart's"
echo "# CRD job ran in the same namespace. The node-agent exception was only"
echo "# dry-run, never installed."
echo "# Not run: an object store, a snapshot-capable CSI driver, a backup and a"
echo "# restore. The cluster's storage class cannot take snapshots. The lab held"
echo "# the shared heavy-install lock and removed the chart, the CRDs and the"
echo "# cluster-scoped objects at the end (step 9)."
echo "#"
echo "# What did not work the first time: the probe Pod needs the namespace's default"
echo "# ServiceAccount, which appeared a few seconds late, so the script waits for it."
echo "# The Velero image has no shell, so the probe mounts the image as a volume (the"
echo "# image-volume feature, which this cluster has) and reads /etc/passwd from it."
echo "# The chart's one-shot CRD job has no resources value, so the namespace's"
echo "# LimitRange supplies its requests and memory limit."
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

echo "## step 2: the restricted namespace, and the user the Velero image runs as"
kubectl delete namespace "$NS_VELERO" --ignore-not-found --wait=true >/dev/null 2>&1
run <<CMD
kubectl apply -f - <<'YAML'
$(chapter_yaml "kind: Namespace" first | sed '$d')
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

echo "## step 3: install the chart on the CSI snapshot path"
run <<'CMD'
umask 077
CREDS_FILE="$(mktemp)"
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' lab-placeholder lab-placeholder > "$CREDS_FILE"
kubectl create secret generic velero-cloud-credentials -n p08-02-velero --from-file=cloud="$CREDS_FILE"
rm -f "$CREDS_FILE"
CMD
VELERO_CHART_VERSION=12.2.2
VELERO_IMAGE_DIGEST=sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b
VELERO_AWS_PLUGIN=docker.io/velero/velero-plugin-for-aws@sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa
VELERO_BUCKET=example
VELERO_REGION=us-east-1
VELERO_S3_URL=https://s3.example.com
export VELERO_CHART_VERSION VELERO_IMAGE_DIGEST VELERO_AWS_PLUGIN VELERO_BUCKET VELERO_REGION VELERO_S3_URL
run <<'CMD'
helm install velero vmware-tanzu/velero -n p08-02-velero \
  --version "$VELERO_CHART_VERSION" --wait \
  --set image.digest="$VELERO_IMAGE_DIGEST" \
  --set-json 'initContainers=[{"name":"velero-plugin-for-aws","image":"'"$VELERO_AWS_PLUGIN"'","imagePullPolicy":"IfNotPresent","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"mountPath":"/target","name":"plugins"}]}]' \
  --set-json 'podSecurityContext={"runAsNonRoot":true,"runAsUser":1002,"runAsGroup":1000,"seccompProfile":{"type":"RuntimeDefault"}}' \
  --set-json 'containerSecurityContext={"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}' \
  --set resources.requests.cpu=500m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi \
  --set configuration.features=EnableCSI \
  --set deployNodeAgent=false \
  --set snapshotsEnabled=false \
  --set 'configuration.backupStorageLocation[0].name=default' \
  --set 'configuration.backupStorageLocation[0].provider=aws' \
  --set "configuration.backupStorageLocation[0].bucket=$VELERO_BUCKET" \
  --set "configuration.backupStorageLocation[0].config.region=$VELERO_REGION" \
  --set "configuration.backupStorageLocation[0].config.s3Url=$VELERO_S3_URL" \
  --set 'configuration.backupStorageLocation[0].config.s3ForcePathStyle=true' \
  --set credentials.existingSecret=velero-cloud-credentials
CMD
run <<'CMD'
kubectl -n p08-02-velero rollout status deploy/velero --timeout=120s
kubectl -n p08-02-velero get pods
CMD
# The storage location validates on a timer. Wait for the first verdict.
for i in $(seq 1 60); do
  [ -n "$(kubectl -n "$NS_VELERO" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null)" ] && break
  sleep 3
done
run <<'CMD'
kubectl -n p08-02-velero get backupstoragelocation
CMD
run <<'CMD'
kubectl -n p08-02-velero get deploy,daemonset
CMD

echo "## step 4: what is running, read back from the live objects"
run <<'CMD'
kubectl -n p08-02-velero get deploy velero -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" resources: "}{.resources}{"\n"}{end}'
kubectl -n p08-02-velero get pod -l name=velero -o jsonpath='{range .items[0].spec.initContainers[*]}{.name}{" resources (from the LimitRange): "}{.resources}{"\n"}{end}'
kubectl -n p08-02-velero get deploy velero -o jsonpath='pod securityContext: {.spec.template.spec.securityContext}{"\n"}'
kubectl -n p08-02-velero get deploy velero -o jsonpath='container securityContext: {.spec.template.spec.containers[0].securityContext}{"\n"}'
kubectl -n p08-02-velero get deploy velero -o jsonpath='server args: {.spec.template.spec.containers[0].args}{"\n"}'
CMD
run <<'CMD'
kubectl -n p08-02-velero logs deploy/velero -c velero | grep 'Starting Velero server' | sed -E 's/.*msg="(Starting Velero server v[0-9.]+).*/\1/'
CMD
run <<'CMD'
kubectl get crd -o name | grep -c '\.velero\.io$'
CMD

echo "## step 5: the node-agent exception, asked of the API server with a dry run"
run <<'CMD'
helm template velero vmware-tanzu/velero -n p08-02-velero --version 12.2.2 --show-only templates/node-agent-daemonset.yaml \
  --set image.digest=sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b \
  --set deployNodeAgent=true --set snapshotsEnabled=false --set configuration.features=EnableCSI \
  --set credentials.existingSecret=velero-cloud-credentials \
  --set-json 'nodeAgent.podSecurityContext={"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}' \
  --set-json 'nodeAgent.containerSecurityContext={"allowPrivilegeEscalation":false}' \
  --set nodeAgent.resources.requests.cpu=500m \
  --set nodeAgent.resources.requests.memory=512Mi \
  --set nodeAgent.resources.limits.memory=1Gi \
  | kubectl apply --dry-run=server -f -
CMD
run <<'CMD'
helm template velero vmware-tanzu/velero -n p08-02-velero --version 12.2.2 --show-only templates/node-agent-daemonset.yaml \
  --set image.digest=sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b \
  --set deployNodeAgent=true --set snapshotsEnabled=false --set configuration.features=EnableCSI \
  --set credentials.existingSecret=velero-cloud-credentials \
  --set nodeAgent.disableHostPath=true \
  --set-json 'nodeAgent.podSecurityContext={"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}' \
  --set-json 'nodeAgent.containerSecurityContext={"allowPrivilegeEscalation":false}' \
  --set nodeAgent.resources.requests.cpu=500m \
  --set nodeAgent.resources.requests.memory=512Mi \
  --set nodeAgent.resources.limits.memory=1Gi \
  | kubectl apply --dry-run=server -f -
CMD

echo "## step 6: the chapter's NetworkPolicy and restorer RBAC blocks, and the restore grant"
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
run <<'CMD'
kubectl auth can-i create restores.velero.io -n p08-02-velero --as=alice
kubectl auth can-i create restores.velero.io -n p08-02-velero --as=alice --as-group=velero-restorers
kubectl auth can-i get secrets -n p08-02-bookstore --as=alice --as-group=velero-restorers
CMD

echo "## step 7: a generated value in a Secret, read back as a backup stores it"
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
run <<'CMD'
helm uninstall velero -n p08-02-velero
CMD
run <<'CMD'
kubectl get crd -o name | grep '\.velero\.io$' | xargs -r kubectl delete
CMD
run <<CMD
retry_cmd kubectl delete namespace $NS_BOOK $NS_VELERO --wait=true --timeout=240s
CMD
run <<'CMD'
kubectl get crd,clusterrole,clusterrolebinding -o name | grep -i velero || echo "no velero cluster objects left"
CMD
echo "# lab 08-02 finished"
