#!/usr/bin/env bash
# Lab 05.03: supply chain security on the catalog image. Tier A (kind plus a
# lab registry on the Docker host).
#
# Run this ONLY against a kind cluster you own. The script refuses any kubectl
# context that is not a kind cluster. It starts a lab registry, builds the
# catalog image with BuildKit provenance and pushes it there, then scans it,
# writes an SBOM, compares two scanners on that SBOM, records a VEX statement
# that leaves the finding in place, signs and attests the digest with a
# throwaway key, and lints two manifests. It then asks a
# restricted namespace to refuse the insecure one.
#
# Steps 11 and 12 change what a node pulls, so they run only against the
# throwaway cluster supply-chain (kind/supply-chain.yaml), which carries the
# containerd setting that lets a node reach the lab registry. On any other
# kind cluster they are skipped and printed as skipped. The script deletes
# what it made: the namespace, the registry and the scratch directory.
#
# The signing config names no transparency log, so no signature or
# attestation reaches a public log. A keyless signature needs an OIDC identity
# from a CI run; 07.03 builds that pipeline.
#
# The scanners and the signer reach the registry at localhost:5001. A Docker
# host other than this machine needs that port forwarded first:
#   ssh -fN -L 5001:127.0.0.1:5001 <docker-host>
set +e

NS=p05-03-supply-chain
REG=localhost:5001                # where the scanners and the signer reach it
NODE_REG=lab-registry:5000          # the same registry, as the kind nodes name it
REG_IMAGE='registry:3@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3'

# Read a command from stdin, print it exactly as written, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac
cluster=no
[ "$ctx" = kind-supply-chain ] && cluster=yes

guide=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1   # full-guide/
work=$(mktemp -d) && cd "$work" || exit 1

echo '## step 0: the tools this run used'
run <<'CMD'
trivy --version | head -1
syft version | grep Version
grype version | grep Version
cosign version | grep GitVersion
kube-linter version
kubesec version | head -1
kubectl version --client -o json | jq -r '.clientVersion.gitVersion'
kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}{"\n"}'
docker buildx version | cut -d' ' -f1-2
CMD

echo '## step 1: a lab registry on the kind network, and the nodes told to trust it'
docker rm -f p05-03-registry >/dev/null 2>&1
run <<CMD
docker run -d --name p05-03-registry --network kind --network-alias lab-registry -p 127.0.0.1:5001:5000 $REG_IMAGE >/dev/null && echo "registry started"
CMD
for i in $(seq 1 60); do curl -fsS -m 2 "http://$REG/v2/" >/dev/null 2>&1 && break; sleep 1; done
printf '[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n' "$NODE_REG" > hosts.toml
run <<'CMD'
for n in $(docker ps --filter label=io.x-k8s.kind.cluster=supply-chain --format '{{.Names}}'); do
  docker exec "$n" mkdir -p /etc/containerd/certs.d/lab-registry:5000
  docker exec -i "$n" sh -c 'cat > /etc/containerd/certs.d/lab-registry:5000/hosts.toml' < hosts.toml
  docker exec "$n" getent hosts lab-registry >/dev/null && echo "$n resolves lab-registry"
done
CMD

echo '## step 2: a namespace that enforces restricted'
kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
run <<CMD
kubectl create ns $NS
kubectl label ns $NS pod-security.kubernetes.io/enforce=restricted \\
  pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
CMD

echo '## step 3: build the catalog with BuildKit provenance and push it to the lab registry'
run <<'CMD'
docker buildx build --platform linux/amd64 --provenance=mode=max --push --progress=quiet \
  -t localhost:5001/bookstore/catalog:lab "$guide/examples/bookstore/app/catalog"
CMD
run <<'CMD'
D0=$(docker buildx imagetools inspect localhost:5001/bookstore/catalog:lab --format '{{.Manifest.Digest}}')
echo "signed digest: $D0"
CMD
run <<CMD
docker buildx imagetools inspect $REG/bookstore/catalog:lab
CMD
run <<CMD
docker buildx imagetools inspect $REG/bookstore/catalog:lab --format '{{json .Provenance}}' |
  jq -r '.SLSA.buildDefinition.buildType'
docker buildx imagetools inspect $REG/bookstore/catalog:lab --format '{{json .Provenance}}' |
  jq -r '.SLSA.buildDefinition.resolvedDependencies[] | "\(.uri | split("@")[0]) sha256:\(.digest.sha256)"'
CMD

echo '## step 4: scan the image digest with Trivy'
run <<CMD
trivy image --platform linux/amd64 --image-src remote --scanners vuln --severity HIGH,CRITICAL $REG/bookstore/catalog@\$D0
CMD

