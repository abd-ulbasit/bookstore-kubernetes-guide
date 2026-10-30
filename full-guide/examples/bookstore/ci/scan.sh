#!/usr/bin/env bash
# Run one pipeline scanner from a pinned container image, the same way the
# pipeline does (07.03). Run it from the repository root.
#
#   ci/scan.sh [--expect ID] TOOL [TARGET]
#
# Without --expect the script exits non-zero when the scanner flags the
# target. With --expect ID it is a control: it exits 0 only when the scanner
# flags the target AND its report contains ID, so a scanner that went quiet,
# crashed or changed its rule IDs fails the control instead of passing it.
# Only the control mode relaxes the scanner, and only where the planted
# secrets must be found (see the notes on gitleaks and trufflehog).
#
# TOOL is one of: gitleaks trufflehog semgrep gosec govulncheck trivy-fs
# trivy-config trivy-image trivy-sbom hadolint dockle syft grype kube-linter
# kubesec zizmor actionlint zap. TARGET defaults to "." and is a path under the
# repository root; for the image tools it is the path of a `docker save` tar,
# and for zap it is the URL of a service already running on this host.
#
# Reports land in $REPORT_DIR (default scan-reports/). Every image below is
# pinned by digest; the tag in the comment is the release it was resolved
# from. Bump a tool by resolving the new tag's digest and changing both.
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-scan-reports}"
EXPECT=""
if [ "${1:-}" = "--expect" ]; then
  EXPECT="${2:?--expect needs an ID}"
  shift 2
fi
TOOL="${1:?usage: scan.sh [--expect ID] TOOL [TARGET]}"
TARGET="${2:-.}"

# Tag in the comment, digest in the reference.
GITLEAKS=ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f   # v8.30.1
TRUFFLEHOG=ghcr.io/trufflesecurity/trufflehog@sha256:bf9238f5bdf26ac28230d4b0bae5162a752b151bf10bea612dad7a62da938731 # 3.99.4
SEMGREP=semgrep/semgrep@sha256:529ee8a277ec8adc5b534d7c74eea0a47e9de21d62852b6ba7ac6ba9566845c3              # 1.180.0
GOLANG=golang@sha256:a2012b4a1d1f9f7e9f44e0d39b805a901e856b1dd80b4e6ee4338db547050308                       # 1.26.10-alpine
TRIVY=ghcr.io/aquasecurity/trivy@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c    # 0.76.1
HADOLINT=ghcr.io/hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d    # v2.15.1
DOCKLE=goodwithtech/dockle@sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9           # v0.4.15
SYFT=ghcr.io/anchore/syft@sha256:4cc92b64ca74ffca4c94d4c8fcc01f217731375300be14d0b6eeb2e82eaa110a             # v1.55.0
GRYPE=ghcr.io/anchore/grype@sha256:621d56d1d68106b787022c81546f7e0a36202a25d1239f0c20195fab8c16f7ea           # v0.121.0
KUBE_LINTER=ghcr.io/stackrox/kube-linter@sha256:f2bfce7879206d32f69ab6572c376f916643f54ca291ac38cf7d01ef591ff3f9 # v0.8.3
KUBESEC=kubesec/kubesec@sha256:6735b7f3d1c8b3abde5c6e49d260759e90693a70d699f9d44bec9ef4ccc8b995               # v2.15.0
ZIZMOR=ghcr.io/zizmorcore/zizmor@sha256:42d409dbb851d4c5d35a058cf042b828bea1e3f2884378c526eb0974780e18d9      # 1.31.1
ACTIONLINT=rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667            # 1.7.12
ZAP=ghcr.io/zaproxy/zaproxy@sha256:030d3df57735dacbb83464854758e674dd9ad01d79d12a129a8e58b1fd384238            # 2.17.0
GOSEC_VERSION=v2.30.0
GOVULNCHECK_VERSION=v1.9.0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$PWD"
rules_dir="$here/semgrep"
mkdir -p "$REPORT_DIR"
out="$(cd "$REPORT_DIR" && pwd)"
# The tool caches (the Trivy and Grype databases, the Go build cache) live in
# named volumes, so a second run on the same machine does not fetch them again.
cache=(-v scan-cache-trivy:/root/.cache)
gocache=(-v scan-cache-go:/gocache -e GOCACHE=/gocache/build -e GOPATH=/gocache/path)

# Run a container with the repository read-only at /src and the reports
# writable at /out. Extra docker flags come before the image.
run() { docker run --rm -v "$root:/src:ro" -v "$out:/out" "$@"; }

