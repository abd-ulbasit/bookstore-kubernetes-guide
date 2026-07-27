#!/usr/bin/env python3
"""Assert every Pod spec the reader is told to apply declares runAsNonRoot.

Why this exists
---------------
SECURITY-SCAN.md accepts exactly two Trivy `KSV-0012` ("Runs as root user")
findings, on the two frozen Part 00/01 teaching seeds. An acceptance list in
prose rots the moment someone adds a third manifest: the finding count goes
up, nobody notices, and the document quietly becomes a lie. That is the same
class of failure that let a hardcoded scanner path hide a reachable SQL
injection for months.

So the acceptance list is executable. This script fails if:

  * any Pod-bearing workload outside the allowlist omits `runAsNonRoot: true`
    (a new unhardened manifest landed), OR
  * an allowlisted file *gains* `runAsNonRoot` or disappears (the allowlist is
    now stale and SECURITY-SCAN.md needs updating).

Both directions matter. A list that can only be too permissive is not a check.

Sources covered: the raw-manifests tree, the rendered Helm chart, and each
rendered Kustomize overlay — i.e. every path by which the guide hands a
reader something to `kubectl apply`.
"""

from __future__ import annotations

import glob
import subprocess
import sys

import yaml

REPO_PREFIX = "full-guide/examples/bookstore"

# The two Part 00/01 teaching seeds, documented in SECURITY-SCAN.md §1.3.
# They live in `default`, are reproduced verbatim in chapter prose that walks
# them field by field, and Part 01 ch.03 tells the reader they are frozen.
# Hardening is taught as a deliberate increment in Part 05 ch.02.
ALLOWLIST = {
    f"{REPO_PREFIX}/raw-manifests/01-catalog-pod.yaml",
    f"{REPO_PREFIX}/raw-manifests/02-catalog-pod-sidecar.yaml",
}

WORKLOAD_KINDS = {
    "Deployment",
    "StatefulSet",
    "DaemonSet",
    "Job",
    "ReplicaSet",
    "ReplicationController",
}


def pod_spec(doc):
    """Return (podSpec, label) for any doc that carries one, else (None, None)."""
    kind = doc.get("kind")
    meta = doc.get("metadata") or {}
    name = meta.get("name", "<unnamed>")
    try:
        if kind in WORKLOAD_KINDS:
            return doc["spec"]["template"]["spec"], f"{kind}/{name}"
        if kind == "CronJob":
            return (
                doc["spec"]["jobTemplate"]["spec"]["template"]["spec"],
                f"{kind}/{name}",
            )
        if kind == "Pod":
            return doc["spec"], f"{kind}/{name}"
    except (KeyError, TypeError):
        # A malformed workload is a separate problem; other CI jobs (helm lint,
        # kubectl kustomize, mkdocs) will surface it. Don't mask it as a
        # security finding here.
        return None, None
    return None, None


def declares_nonroot(spec) -> bool:
    """True if the Pod, or every one of its containers, sets runAsNonRoot."""
    if (spec.get("securityContext") or {}).get("runAsNonRoot") is True:
        return True
    containers = (spec.get("containers") or []) + (spec.get("initContainers") or [])
    if not containers:
        return False
    return all(
        (c.get("securityContext") or {}).get("runAsNonRoot") is True
        for c in containers
    )


def load_docs(text: str):
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"FAIL — command errored: {' '.join(cmd)}", file=sys.stderr)
        print(result.stderr[-2000:], file=sys.stderr)
        sys.exit(2)
    return result.stdout


def main() -> int:
    # (source label, path-or-None, yaml text)
    sources: list[tuple[str, str | None, str]] = []

    for path in sorted(glob.glob(f"{REPO_PREFIX}/raw-manifests/*.yaml")):
        with open(path, encoding="utf-8") as fh:
            sources.append((path, path, fh.read()))

    sources.append(
        (
            "helm template bookstore",
            None,
            run(["helm", "template", "bookstore", f"{REPO_PREFIX}/helm/bookstore"]),
        )
    )

    for overlay in ("dev", "staging", "prod"):
        sources.append(
            (
                f"kustomize overlay/{overlay}",
                None,
                run(["kubectl", "kustomize", f"{REPO_PREFIX}/kustomize/overlays/{overlay}"]),
            )
        )

    violations: list[str] = []
    allowlist_hits: set[str] = set()
    checked = 0

    for label, path, text in sources:
        for doc in load_docs(text):
            spec, what = pod_spec(doc)
            if spec is None:
                continue
            checked += 1
            if declares_nonroot(spec):
                # An allowlisted file that now declares it means the allowlist
                # is stale — surface that rather than silently passing.
                if path in ALLOWLIST:
                    allowlist_hits.add(path)
                continue
            if path in ALLOWLIST:
                allowlist_hits.add(path)
                continue
            violations.append(f"{label}: {what} does not declare runAsNonRoot")

    print(f"checked {checked} Pod spec(s) across {len(sources)} source(s)")

    stale = ALLOWLIST - allowlist_hits
    hardened_but_listed = {
        p
        for p in allowlist_hits
        if all(
            declares_nonroot(spec)
            for spec, _ in (
                pod_spec(d) for d in load_docs(open(p, encoding="utf-8").read())
            )
            if spec is not None
        )
    }

    ok = True

    if violations:
        ok = False
        print("\nFAIL — Pod spec(s) without runAsNonRoot that are not accepted:")
        for v in violations:
            print(f"  {v}")
        print(
            "\nEither declare runAsNonRoot, or add the file to ALLOWLIST here "
            "AND document the reason in SECURITY-SCAN.md §1.3."
        )

    if stale:
        ok = False
        print("\nFAIL — allowlisted file(s) no longer present / carry no Pod spec:")
        for p in sorted(stale):
            print(f"  {p}")
        print("\nRemove them from ALLOWLIST and from SECURITY-SCAN.md §1.3.")

    if hardened_but_listed:
        ok = False
        print("\nFAIL — allowlisted file(s) now declare runAsNonRoot:")
        for p in sorted(hardened_but_listed):
            print(f"  {p}")
        print("\nGood news, but the acceptance in SECURITY-SCAN.md §1.3 is now")
        print("stale. Drop them from ALLOWLIST and update the doc.")

    if ok:
        print(
            f"OK — every Pod spec declares runAsNonRoot except the "
            f"{len(ALLOWLIST)} documented teaching seed(s)."
        )

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
