#!/usr/bin/env bash
# Lab 05.03, VEX step: a not_affected statement that suppresses one finding.
# No cluster is needed.
#
# Run this from the guide's full-guide/ directory. Its output is appended to
# the chapter's transcript as step 7b. It scans the Go module list of the
# Bookstore's catalog service, not the image, so the SBOM here is a module
# list with no operating system packages. That is enough to show the VEX
# mechanism on a real finding. Needs syft, trivy, jq, go and govulncheck.
#
# The statement says the vulnerable code is not in the execute path. That claim
# is only worth making with evidence, so the script first asks govulncheck
# whether the catalog calls the advisory's vulnerable function.
set +e

APP=examples/bookstore/app/catalog
ADVISORY=GO-2026-5024
CVE=CVE-2026-39824

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

[ -f "$APP/go.mod" ] || { echo "run this from the guide's full-guide/ directory" >&2; exit 2; }
work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT
export APP ADVISORY CVE work

echo '## step 7b: a not_affected statement, backed by a reachability check'
run <<'CMD'
syft dir:"$APP" -q -o cyclonedx-json="$work/catalog.cdx.json"
jq -r '[.components[].type] | group_by(.) | map("\(.[0]) \(length)")[]' "$work/catalog.cdx.json"
CMD
run <<'CMD'
trivy sbom --quiet --format json --scanners vuln "$work/catalog.cdx.json" |
  jq -r '.Results[]?.Vulnerabilities[]? | .VulnerabilityID + " " + .PkgName + " " + .InstalledVersion + " " + .Severity'
CMD
run <<'CMD'
(cd "$APP" && govulncheck -format json ./... |
  jq -r --arg id "$ADVISORY" 'select(.finding.osv == $id) | .finding.trace[0] | if .function then "symbol" elif .package then "package" else "module" end' |
  sort | uniq -c)
CMD
run <<'CMD'
(cd "$APP" && govulncheck -format json ./... |
  jq -r --arg id "$ADVISORY" 'select(.osv.id == $id) | .osv.summary')
CMD

P=$(jq -r '.components[] | select(.name=="golang.org/x/sys") | .purl' "$work/catalog.cdx.json")
export P
cat > "$work/vex.json" <<JSON
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://example.invalid/vex/p05-catalog-lab-not-affected",
  "author": "05.03 lab",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": 1,
  "statements": [
    {
      "vulnerability": {"name": "$CVE"},
      "products": [{"@id": "$P"}],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path",
      "impact_statement": "govulncheck finds the advisory only at module level: the catalog never calls the vulnerable function, which is in the Windows-only package."
    }
  ]
}
JSON
run <<'CMD'
jq -r '.statements[] | .status + " " + .justification + " " + .vulnerability.name' "$work/vex.json"
CMD
run <<'CMD'
echo "trivy without a statement: $(trivy sbom --quiet --format json --scanners vuln "$work/catalog.cdx.json" | jq '[.Results[]?.Vulnerabilities[]?] | length') finding(s)"
CMD
run <<'CMD'
echo "trivy with the not_affected statement: $(trivy sbom --quiet --format json --scanners vuln --vex "$work/vex.json" "$work/catalog.cdx.json" | jq '[.Results[]?.Vulnerabilities[]?] | length') finding(s)"
CMD
echo '## done'