echo '## step 5: write the SBOM with Syft, CycloneDX'
run <<CMD
syft --platform linux/amd64 registry:$REG/bookstore/catalog@\$D0 -o cyclonedx-json=catalog.cdx.json
jq -r '[.components[].type] | group_by(.) | map("\(.[0]) \(length)")[]' catalog.cdx.json
CMD

echo '## step 6: two scanners, one SBOM'
run <<CMD
trivy sbom --quiet --format json --scanners vuln catalog.cdx.json |
  jq -r '[.Results[]?.Vulnerabilities[]? | .VulnerabilityID + " " + .PkgName + " " + .Severity] | sort[]' > trivy.txt
grype sbom:catalog.cdx.json -q -o json |
  jq -r '[.matches[] | .vulnerability.id + " " + .artifact.name + " " + .vulnerability.severity] | sort[]' > grype.txt
echo "trivy on the SBOM: \$(wc -l < trivy.txt | tr -d ' ') finding(s)"
echo "grype on the SBOM: \$(wc -l < grype.txt | tr -d ' ') finding(s)"
echo "only trivy reports:"; comm -23 trivy.txt grype.txt
echo "only grype reports:"; comm -13 trivy.txt grype.txt
echo "grype on the image itself: \$(grype --platform linux/amd64 -q -o json registry:$REG/bookstore/catalog@\$D0 | jq '.matches | length') match(es)"
CMD

echo '## step 7: a VEX statement that says the finding is under investigation'
run <<CMD
P=\$(jq -r '.components[] | select(.name=="golang.org/x/sys") | .purl' catalog.cdx.json)
cat > vex.json <<JSON
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://example.invalid/vex/p05-catalog-lab",
  "author": "05.03 lab",
  "timestamp": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": 1,
  "statements": [
    {
      "vulnerability": {"name": "CVE-2026-39824"},
      "products": [{"@id": "\$P"}],
      "status": "under_investigation"
    }
  ]
}
JSON
echo "grype with vex.json: \$(grype sbom:catalog.cdx.json --vex vex.json -q -o json | jq '.matches | length') finding(s)"
echo "trivy with vex.json: \$(trivy sbom --quiet --format json --scanners vuln --vex vex.json catalog.cdx.json | jq '[.Results[]?.Vulnerabilities[]?] | length') finding(s)"
CMD

echo '## step 8: sign the digest with a throwaway key, with no transparency log'
run <<'CMD'
COSIGN_PASSWORD= cosign generate-key-pair
CMD
cat > signing-config.json <<'JSON'
{
  "mediaType": "application/vnd.dev.sigstore.signingconfig.v0.2+json",
  "caUrls": [],
  "oidcUrls": [],
  "rekorTlogUrls": [],
  "tsaUrls": []
}
JSON
run <<CMD
COSIGN_PASSWORD= cosign sign --yes --key cosign.key --signing-config=signing-config.json $REG/bookstore/catalog@\$D0
CMD
run <<CMD
cosign verify --key cosign.pub --insecure-ignore-tlog $REG/bookstore/catalog@\$D0 >verify.json 2>verify.err
echo "verify exit=\$?"
head -n 1 verify.err
jq -r '.[0].critical.image."docker-manifest-digest"' verify.json
CMD

echo '## step 9: attest the SBOM as a signed in-toto statement, then read its predicate type'
run <<CMD
COSIGN_PASSWORD= cosign attest --yes --key cosign.key --signing-config=signing-config.json --type cyclonedx --predicate catalog.cdx.json $REG/bookstore/catalog@\$D0
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog --type cyclonedx $REG/bookstore/catalog@\$D0 2>/dev/null |
  jq -r '.payload' | base64 --decode | jq -r '.predicateType'
CMD

echo '## step 10: attack, move the tag under the signed digest'
mkdir -p tamper
printf 'FROM %s\nCOPY payload.txt /payload.txt\n' "$REG/bookstore/catalog@$D0" > tamper/Dockerfile
echo "an attacker's file" > tamper/payload.txt
run <<CMD
docker buildx build --platform linux/amd64 --provenance=false --push --progress=quiet -t $REG/bookstore/catalog:lab tamper
D1=\$(docker buildx imagetools inspect $REG/bookstore/catalog:lab --format '{{.Manifest.Digest}}')
echo "signed digest:  \$D0"
echo "tag now points: \$D1"
CMD
run <<CMD
cosign verify --key cosign.pub --insecure-ignore-tlog $REG/bookstore/catalog:lab >/dev/null 2>verify-tag.err
echo "verify of the tag, exit=\$?"
grep -v WARNING verify-tag.err | head -n 1
CMD

