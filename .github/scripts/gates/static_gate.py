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
               custom resource, a List), or a document Trivy would skip (no
               apiVersion or metadata, a workload with no containers), or
               Trivy returned nothing for the file. Trivy reports such a
               file as clean, so a clean result there means nothing and is
               never a pass.

The gate does not trust a quiet scanner. Before reading any result it scans
two control fixtures beside the real files and aborts with exit code 2
unless the violating one trips all five core checks and the hardened one
trips none. A renamed check ID, an empty result or a missing check bundle
therefore stops the run instead of reading as a pass.

Trivy also reads a null `securityContext` as nothing to flag, and takes a
pod-level `runAsNonRoot: true` or a container's `runAsUser: 0` at face
value. So the gate cross-checks every workload against its parsed YAML: a
null or non-mapping `securityContext`, a container that overrides
`runAsNonRoot` to false and `runAsUser: 0` all fail. Three more control
fixtures prove that cross-check still sees each of them.

An insecure-on-purpose marker is allowed only in the Part 05 chapters, and
never on a workload in namespace `bookstore`, `default` or none.

Exit codes: 0 every in-scope block passes, or is not evaluated and holds no
pod template. 1 an in-scope block fails, has a stale marker, or is not
evaluated while holding a pod template that is not on the allowlist. 2 the
gate could not trust itself: the control check or the scanner failed, the
manifest or an --also path holds nothing, or no in-scope block was judged.
Not-evaluated blocks are always listed and counted apart from passes. Blocks
outside --scope are reported only. With no --scope everything is in scope.

The allowlist (--allow FILE) holds one `chapter | what | reason` line per
not-evaluated block that someone checked another way. `what` is the reason
the block printed (a kind such as Rollout, or `no-scanner-result`), or `*`.

Usage:
    static_gate.py --manifest M --scope CHAPTER [--scope ...]
                   [--also PATH ...] [--allow FILE ...] [--report OUT.json]
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

POD_KEYS = ("containers", "initContainers", "ephemeralContainers")

# Only Part 05 teaches attacks, so only its chapters may carry the marker. The
# capstone overlay is an examples tree that --also scans, never a chapter block.
MARKER_CHAPTERS = ("05-security/",)
SHARED_NAMESPACES = frozenset({"bookstore", "default"})

SEVERITIES = "LOW,MEDIUM,HIGH,CRITICAL"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
CONTROL_VIOLATING = "gate-control-violating.yaml"
CONTROL_HARDENED = "gate-control-hardened.yaml"

# What the parsed-YAML cross-check must find in each fixture: the core checks it
# adds to Trivy's findings, and the notes it raises.
BASELINE_CONTROLS = {
    "violating-null-securitycontext.yaml": (set(CORE), {"null-securityContext"}),
    "violating-runasnonroot-override.yaml": ({"KSV-0012"}, set()),
    "violating-runasuser-zero.yaml": ({"KSV-0012"}, set()),
}

PASS, FAIL, STALE, NOT_EVALUATED = "pass", "fail", "stale-marker", "not-evaluated"
JUDGED = (PASS, FAIL, STALE)


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
        return FAIL, [block.note or "unparseable"]
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


