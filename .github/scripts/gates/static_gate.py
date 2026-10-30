#!/usr/bin/env python3
"""G2 and the marker half of G5: the static gate.

Runs `trivy config` over the blocks G1 extracted and judges each one:

pass           a workload carrying the baseline, or a block with nothing
               to flag. Every document in it is a kind this gate understands
               and is complete enough for Trivy to read.
fail           a workload missing a core check, any HIGH or CRITICAL finding,
               a block that cannot be parsed, or a marked block without its
               banner.
stale-marker   an insecure-on-purpose block that no longer fails anything.
not-evaluated  the block holds a kind Trivy has no check for (a Rollout, a
               custom resource), or a document Trivy would skip (no
               apiVersion or metadata, a workload with no containers).
               Trivy reports such a file as clean, so a clean result there
               means nothing and is never a pass.

The gate does not trust a quiet scanner. Before reading any result it scans
two control fixtures beside the real files and aborts with exit code 2
unless the violating one trips all five core checks and the hardened one
trips none. A renamed check ID, an empty result or a missing check bundle
therefore stops the run instead of reading as a pass.

Exit codes: 0 every in-scope block passes or is not evaluated, 1 an in-scope
block fails or has a stale marker, 2 the control check or the scanner failed.
Not-evaluated blocks are always listed and counted apart from passes.
Blocks outside --scope are reported only. With no --scope everything is in
scope.

Usage:
    static_gate.py --manifest M --scope CHAPTER [--scope ...]
                   [--also PATH ...] [--report OUT.json]
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import yaml

import extract_blocks as eb

CORE = ("KSV-0012", "KSV-0014", "KSV-0001", "KSV-0003", "KSV-0030")

WORKLOAD_KINDS = ("Pod", "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet")

# Kinds the Trivy v0.76.1 check bundle selects besides workloads (the
# `subtypes` of its kubernetes checks): RBAC, ConfigMap, Service and quotas.
CHECKED_KINDS = frozenset(
    {
        "Role",
        "ClusterRole",
        "RoleBinding",
        "ClusterRoleBinding",
        "ConfigMap",
        "Service",
        "ResourceQuota",
        "LimitRange",
    }
)

# Built-in kinds that carry no pod template. Trivy has no check for them, but
# there is nothing hidden in them either, so a block of only these can pass.
INERT_KINDS = frozenset(
    {
        "Namespace",
        "ServiceAccount",
        "Secret",
        "NetworkPolicy",
        "Ingress",
        "IngressClass",
        "PersistentVolume",
        "PersistentVolumeClaim",
        "StorageClass",
        "PriorityClass",
        "RuntimeClass",
        "PodDisruptionBudget",
        "HorizontalPodAutoscaler",
        "Endpoints",
        "EndpointSlice",
        "CustomResourceDefinition",
        "ValidatingAdmissionPolicy",
        "ValidatingAdmissionPolicyBinding",
        "MutatingAdmissionPolicy",
        "MutatingAdmissionPolicyBinding",
    }
)

KNOWN_KINDS = frozenset(WORKLOAD_KINDS) | CHECKED_KINDS | INERT_KINDS

SEVERITIES = "LOW,MEDIUM,HIGH,CRITICAL"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
CONTROL_VIOLATING = "gate-control-violating.yaml"
CONTROL_HARDENED = "gate-control-hardened.yaml"

PASS, FAIL, STALE, NOT_EVALUATED = "pass", "fail", "stale-marker", "not-evaluated"


class ControlError(Exception):
    """The gate cannot trust its own scanner or scope; the run exits 2."""


@dataclass
class Scan:
    failed: set[str]  # every check ID that failed, LOW to CRITICAL
    high_crit: set[str]  # the failed IDs of HIGH or CRITICAL severity
    seen: bool  # Trivy returned a result entry for this file


def verdict(block: eb.Block, failed: set[str], high_crit: set[str]) -> tuple[str, list[str]]:
    """Judge one block from Trivy's findings; return (status, check IDs or kinds).

    A block holding any workload is judged as a workload, wherever in the
    block it sits, so a Role beside a Pod cannot hide the Pod.
    """
    if block.klass == eb.UNPARSEABLE:
        return FAIL, ["unparseable"]
    is_workload = bool(set(block.kinds) & set(WORKLOAD_KINDS))
    core = [i for i in CORE if is_workload and i in failed]
    problems = core + sorted(set(high_crit) - set(core))
    unknown = [k for k in dict.fromkeys(block.kinds) if k not in KNOWN_KINDS]
    if block.klass == eb.INSECURE:
        if problems:
            return PASS, problems
        return (NOT_EVALUATED, unknown) if unknown else (STALE, [])
    if problems:
        return FAIL, problems
    if unknown:
        return NOT_EVALUATED, unknown
    return PASS, []


def banner_ok(body: str) -> bool:
    """True if the block opens with `# INSECURE ON PURPOSE: ... Lab cluster only.`"""
    comment = []
    for line in body.splitlines():
        if not line.strip() and not comment:
            continue
        if not line.lstrip().startswith("#"):
            break
        comment.append(line.lstrip().lstrip("#").strip())
    text = " ".join(comment)
    return text.startswith("INSECURE ON PURPOSE:") and "Lab cluster only." in text


def _pod_spec(doc: dict):
    """Return the pod spec of a workload document, or None."""
    node = doc.get("spec")
    if doc["kind"] == "Pod":
        return node
    path = ("jobTemplate", "spec", "template", "spec") if doc["kind"] == "CronJob" else ("template", "spec")
    for key in path:
        node = node.get(key) if isinstance(node, dict) else None
    return node


def incomplete_documents(body: str) -> list[str]:
    """List documents Trivy would skip or call clean without reading a container.

    Trivy ignores a document with no apiVersion or metadata, and a workload
    with no containers has nothing to fail. Either way the file reads clean,
    so the verdict must not call the block a pass.
    """
    gaps = []
    for doc in yaml.safe_load_all(body):
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if kind not in WORKLOAD_KINDS and kind not in CHECKED_KINDS:
            continue
        if not isinstance(doc.get("apiVersion"), str):
            gaps.append(f"{kind}: no apiVersion")
        elif not isinstance(doc.get("metadata"), dict):
            gaps.append(f"{kind}: no metadata")
        elif kind in WORKLOAD_KINDS:
            spec = _pod_spec(doc)
            containers = spec.get("containers") if isinstance(spec, dict) else None
            if not containers:
                gaps.append(f"{kind}: no containers")
    return gaps


def in_scope(chapter: str, scopes: list[str]) -> bool:
    """True if the chapter equals a scope or sits under a scope directory."""
    if not scopes:
        return True
    return any(chapter == s or chapter.startswith(s + "/") for s in map(_norm_scope, scopes))


def _norm_scope(scope: str) -> str:
    scope = scope.strip()
    while scope.startswith("./"):
        scope = scope[2:]
    return scope.rstrip("/")


def check_scopes(blocks: list[eb.Block], scopes: list[str]) -> None:
    """A scope that selects nothing would pass vacuously, so refuse it."""
    for scope in scopes:
        if not any(in_scope(b.chapter, [scope]) for b in blocks):
            raise ControlError(
                f"scope {scope!r} matches no extracted block "
                "(a typo, or a chapter with no manifest)"
            )


def trivy_scan(directory: Path, trivy: str = "trivy") -> dict[str, Scan]:
    """Run trivy config over a directory; return a Scan per reported file.

    Trivy runs with the directory as its working directory, so a stray
    .trivyignore or trivy.yaml in the caller's tree cannot silence findings.
    """
    cmd = [
        trivy, "config", "--quiet", "--format", "json",
        "--severity", SEVERITIES, "--include-non-failures", ".",
    ]  # fmt: skip
    try:
        proc = subprocess.run(cmd, cwd=directory, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise ControlError(f"cannot run trivy: {exc}") from exc
    if proc.returncode != 0:
        raise ControlError(f"trivy exited {proc.returncode}: {proc.stderr.strip()[:500]}")
    try:
        report = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise ControlError(f"trivy printed no JSON: {exc}") from exc
    scans: dict[str, Scan] = {}
    for result in report.get("Results") or []:
        scan = scans.setdefault(result["Target"], Scan(set(), set(), True))
        for finding in result.get("Misconfigurations") or []:
            if finding.get("Status") != "FAIL":
                continue
            scan.failed.add(finding["ID"])
            if finding.get("Severity") in ("HIGH", "CRITICAL"):
                scan.high_crit.add(finding["ID"])
    return scans


def check_control(scans: dict[str, Scan]) -> None:
    """Abort unless the violating fixture trips every core check and the hardened none."""
    violating = scans.get(CONTROL_VIOLATING)
    if violating is None or not violating.seen:
        raise ControlError("the scanner returned nothing for the violating control fixture")
    missing = [i for i in CORE if i not in violating.failed]
    if missing:
        raise ControlError(
            "the violating control fixture no longer trips " + ", ".join(missing)
            + " (check IDs renamed or removed, or the check bundle is missing)"
        )  # fmt: skip
    hardened = scans.get(CONTROL_HARDENED)
    if hardened is None or not hardened.seen:
        raise ControlError("the scanner returned nothing for the hardened control fixture")
    tripped = [i for i in CORE if i in hardened.failed]
    if tripped:
        raise ControlError("the hardened control fixture trips " + ", ".join(tripped))


def scan_files(files: list[Path], trivy: str = "trivy") -> dict[Path, Scan]:
    """Scan files together with both control fixtures; abort if the control fails."""
    with tempfile.TemporaryDirectory(prefix="static-gate-") as tmp:
        scan_dir = Path(tmp)
        names: dict[Path, str] = {}
        for i, path in enumerate(files):
            names[path] = f"{i:05d}__{path.name}"
            shutil.copyfile(path, scan_dir / names[path])
        shutil.copyfile(FIXTURES / "violating-deployment.yaml", scan_dir / CONTROL_VIOLATING)
        shutil.copyfile(FIXTURES / "hardened-deployment.yaml", scan_dir / CONTROL_HARDENED)
        scans = trivy_scan(scan_dir, trivy)
    check_control(scans)
    return {path: scans.get(name, Scan(set(), set(), False)) for path, name in names.items()}


def _also_blocks(paths: list[str]) -> list[eb.Block]:
    """Turn the files under --also paths into blocks that count as in scope."""
    blocks = []
    for given in paths:
        root = Path(given)
        files = [root] if root.is_file() else sorted(
            p for p in root.rglob("*") if p.suffix in (".yaml", ".yml")
        )  # fmt: skip
        for path in files:
            body = path.read_text(encoding="utf-8")
            if not eb.top_level_kinds(body):
                continue
            klass, kinds = eb.classify(body, False)
            blocks.append(eb.Block(path.as_posix(), 0, 1, klass, kinds, str(path.resolve())))
    return blocks


def judge(block: eb.Block, scan: Scan) -> tuple[str, list[str]]:
    """Verdict plus the two guards that need the file: banner and silent scanner."""
    if block.klass == eb.UNPARSEABLE:
        return verdict(block, scan.failed, scan.high_crit)
    if block.klass == eb.INSECURE:
        if not banner_ok(Path(block.path).read_text(encoding="utf-8")):
            return FAIL, ["missing-banner"]
    if not scan.seen:
        return NOT_EVALUATED, ["no-scanner-result"]
    status, ids = verdict(block, scan.failed, scan.high_crit)
    if status in (PASS, STALE) and not ids:
        gaps = incomplete_documents(Path(block.path).read_text(encoding="utf-8"))
        if gaps:
            return NOT_EVALUATED, gaps
    return status, ids


def chapter_stats(rows: list[dict]) -> dict[str, int]:
    """Count chapters holding a workload, and those failing all five core checks."""
    failed_core: dict[str, set[str]] = {}
    for row in rows:
        if set(row["kinds"]) & set(WORKLOAD_KINDS) and row["klass"] == eb.APPLYABLE:
            failed_core.setdefault(row["chapter"], set()).update(row["core_failed"])
    return {
        "chapters_with_workload": len(failed_core),
        "chapters_failing_all_core": sum(1 for ids in failed_core.values() if ids >= set(CORE)),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--scope", action="append", default=[], metavar="CHAPTER")
    parser.add_argument("--also", action="extend", nargs="+", default=[], metavar="PATH")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)

    blocks = eb.load_manifest(args.manifest)
    try:
        check_scopes(blocks, args.scope)
        also = _also_blocks(args.also)
        scans = scan_files([Path(b.path) for b in blocks + also])
    except ControlError as exc:
        print(f"static gate aborted: {exc}", file=sys.stderr)
        return 2

    rows = []
    for block, explicit in [(b, False) for b in blocks] + [(b, True) for b in also]:
        scan = scans[Path(block.path)]
        status, ids = judge(block, scan)
        rows.append(
            {
                "chapter": block.chapter,
                "index": block.index,
                "line": block.line,
                "klass": block.klass,
                "kinds": block.kinds,
                "status": status,
                "ids": ids,
                "core_failed": [i for i in CORE if i in scan.failed],
                "in_scope": explicit or in_scope(block.chapter, args.scope),
            }
        )

    counts = Counter(r["status"] for r in rows)
    scoped = [r for r in rows if r["in_scope"]]
    scoped_counts = Counter(r["status"] for r in scoped)
    summary = {
        "blocks": len(rows),
        "by_status": dict(counts),
        "in_scope": len(scoped),
        "in_scope_by_status": dict(scoped_counts),
        **chapter_stats(rows),
    }
    for row in scoped:
        if row["status"] != PASS:
            where = row["chapter"] if not row["index"] else f"{row['chapter']}:{row['line']}"
            print(f"{row['status']:<13} {where}  {', '.join(row['ids'])}")
    print(
        "static gate: " + ", ".join(f"{counts[s]} {s}" for s in (PASS, FAIL, STALE, NOT_EVALUATED))
        + f" ({len(scoped)} of {len(rows)} blocks in scope)"
    )  # fmt: skip
    print(
        f"chapters with a workload: {summary['chapters_with_workload']}, "
        f"failing all five core checks: {summary['chapters_failing_all_core']}"
    )
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps({"summary": summary, "blocks": rows}, indent=2) + "\n", encoding="utf-8"
        )
    return 1 if scoped_counts[FAIL] or scoped_counts[STALE] else 0


if __name__ == "__main__":
    sys.exit(main())