cat > serviceaccount.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: catalog, namespace: $NS}
automountServiceAccountToken: false
YAML
cat > by-digest.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: catalog-by-digest, namespace: $NS}
spec:
  serviceAccountName: catalog
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: catalog
      image: $NODE_REG/bookstore/catalog@$D0
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 64Mi}
      volumeMounts: [{name: tmp, mountPath: /tmp}]
  volumes: [{name: tmp, emptyDir: {}}]
YAML
if [ "$cluster" = yes ]; then
echo '## step 11: a Pod that names the tag runs whatever the tag points to'
cat > by-tag.yaml <<YAML
apiVersion: v1
kind: Pod
metadata: {name: catalog-by-tag, namespace: $NS}
spec:
  serviceAccountName: catalog
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: catalog
      image: $NODE_REG/bookstore/catalog:lab
      imagePullPolicy: Always
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 64Mi}
      volumeMounts: [{name: tmp, mountPath: /tmp}]
  volumes: [{name: tmp, emptyDir: {}}]
YAML
run <<CMD
kubectl apply -n $NS -f serviceaccount.yaml -f by-tag.yaml
kubectl wait -n $NS --for=condition=Ready --timeout=120s pod/catalog-by-tag
echo "signed digest:  \$D0"
echo "running digest: \$(kubectl get pod -n $NS catalog-by-tag -o jsonpath='{.status.containerStatuses[0].imageID}' | sed 's/.*@//')"
CMD

echo '## step 12: harden, pin the digest, and re-attack the tag'
run <<CMD
kubectl apply -n $NS -f by-digest.yaml
kubectl wait -n $NS --for=condition=Ready --timeout=120s pod/catalog-by-digest
echo "running digest: \$(kubectl get pod -n $NS catalog-by-digest -o jsonpath='{.status.containerStatuses[0].imageID}' | sed 's/.*@//')"
CMD
printf 'FROM %s\nCOPY payload.txt /payload.txt\n' "$REG/bookstore/catalog@$D0" > tamper/Dockerfile
echo "a second attacker's file" > tamper/payload.txt
run <<CMD
docker buildx build --platform linux/amd64 --provenance=false --push --progress=quiet -t $REG/bookstore/catalog:lab tamper
D2=\$(docker buildx imagetools inspect $REG/bookstore/catalog:lab --format '{{.Manifest.Digest}}')
echo "tag now points: \$D2"
kubectl delete -n $NS pod catalog-by-digest --wait=true
kubectl apply -n $NS -f by-digest.yaml
kubectl wait -n $NS --for=condition=Ready --timeout=120s pod/catalog-by-digest
echo "running digest: \$(kubectl get pod -n $NS catalog-by-digest -o jsonpath='{.status.containerStatuses[0].imageID}' | sed 's/.*@//')"
CMD
else
echo '## steps 11 and 12 need the throwaway cluster supply-chain, so this run skips them'
echo '## the chapter cites them to upstream and labels them not run'
echo
fi

echo '## step 13: lint two manifests, then ask the restricted namespace to refuse the insecure one'
cat > insecure.yaml <<YAML
# INSECURE ON PURPOSE: a Pod that every manifest linter should refuse. Lab cluster only.
apiVersion: v1
kind: Pod
metadata: {name: catalog-insecure, namespace: $NS}
spec:
  serviceAccountName: catalog
  hostNetwork: true
  containers:
    - name: catalog
      image: $NODE_REG/bookstore/catalog:lab
      securityContext:
        privileged: true
        runAsUser: 0
        allowPrivilegeEscalation: true
YAML
run <<'CMD'
kube-linter lint serviceaccount.yaml insecure.yaml --format plain > lint.txt; st=$?
sed "s|$(pwd)/||g" lint.txt
echo "kube-linter exit=$st"
CMD
run <<'CMD'
kubesec scan insecure.yaml -f json | jq -r '.[0] | "kubesec score \(.score), critical items \((.scoring.critical // []) | length)"'
kubesec scan by-digest.yaml -f json | jq -r '.[0] | "kubesec score \(.score), critical items \((.scoring.critical // []) | length)"'
CMD
run <<'CMD'
trivy config --quiet --severity HIGH,CRITICAL insecure.yaml
trivy config --quiet --severity HIGH,CRITICAL by-digest.yaml
CMD
run <<CMD
kubectl apply -n $NS -f serviceaccount.yaml
CMD
run <<CMD
kubectl apply --dry-run=server -n $NS -f insecure.yaml 2>&1 | head -n 1
CMD
run <<CMD
kubectl apply --dry-run=server -n $NS -f by-digest.yaml
CMD

echo '## step 14: tear down what the lab created'
run <<CMD
kubectl delete ns $NS --wait=true
docker rm -f p05-03-registry
CMD
cd / && rm -rf "$work"