def _podish(node) -> bool:
    """True if anything under node looks like a pod template or a container."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in POD_KEYS and isinstance(value, list) and value:
                return True
            if key == "image" and isinstance(value, str):
                return True
            if _podish(value):
                return True
    elif isinstance(node, list):
        return any(_podish(item) for item in node)
    return False


def holds_pod_template(body: str) -> bool:
    """True if a document in body runs containers, whatever its kind.

    A Rollout, a PyTorchJob or a List carries a pod template the scanner never
    read. A body that does not parse is assumed to hold one.
    """
    docs = eb.load_documents(body)
    return docs is None or any(_podish(doc) for doc in docs)


def _context(node: dict) -> tuple[dict, str | None]:
    """Return (securityContext mapping, note); a null or odd value gives ({}, note)."""
    if "securityContext" not in node:
        return {}, None
    value = node["securityContext"]
    if isinstance(value, dict):
        return value, None
    return {}, "null-securityContext" if value is None else "non-mapping-securityContext"


def _seccomp_ok(*contexts: dict) -> bool:
    for sc in contexts:
        profile = sc.get("seccompProfile")
        if isinstance(profile, dict) and profile.get("type") in ("RuntimeDefault", "Localhost"):
            return True
    return False


def _drops_all(sc: dict) -> bool:
    caps = sc.get("capabilities")
    drop = caps.get("drop") if isinstance(caps, dict) else None
    return isinstance(drop, list) and any(str(item).upper() == "ALL" for item in drop)


def baseline_failures(body: str) -> tuple[set[str], set[str]]:
    """Cross-check every workload in body against its parsed YAML.

    Returns (core check IDs Trivy missed, notes). Trivy reads a null
    `securityContext` as clean, and trusts a pod-level `runAsNonRoot: true`
    over a container that sets it to false or runs as UID 0. For a container
    whose own or pod-level securityContext is null or not a mapping, all five
    core checks are worked out here, treating the null as empty.
    """
    failed: set[str] = set()
    notes: set[str] = set()
    for doc in eb.load_documents(body) or []:
        if not (isinstance(doc, dict) and doc.get("kind") in WORKLOAD_KINDS):
            continue
        spec = _pod_spec(doc)
        if not isinstance(spec, dict):
            continue
        pod_sc, pod_note = _context(spec)
        for key in POD_KEYS:
            for container in spec.get(key) or []:
                if not isinstance(container, dict):
                    continue
                sc, note = _context(container)
                uid = sc.get("runAsUser", pod_sc.get("runAsUser"))
                if sc.get("runAsNonRoot") is False or (uid == 0 and not isinstance(uid, bool)):
                    failed.add("KSV-0012")
                if not (pod_note or note):
                    continue
                notes.update(n for n in (pod_note, note) if n)
                if sc.get("runAsNonRoot", pod_sc.get("runAsNonRoot")) is not True:
                    failed.add("KSV-0012")
                if sc.get("readOnlyRootFilesystem") is not True:
                    failed.add("KSV-0014")
                if sc.get("allowPrivilegeEscalation") is not False:
                    failed.add("KSV-0001")
                if not _drops_all(sc):
                    failed.add("KSV-0003")
                if not _seccomp_ok(sc, pod_sc):
                    failed.add("KSV-0030")
    return failed, notes


def check_baseline_control() -> None:
    """Abort unless the cross-check sees each baseline fixture and clears the hardened one."""
    for name, (want_failed, want_notes) in BASELINE_CONTROLS.items():
        failed, notes = baseline_failures((FIXTURES / name).read_text(encoding="utf-8"))
        missing = sorted((want_failed - failed) | (want_notes - notes))
        if missing:
            raise ControlError(f"the parsed-YAML cross-check no longer flags {name}: {', '.join(missing)}")
    failed, notes = baseline_failures((FIXTURES / "hardened-deployment.yaml").read_text(encoding="utf-8"))
    if failed or notes:
        raise ControlError(
            "the hardened control fixture trips the parsed-YAML cross-check: "
            + ", ".join(sorted(failed | notes))
        )


def effective_scan(block: eb.Block, scan: Scan) -> Scan:
    """Return scan with the parsed-YAML cross-check's findings added."""
    if block.klass == eb.UNPARSEABLE or not scan.seen:
        return scan
    failed, notes = baseline_failures(Path(block.path).read_text(encoding="utf-8"))
    return Scan(scan.failed | failed, scan.high_crit | notes, scan.seen)


def marker_problems(block: eb.Block, body: str) -> list[str]:
    """List the ways an insecure-on-purpose block breaks the marker policy.

    The marker is allowed only in the Part 05 chapters, and never on a
    workload in namespace `bookstore`, `default` or none.
    """
    problems = []
    if not block.chapter.startswith(MARKER_CHAPTERS):
        problems.append("marker-outside-part-05")
    for doc in eb.load_documents(body) or []:
        if not isinstance(doc, dict):
            continue
        meta = doc.get("metadata") if isinstance(doc.get("metadata"), dict) else {}
        if doc.get("kind") == "Namespace":
            name = meta.get("name")
            if isinstance(name, str) and name in SHARED_NAMESPACES:
                problems.append(f"marker-namespace-{name}")
            continue
        namespace = meta.get("namespace")
        if isinstance(namespace, str) and namespace in SHARED_NAMESPACES:
            problems.append(f"marker-namespace-{namespace}")
        elif not namespace and (doc.get("kind") in WORKLOAD_KINDS or _podish(doc)):
            problems.append("marker-namespace-none")
    return list(dict.fromkeys(problems))


