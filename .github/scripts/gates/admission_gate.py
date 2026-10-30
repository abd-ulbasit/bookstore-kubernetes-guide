#!/usr/bin/env python3
"""G3: the admission gate.

Server-side dry-runs every applyable block from G1 into a namespace that
enforces and warns at the `restricted` Pod Security level, and reports what
the API server said:

pass         accepted with no Pod Security complaint.
violation    rejected for violating Pod Security, or accepted with a warning
             that says it would. A Deployment that breaks `restricted` is
             admitted with only a warning and exit 0 (its ReplicaSet is the
             one that cannot create Pods), so a warning counts as a violation.
missing-crd  the cluster has no such kind. The block was not evaluated.
error        any other failure, for example an invalid field.

Insecure-on-purpose blocks are skipped. Unparseable blocks cannot be applied
and count as failures when in scope.

Before it trusts any result the gate dry-runs the two control fixtures and
exits 2 unless the violating one is a `violation` and the hardened one a
`pass`. A cluster that does not enforce Pod Security therefore stops the run
instead of passing every block.

Exit codes: 0 no in-scope violation, error or unparseable block, 1 at least
one, 2 the control check or the cluster could not be trusted. Blocks outside
--scope are reported only; with no --scope everything is in scope. The
ambient kubeconfig is used; the kubectl binary comes from --kubectl, the
KUBECTL environment variable, or PATH.

Usage:
    admission_gate.py --manifest M --scope CHAPTER [--scope ...]
                      [--report OUT.json]
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

import yaml

import extract_blocks as eb
from static_gate import FIXTURES, ControlError, check_scopes, in_scope

NAMESPACE = "gate-restricted"
PSA_LABELS = {
    "pod-security.kubernetes.io/enforce": "restricted",
    "pod-security.kubernetes.io/warn": "restricted",
}

PASS, VIOLATION, MISSING_CRD, ERROR = "pass", "violation", "missing-crd", "error"
SKIPPED, UNPARSEABLE = "skipped-insecure", "unparseable"

_PSA = re.compile(r"violat\w*\s+PodSecurity", re.IGNORECASE)
_NO_CRD = re.compile(
    r"no matches for kind|ensure CRDs are installed first"
    r"|the server could not find the requested resource",
    re.IGNORECASE,
)


def classify_output(rc: int, out: str) -> str:
    """Classify one dry-run from kubectl's exit code and combined output."""
    if _PSA.search(out):
        return VIOLATION
    if rc != 0:
        return MISSING_CRD if _NO_CRD.search(out) else ERROR
    return PASS


def retarget(docs: list[dict], ns: str, cluster_scoped: set[str]) -> list[dict]:
    """Return copies of docs placed in ns, leaving cluster-scoped kinds alone."""
    out = []
    for doc in docs:
        doc = copy.deepcopy(doc)
        if doc.get("kind") not in cluster_scoped:
            if not isinstance(doc.get("metadata"), dict):
                doc["metadata"] = {}
            doc["metadata"]["namespace"] = ns
        out.append(doc)
    return out


def kubectl_run(kubectl: str, args: list[str], stdin: str | None = None) -> tuple[int, str]:
    """Run kubectl; return (exit code, stdout and stderr together)."""
    try:
        proc = subprocess.run(
            [kubectl, *args], input=stdin, capture_output=True, text=True, timeout=120, check=False
        )
    except subprocess.TimeoutExpired:
        return 124, "kubectl timed out after 120 seconds"
    except OSError as exc:
        raise ControlError(f"cannot run kubectl: {exc}") from exc
    return proc.returncode, proc.stdout + proc.stderr


def cluster_scoped_kinds(kubectl: str) -> set[str]:
    rc, out = kubectl_run(kubectl, ["api-resources", "--namespaced=false", "--no-headers"])
    kinds = {line.split()[-1] for line in out.splitlines() if line.split()}
    if rc != 0 or not kinds:
        raise ControlError(f"cannot list cluster-scoped kinds (exit {rc}): {out.strip()[:300]}")
    return kinds