# Every function sets REPORT to the file the verdict should search and
# returns the scanner's own exit code.
REPORT=""
rc=0

# Go tools run from the golang image. Modules are fetched at run time and
# checked against the Go checksum database, so a version pin is a content pin.
gorun() {
  run -w "/src/$TARGET" -e HOME=/tmp "${gocache[@]}" \
    -e GOTOOLCHAIN=local -e GOFLAGS=-buildvcs=false -e CGO_ENABLED=0 \
    "$GOLANG" sh -c "$1"
}

case "$TOOL" in
  gitleaks|trufflehog|semgrep|gosec|govulncheck|trivy-fs|trivy-config|trivy-image|trivy-sbom|hadolint|dockle|syft|grype|kube-linter|kubesec|zizmor|actionlint|zap) ;;
  *) echo "scan.sh: unknown tool '$TOOL'" >&2; exit 64 ;;
esac

# The scanners are chatty. Their output goes to $REPORT_DIR/$TOOL.log, and
# this script prints one verdict line.
{
case "$TOOL" in
  gitleaks)
    # The repo's allowlist applies to real scans only. A control must see the
    # planted fake token, so it runs on the default rules.
    cfg=()
    if [ -z "$EXPECT" ] && [ -f "$root/.gitleaks.toml" ]; then cfg=(--config /src/.gitleaks.toml); fi
    REPORT="$out/gitleaks.json"
    # Run from /src with a relative target, so the allowlist's path patterns
    # see repo-relative paths, as they do in the full-history scan.
    run -w /src "$GITLEAKS" dir --no-banner --redact --exit-code 1 "${cfg[@]}" \
      --report-format json --report-path /out/gitleaks.json "$TARGET" || rc=$?
    ;;
  trufflehog)
    # Verified mode reports only credentials that still work, which is why it
    # can gate a pipeline with almost no false positives. A fake token never
    # verifies, so the control turns verification off to prove the detectors
    # still match.
    mode=(--results=verified)
    if [ -n "$EXPECT" ]; then mode=(--no-verification --results=unverified,unknown); fi
    REPORT="$out/trufflehog.json"
    run "$TRUFFLEHOG" filesystem "/src/$TARGET" --no-update --fail --json "${mode[@]}" \
      >"$REPORT" 2>"$out/trufflehog.log" || rc=$?
    ;;
  semgrep)
    REPORT="$out/semgrep.json"
    run -v "$rules_dir:/rules:ro" -e SEMGREP_SEND_METRICS=off "$SEMGREP" semgrep scan \
      --config /rules --metrics=off --disable-version-check --error --quiet \
      --json --output /out/semgrep.json "/src/$TARGET" || rc=$?
    ;;
  gosec)
    REPORT="$out/gosec.json"
    gorun "go run github.com/securego/gosec/v2/cmd/gosec@${GOSEC_VERSION} -fmt=json -out=/out/gosec.json ./..." || rc=$?
    ;;
  govulncheck)
    REPORT="$out/govulncheck.txt"
    gorun "go run golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION} ./... >/out/govulncheck.txt 2>&1" || rc=$?
    ;;
  trivy-fs)
    REPORT="$out/trivy-fs.json"
    run "${cache[@]}" "$TRIVY" fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --quiet \
      --format json --output /out/trivy-fs.json "/src/$TARGET" || rc=$?
    ;;
  trivy-config)
    # Fail on any HIGH or CRITICAL finding, and on the five checks that make up
    # the baseline whatever their severity: KSV-0012 (root), KSV-0014 (writable
    # root filesystem), KSV-0001 (privilege escalation), KSV-0003 (capabilities
    # not dropped) and KSV-0030 (no seccomp profile).
    REPORT="$out/trivy-config.json"
    run "${cache[@]}" "$TRIVY" config --severity LOW,MEDIUM,HIGH,CRITICAL --exit-code 0 --quiet \
      --format json --output /out/trivy-config.json "/src/$TARGET" || rc=$?
    if [ "$rc" -eq 0 ] && grep -qE '"Severity": "(HIGH|CRITICAL)"|"ID": "KSV-(0012|0014|0001|0003|0030)"' "$REPORT"; then rc=1; fi
    ;;
  trivy-image)
    # ignore-unfixed: a rebuild cannot remediate a CVE with no fix, so gating
    # on it blocks every build for nothing. The weekly rescan catches the day
    # a fix lands.
    REPORT="$out/trivy-image.json"
    run -v "$here:/ci:ro" "${cache[@]}" "$TRIVY" image --input "/src/$TARGET" --severity HIGH,CRITICAL --ignore-unfixed \
      --ignorefile /ci/trivyignore.yaml --exit-code 1 --quiet --format json --output /out/trivy-image.json || rc=$?
    ;;
  trivy-sbom)
    REPORT="$out/trivy-sbom.json"
    run -v "$here:/ci:ro" "${cache[@]}" "$TRIVY" sbom "/src/$TARGET" --severity HIGH,CRITICAL --ignore-unfixed \
      --ignorefile /ci/trivyignore.yaml --exit-code 1 --quiet --format json --output /out/trivy-sbom.json || rc=$?
    ;;
  hadolint)
    REPORT="$out/hadolint.json"
    run "$HADOLINT" /bin/hadolint --failure-threshold warning --format json "/src/$TARGET" >"$REPORT" || rc=$?
    ;;
  dockle)
    REPORT="$out/dockle.json"
    # KEY_SHA512 is a shell variable in the nginx image's build script, the
    # checksum of nginx's public signing key. Dockle reads the name as a secret.
    run "$DOCKLE" --input "/src/$TARGET" --exit-code 1 --exit-level warn --accept-key KEY_SHA512 \
      --format json --output /out/dockle.json || rc=$?
    ;;
  syft)
    # Generates the SBOM; Grype and Trivy read it. It flags nothing itself,
    # so there is no control for it: a broken SBOM fails the two that follow.
    REPORT="$out/sbom.cdx.json"
    run "$SYFT" "docker-archive:/src/$TARGET" -o cyclonedx-json=/out/sbom.cdx.json -q || rc=$?
    ;;
  grype)
    REPORT="$out/grype.json"
    # The image sets no HOME, so Grype would fetch its database on every run
    # unless the cache directory is named.
    run -v scan-cache-grype:/cache -v "$here:/ci:ro" -e GRYPE_DB_CACHE_DIR=/cache "$GRYPE" "sbom:/src/$TARGET" -c /ci/grype.yaml --only-fixed \
      --fail-on high -o json --file /out/grype.json -q || rc=$?
    ;;
  kube-linter)
    REPORT="$out/kube-linter.json"
    run -v "$here:/ci:ro" "$KUBE_LINTER" lint --config /ci/kube-linter.yaml --format json "/src/$TARGET" >"$REPORT" || rc=$?
    ;;
  kubesec)
    # kubesec scores workloads ("Passed with a score of N points") and says
    # "could not find schema" for every other kind, so its own exit code is
    # useless on a whole overlay. The gate is a workload that fails.
    REPORT="$out/kubesec.json"
    run "$KUBESEC" scan --exit-code 0 "/src/$TARGET" >"$REPORT" || rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'Failed with a score' "$REPORT"; then rc=1; fi
    ;;
  zizmor)
    # TARGET may name several workflow files or directories, separated by spaces.
    read -ra paths <<<"$TARGET"
    REPORT="$out/zizmor.txt"
    run -w /src "$ZIZMOR" --offline --no-progress "${paths[@]}" >"$REPORT" 2>&1 || rc=$?
    ;;
  actionlint)
    read -ra paths <<<"$TARGET"
    REPORT="$out/actionlint.txt"
    run -w /src "$ACTIONLINT" "${paths[@]}" >"$REPORT" 2>&1 || rc=$?
    ;;
  zap)
    # The baseline is passive: it crawls the URL and reads the responses, and
    # sends no attack traffic. The ZAP user must be able to write the reports.
    chmod 0777 "$out"
    REPORT="$out/zap.json"
    docker run --rm --network host -v "$out:/zap/wrk:rw" -v "$here/zap:/zap/conf:ro" "$ZAP" \
      zap-baseline.py -t "$TARGET" -c /zap/conf/baseline.conf -J zap.json -r zap.html || rc=$?
    ;;
esac
} >"$out/$TOOL.log" 2>&1

if [ -z "$EXPECT" ]; then
  [ "$rc" -eq 0 ] && echo "scan.sh: $TOOL clean on $TARGET" || echo "scan.sh: $TOOL flagged $TARGET (exit $rc, report ${REPORT#"$root"/})" >&2
  exit "$rc"
fi

if [ "$rc" -eq 0 ]; then
  echo "scan.sh: control FAILED, $TOOL reported nothing on $TARGET" >&2
  exit 1
fi
if ! grep -qF -- "$EXPECT" "$REPORT" 2>/dev/null; then
  echo "scan.sh: control FAILED, $TOOL flagged $TARGET (exit $rc) but its report has no $EXPECT" >&2
  exit 1
fi
echo "scan.sh: control ok, $TOOL reported $EXPECT on $TARGET"