def load_allowlist(paths: list[Path]) -> set[tuple[str, str]]:
    """Read `chapter | what | reason` lines; every entry needs all three parts."""
    entries: set[tuple[str, str]] = set()
    for path in paths:
        try:
            text = Path(path).read_text(encoding="utf-8")
        except OSError as exc:
            raise ControlError(f"cannot read the allowlist: {exc}") from exc
        for number, raw in enumerate(text.splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [part.strip() for part in line.split("|", 2)]
            if len(parts) != 3 or not all(parts):
                raise ControlError(f"{path}:{number}: an allowlist entry is `chapter | what | reason`")
            entries.add((parts[0], parts[1]))
    return entries


def is_allowed(chapter: str, tokens: list[str], allow: set[tuple[str, str]]) -> bool:
    """True if every reason a block was not evaluated is allowlisted for its chapter."""
    return bool(tokens) and all(
        (chapter, token) in allow or (chapter, "*") in allow for token in tokens
    )


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
            names[path] = f"{i:05d}__{path.stem}{path.suffix.lower()}"  # Trivy keys on the lower-case suffix
            shutil.copyfile(path, scan_dir / names[path])
        shutil.copyfile(FIXTURES / "violating-deployment.yaml", scan_dir / CONTROL_VIOLATING)
        shutil.copyfile(FIXTURES / "hardened-deployment.yaml", scan_dir / CONTROL_HARDENED)
        scans = trivy_scan(scan_dir, trivy)
    check_control(scans)
    check_baseline_control()
    return {path: scans.get(name, Scan(set(), set(), False)) for path, name in names.items()}


def _also_blocks(paths: list[str]) -> list[eb.Block]:
    """Turn the files under --also paths into blocks that count as in scope.

    A path that does not exist, or that holds no manifest, would scan nothing
    and read as a pass, so it aborts the run.
    """
    blocks = []
    for given in paths:
        root = Path(given)
        if not root.exists():
            raise ControlError(f"--also path {given!r} does not exist")
        files = [root] if root.is_file() else sorted(
            p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in (".yaml", ".yml")
        )  # fmt: skip
        found = 0
        for path in files:
            try:
                body = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise ControlError(f"cannot read {path}: {exc}") from exc
            if not eb.is_manifest(body):
                continue
            klass, kinds = eb.classify(body, False)
            blocks.append(eb.Block(path.as_posix(), 0, 1, klass, kinds, str(path.resolve())))
            found += 1
        if not found:
            raise ControlError(f"--also path {given!r} holds no YAML manifest (.yaml or .yml)")
    return blocks


def judge(block: eb.Block, scan: Scan) -> tuple[str, list[str]]:
    """Verdict plus the guards that need the file: marker policy and a silent scanner."""
    if block.klass == eb.UNPARSEABLE:
        return verdict(block, scan.failed, scan.high_crit)
    body = Path(block.path).read_text(encoding="utf-8")
    if block.klass == eb.INSECURE:
        early = ([] if banner_ok(body) else ["missing-banner"]) + marker_problems(block, body)
        if early:
            return FAIL, early
    if not scan.seen:
        return NOT_EVALUATED, ["no-scanner-result"]
    scan = effective_scan(block, scan)
    status, ids = verdict(block, scan.failed, scan.high_crit)
    if status in (PASS, STALE) and not ids:
        gaps = incomplete_documents(body)
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
    parser.add_argument("--allow", action="append", default=[], type=Path, metavar="FILE")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)

    blocks = eb.load_manifest(args.manifest)
    try:
        if not blocks:
            raise ControlError("the manifest holds no blocks, so there is nothing to check")
        check_scopes(blocks, args.scope)
        also = _also_blocks(args.also)
        allow = load_allowlist(args.allow)
        scans = scan_files([Path(b.path) for b in blocks + also])
    except ControlError as exc:
        print(f"static gate aborted: {exc}", file=sys.stderr)
        return 2

    rows = []
    for block, explicit in [(b, False) for b in blocks] + [(b, True) for b in also]:
        scan = scans[Path(block.path)]
        status, ids = judge(block, scan)
        unjudged = status == NOT_EVALUATED
        pod_template = unjudged and holds_pod_template(Path(block.path).read_text(encoding="utf-8"))
        rows.append(
            {
                "chapter": block.chapter,
                "index": block.index,
                "line": block.line,
                "source": block.source,
                "klass": block.klass,
                "kinds": block.kinds,
                "status": status,
                "ids": ids,
                "core_failed": [i for i in CORE if i in effective_scan(block, scan).failed],
                "pod_template": pod_template,
                "allowed": pod_template and is_allowed(block.chapter, ids, allow),
                "in_scope": explicit or in_scope(block.chapter, args.scope),
            }
        )

    counts = Counter(r["status"] for r in rows)
    scoped = [r for r in rows if r["in_scope"]]
    scoped_counts = Counter(r["status"] for r in scoped)
    judged = sum(scoped_counts[s] for s in JUDGED)
    unlisted = [r for r in scoped if r["pod_template"] and not r["allowed"]]
    summary = {
        "blocks": len(rows),
        "by_status": dict(counts),
        "in_scope": len(scoped),
        "in_scope_by_status": dict(scoped_counts),
        "in_scope_judged": judged,
        "unlisted_pod_templates": len(unlisted),
        **chapter_stats(rows),
    }
    for row in scoped:
        if row["status"] != PASS:
            where = row["chapter"] if not row["index"] else f"{row['chapter']}:{row['line']}"
            tail = "  (holds a pod template, not allowlisted)" if row in unlisted else ""
            print(f"{row['status']:<13} {where}  {', '.join(row['ids'])}{tail}")
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
    if not judged:
        print(
            "static gate aborted: no in-scope block was judged (all "
            f"{len(scoped)} were not evaluated), so a pass would mean nothing",
            file=sys.stderr,
        )
        return 2
    return 1 if scoped_counts[FAIL] or scoped_counts[STALE] or unlisted else 0


if __name__ == "__main__":
    sys.exit(main())