def ensure_namespace(kubectl: str) -> None:
    manifest = {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {"name": NAMESPACE, "labels": PSA_LABELS},
    }
    rc, out = kubectl_run(kubectl, ["apply", "-f", "-"], yaml.safe_dump(manifest))
    if rc != 0:
        raise ControlError(f"cannot create namespace {NAMESPACE}: {out.strip()[:300]}")


def dry_run(kubectl: str, body: str, cluster_scoped: set[str]) -> tuple[str, str]:
    """Server-side dry-run a block body in the gate namespace; return (status, output)."""
    docs = [d for d in yaml.safe_load_all(body) if isinstance(d, dict)]
    payload = yaml.safe_dump_all(retarget(docs, NAMESPACE, cluster_scoped), sort_keys=False)
    rc, out = kubectl_run(
        kubectl, ["apply", "--dry-run=server", "--validate=strict", "-f", "-"], payload
    )
    return classify_output(rc, out), out


def check_control(kubectl: str, cluster_scoped: set[str]) -> None:
    """Abort unless the violating fixture is a violation and the hardened one passes."""
    expected = {"violating-deployment.yaml": VIOLATION, "hardened-deployment.yaml": PASS}
    for name, want in expected.items():
        body = (FIXTURES / name).read_text(encoding="utf-8")
        got, out = dry_run(kubectl, body, cluster_scoped)
        if got != want:
            raise ControlError(
                f"control fixture {name} came back {got!r}, expected {want!r}; "
                f"the cluster is not enforcing Pod Security as the gate needs. "
                f"Output: {out.strip()[:300]}"
            )


def judge(block: eb.Block, kubectl: str, cluster_scoped: set[str]) -> tuple[str, str]:
    if block.klass == eb.INSECURE:
        return SKIPPED, ""
    if block.klass == eb.UNPARSEABLE:
        return UNPARSEABLE, ""
    return dry_run(kubectl, Path(block.path).read_text(encoding="utf-8"), cluster_scoped)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--scope", action="append", default=[], metavar="CHAPTER")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--kubectl", default=os.environ.get("KUBECTL", "kubectl"))
    args = parser.parse_args(argv)

    blocks = eb.load_manifest(args.manifest)
    try:
        check_scopes(blocks, args.scope)
        cluster_scoped = cluster_scoped_kinds(args.kubectl)
        ensure_namespace(args.kubectl)
        check_control(args.kubectl, cluster_scoped)
    except ControlError as exc:
        print(f"admission gate aborted: {exc}", file=sys.stderr)
        return 2

    rows = []
    for block in blocks:
        status, out = judge(block, args.kubectl, cluster_scoped)
        rows.append(
            {
                "chapter": block.chapter,
                "index": block.index,
                "line": block.line,
                "klass": block.klass,
                "kinds": block.kinds,
                "status": status,
                "detail": out.strip()[:600],
                "in_scope": in_scope(block.chapter, args.scope),
            }
        )

    counts = Counter(r["status"] for r in rows)
    scoped = [r for r in rows if r["in_scope"]]
    failing = {VIOLATION, ERROR, UNPARSEABLE}
    for row in scoped:
        if row["status"] in failing | {MISSING_CRD}:
            first = row["detail"].splitlines()[0] if row["detail"] else ""
            print(f"{row['status']:<12} {row['chapter']}:{row['line']}  {first[:110]}")
    order = (PASS, VIOLATION, MISSING_CRD, ERROR, UNPARSEABLE, SKIPPED)
    print(
        "admission gate: " + ", ".join(f"{counts[s]} {s}" for s in order)
        + f" ({len(scoped)} of {len(rows)} blocks in scope)"
    )  # fmt: skip
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        summary = {"blocks": len(rows), "by_status": dict(counts), "in_scope": len(scoped)}
        args.report.write_text(
            json.dumps({"summary": summary, "blocks": rows}, indent=2) + "\n", encoding="utf-8"
        )
    return 1 if any(r["status"] in failing for r in scoped) else 0


if __name__ == "__main__":
    sys.exit(main())
