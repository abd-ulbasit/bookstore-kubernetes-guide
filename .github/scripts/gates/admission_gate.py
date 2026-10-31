#!/usr/bin/env python3
"""G3: the admission gate.

Server-side dry-runs every applyable block from G1 into a namespace that
enforces and warns at the `restricted` Pod Security level, and reports what
the API server said:

pass         accepted with no Pod Security complaint.
registered   accepted with no Pod Security complaint, in the namespace of a
             registered exception, at the level the registry gives it (below).
             It is judged, and it is not a failure.
violation    rejected for violating Pod Security, or accepted with a warning
             that says it would. A Deployment that breaks `restricted` is
             admitted with only a warning and exit 0 (its ReplicaSet is the
             one that cannot create Pods), so a warning counts as a violation.
missing-crd  the cluster has no such custom resource definition. The block
             was not evaluated. A removed or wrong apiVersion on a built-in
             kind, or on a group the cluster serves, is an `error` instead:
             no cluster could apply it.
error        any other failure, for example an invalid field.

Registered exceptions (design section 5.4). A namespace above `restricted`
is judged at its own level, not at `restricted`, only when all of this holds:
  * security/namespace-exceptions.yaml (--namespace-registry) has an entry for
    it, read by registry_gate.py. An entry that is expired, more than 12 months
    out, short of a reason, a citation or an existing chapter, or that shares
    its namespace with another entry, grants nothing;
  * the entry's `chapter` is the block's own chapter, so another chapter that
    uses the same namespace is still judged at `restricted`;
  * every namespaced document in the block names that one namespace. A block
    that also reaches another namespace, or none, is judged at `restricted`,
    so a chapter keeps its excepted agent in a block of its own.
Such a block is dry-run in `gate-baseline` or `gate-privileged`, which enforce
and warn at the entry's level. A workload that breaks that level, for example
a privileged Pod in a namespace registered at `baseline`, is a `violation`.
Only a clean result becomes `registered`; every other status stays as it was.

Insecure-on-purpose blocks are skipped, after the same marker policy the
static gate applies: Part 05 chapters only, and never on a workload in
namespace `bookstore`, `default` or none. A registered namespace does not
relax it. Unparseable blocks cannot be applied and count as failures when in
scope.

The gate writes to the cluster: it creates the `gate-restricted` namespace,
and `gate-baseline` or `gate-privileged` when a registered block needs one.
So it refuses to run unless the current kubectl context is a kind cluster
(`kind-` prefix) or one named with --allow-context, and it prints the
context before it writes.

Before it trusts any result the gate dry-runs the control fixtures and exits
2 unless the violating ones are a `violation` and the hardened one a `pass`.
Besides the plain violating fixture these include three that Trivy reads as
clean (a null securityContext, a container that overrides runAsNonRoot to
false, runAsUser 0). A cluster that does not enforce Pod Security therefore
stops the run instead of passing every block.

Exit codes: 0 no in-scope violation, error or unparseable block, and no
missing-crd block that holds a pod template off the allowlist. 1 at least
one of those. 2 the control check, the cluster, the context or the namespace
registry could not be trusted, the manifest holds nothing, or no in-scope
block was judged (every one was skipped or missing-crd). Blocks outside
--scope are reported only; with no --scope everything is in scope. The
ambient kubeconfig is used; the kubectl binary comes from --kubectl, the
KUBECTL environment variable, or PATH. The allowlist (--allow FILE) is the
one the static gate reads.

Usage:
    admission_gate.py --manifest M --scope CHAPTER [--scope ...]
                      [--allow FILE ...] [--allow-context NAME ...]
                      [--root full-guide] [--namespace-registry FILE]
                      [--today YYYY-MM-DD] [--report OUT.json]
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import yaml

import extract_blocks as eb
import registry_gate as rg
import scanner_registry as sr
from static_gate import (
    FIXTURES,
    KNOWN_KINDS,
    ControlError,
    check_scopes,
    holds_pod_template,
    in_scope,
    is_allowed,
    load_allowlist,
    marker_problems,
)

RESTRICTED = "restricted"
NAMESPACE = "gate-restricted"

KIND_CONTEXT_PREFIX = "kind-"

# A new namespace has no `default` ServiceAccount for a moment, and the API
# server refuses a Pod there until it exists, whatever its security context.
SERVICE_ACCOUNT_POLLS = 40
SERVICE_ACCOUNT_WAIT = 0.5

# Groups every Kubernetes API server serves itself. A kind in one of these is
# never a custom resource, so "no matches" there is a wrong or removed
# apiVersion, not a missing CRD. Groups named `*.k8s.io` that are CRDs
# (Gateway API, snapshots) are deliberately absent.
BUILTIN_GROUPS = frozenset(
    {
        "", "apps", "batch", "autoscaling", "policy", "extensions",
        "rbac.authorization.k8s.io", "networking.k8s.io", "storage.k8s.io",
        "admissionregistration.k8s.io", "apiextensions.k8s.io", "apiregistration.k8s.io",
        "authentication.k8s.io", "authorization.k8s.io", "certificates.k8s.io",
        "coordination.k8s.io", "discovery.k8s.io", "events.k8s.io",
        "flowcontrol.apiserver.k8s.io", "internal.apiserver.k8s.io", "node.k8s.io",
        "resource.k8s.io", "scheduling.k8s.io", "storagemigration.k8s.io",
    }
)  # fmt: skip

PASS, VIOLATION, MISSING_CRD, ERROR = "pass", "violation", "missing-crd", "error"
SKIPPED, UNPARSEABLE, REGISTERED = "skipped-insecure", "unparseable", "registered"
JUDGED = (PASS, REGISTERED, VIOLATION, ERROR, UNPARSEABLE)

# Fixtures that must come back as a violation, every one of them hardened or
# bare in a way Trivy alone cannot tell apart.
CONTROL_VIOLATING = (
    "violating-deployment.yaml",
    "violating-null-securitycontext.yaml",
    "violating-runasnonroot-override.yaml",
    "violating-runasuser-zero.yaml",
)
CONTROL_HARDENED = "hardened-deployment.yaml"

_PSA = re.compile(r"violat\w*\s+PodSecurity", re.IGNORECASE)
_NO_CRD = re.compile(
    r"no matches for kind|ensure CRDs are installed first"
    r"|the server could not find the requested resource",
    re.IGNORECASE,
)


_NO_MATCH = re.compile(r'no matches for kind "[^"]*" in version "(?P<gv>[^"]*)"')


@dataclass
class Cluster:
    """What the gate needs to know about the cluster it is dry-running against."""

    scoped: set[str] = field(default_factory=set)  # cluster-scoped kinds
    groups: set[str] = field(default_factory=set)  # API groups the server serves
    exceptions: dict[str, rg.NamespaceEntry] = field(default_factory=dict)  # registry entries the gate may rely on
    ready: set[str] = field(default_factory=set)  # Pod Security levels whose gate namespace exists


def _is_custom_group(gv: str, served: set[str]) -> bool:
    group = gv.rpartition("/")[0]
    return group not in BUILTIN_GROUPS and group not in served


def classify_output(rc: int, out: str, served: set[str] | frozenset[str] = frozenset()) -> str:
    """Classify one dry-run from kubectl's exit code and combined output.

    "No matches for kind" is a missing CRD only when the group is a custom
    one the cluster does not serve. For a built-in group, or a group the
    cluster serves, the apiVersion or the kind is wrong and no cluster could
    apply the block, so it is an error.
    """
    if _PSA.search(out):
        return VIOLATION
    if rc != 0:
        if not _NO_CRD.search(out):
            return ERROR
        versions = [m.group("gv") for m in _NO_MATCH.finditer(out)]
        if any(not _is_custom_group(gv, set(served)) for gv in versions):
            return ERROR
        return MISSING_CRD
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


def _kubectl(kubectl: str, args: list[str], stdin: str | None = None) -> tuple[int, str, str]:
    """Run kubectl; return (exit code, stdout, stderr)."""
    try:
        proc = subprocess.run(
            [kubectl, *args], input=stdin, capture_output=True, text=True, timeout=120, check=False
        )
    except subprocess.TimeoutExpired:
        return 124, "", "kubectl timed out after 120 seconds"
    except OSError as exc:
        raise ControlError(f"cannot run kubectl: {exc}") from exc
    return proc.returncode, proc.stdout, proc.stderr


def kubectl_run(kubectl: str, args: list[str], stdin: str | None = None) -> tuple[int, str]:
    """Run kubectl; return (exit code, stdout and stderr together)."""
    rc, out, err = _kubectl(kubectl, args, stdin)
    return rc, out + err


def current_context(kubectl: str) -> str:
    """Return the name of the current kubectl context."""
    rc, out, err = _kubectl(kubectl, ["config", "current-context"])
    context = out.strip()
    if rc != 0 or not context:
        raise ControlError(f"kubectl has no current context: {(err or out).strip()[:300]}")
    return context


def check_context(kubectl: str, allowed: list[str]) -> str:
    """Return the current context, or abort unless it is a kind cluster or allowed.

    The gate creates a namespace, so it must never run against whatever
    production cluster the ambient kubeconfig happens to select.
    """
    context = current_context(kubectl)
    if context.startswith(KIND_CONTEXT_PREFIX) or context in allowed:
        return context
    raise ControlError(
        f"kubectl context {context!r} is not a kind cluster ({KIND_CONTEXT_PREFIX}*), and this "
        f"gate creates the {NAMESPACE} namespace and its siblings. Switch context, or pass "
        f"--allow-context {context} if this cluster is meant for it"
    )


def cluster_scoped_kinds(kubectl: str) -> set[str]:
    rc, out = kubectl_run(kubectl, ["api-resources", "--namespaced=false", "--no-headers"])
    kinds = {line.split()[-1] for line in out.splitlines() if line.split()}
    if rc != 0 or not kinds:
        raise ControlError(f"cannot list cluster-scoped kinds (exit {rc}): {out.strip()[:300]}")
    return kinds


def served_groups(kubectl: str) -> set[str]:
    rc, out = kubectl_run(kubectl, ["api-versions"])
    groups = {line.strip().rpartition("/")[0] for line in out.splitlines() if line.strip()}
    if rc != 0 or not groups:
        raise ControlError(f"cannot list the served API versions (exit {rc}): {out.strip()[:300]}")
    return groups


def gate_namespace(level: str) -> str:
    """Name the namespace that enforces and warns at a Pod Security level."""
    return f"gate-{level}"


def ensure_namespace(kubectl: str, cluster: Cluster, level: str = RESTRICTED) -> str:
    """Create the gate namespace for a level once per run; return its name."""
    name = gate_namespace(level)
    if level in cluster.ready:
        return name
    manifest = {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": name,
            "labels": {
                "pod-security.kubernetes.io/enforce": level,
                "pod-security.kubernetes.io/warn": level,
            },
        },
    }
    rc, out = kubectl_run(kubectl, ["apply", "-f", "-"], yaml.safe_dump(manifest))
    if rc != 0:
        raise ControlError(f"cannot create namespace {name}: {out.strip()[:300]}")
    wait_for_default_service_account(kubectl, name)
    cluster.ready.add(level)
    return name


def wait_for_default_service_account(kubectl: str, namespace: str) -> None:
    """Return once the namespace has its `default` ServiceAccount, so a Pod dry-run is judged on Pod Security."""
    for _ in range(SERVICE_ACCOUNT_POLLS):
        rc, _out = kubectl_run(kubectl, ["get", "serviceaccount", "default", "-n", namespace, "-o", "name"])
        if rc == 0:
            return
        time.sleep(SERVICE_ACCOUNT_WAIT)
    raise ControlError(f"namespace {namespace} still has no default ServiceAccount, so a Pod cannot be dry-run in it")


def referenced_service_accounts(docs: list[dict]) -> set[str]:
    """Names of the non-default ServiceAccounts a block's Pod specs refer to."""
    names: set[str] = set()
    for doc in docs:
        spec = doc.get("spec")
        if not isinstance(spec, dict):
            continue
        template = spec.get("template") or {}
        job = (spec.get("jobTemplate") or {}).get("spec") or {}
        for pod_spec in (spec, template.get("spec") or {}, (job.get("template") or {}).get("spec") or {}):
            name = pod_spec.get("serviceAccountName") if isinstance(pod_spec, dict) else None
            if name and name != "default":
                names.add(name)
    return names


def referenced_runtime_classes(docs: list[dict]) -> set[str]:
    """Names of the RuntimeClasses a block's Pod specs refer to."""
    names: set[str] = set()
    for doc in docs:
        spec = doc.get("spec")
        if not isinstance(spec, dict):
            continue
        template = spec.get("template") or {}
        job = (spec.get("jobTemplate") or {}).get("spec") or {}
        for pod_spec in (spec, template.get("spec") or {}, (job.get("template") or {}).get("spec") or {}):
            name = pod_spec.get("runtimeClassName") if isinstance(pod_spec, dict) else None
            if name:
                names.add(name)
    return names


def ensure_runtime_classes(kubectl: str, names: set[str]) -> None:
    """Create named RuntimeClasses for the dry run.

    A chapter defines the RuntimeClass in an earlier block, and a server dry-run
    creates nothing, so a Pod naming it would be refused for a reason that has
    nothing to do with Pod Security. The handler never runs, because a dry run
    starts no container, and Pod Security still judges the Pod.
    """
    for name in sorted(names):
        manifest = {
            "apiVersion": "node.k8s.io/v1",
            "kind": "RuntimeClass",
            "metadata": {"name": name},
            "handler": "runc",
        }
        rc, out = kubectl_run(kubectl, ["apply", "-f", "-"], yaml.safe_dump(manifest))
        if rc != 0:
            raise ControlError(f"cannot create RuntimeClass {name}: {out.strip()[:300]}")


def ensure_service_accounts(kubectl: str, names: set[str], namespace: str = NAMESPACE) -> None:
    """Create named ServiceAccounts in a gate namespace.

    A server dry-run creates nothing, so a Pod naming a dedicated ServiceAccount
    would otherwise be refused for a reason that has nothing to do with Pod
    Security, even when the same block defines that ServiceAccount.
    """
    for name in sorted(names):
        manifest = {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": name, "namespace": namespace},
        }
        rc, out = kubectl_run(kubectl, ["apply", "-f", "-"], yaml.safe_dump(manifest))
        if rc != 0:
            raise ControlError(f"cannot create ServiceAccount {name}: {out.strip()[:300]}")


def dry_run(kubectl: str, body: str, cluster: Cluster, level: str = RESTRICTED) -> tuple[str, str]:
    """Server-side dry-run a block body in the gate namespace of a level; return (status, output)."""
    docs = [d for d in yaml.safe_load_all(body) if isinstance(d, dict)]
    namespace = ensure_namespace(kubectl, cluster, level)
    ensure_service_accounts(kubectl, referenced_service_accounts(docs), namespace)
    ensure_runtime_classes(kubectl, referenced_runtime_classes(docs))
    payload = yaml.safe_dump_all(retarget(docs, namespace, cluster.scoped), sort_keys=False)
    rc, out = kubectl_run(
        kubectl, ["apply", "--dry-run=server", "--validate=strict", "-f", "-"], payload
    )
    return classify_output(rc, out, cluster.groups), out


def check_control(kubectl: str, cluster: Cluster) -> None:
    """Abort unless every violating fixture is a violation and the hardened one passes."""
    expected = {name: VIOLATION for name in CONTROL_VIOLATING} | {CONTROL_HARDENED: PASS}
    for name, want in expected.items():
        body = (FIXTURES / name).read_text(encoding="utf-8")
        got, out = dry_run(kubectl, body, cluster)
        if got != want:
            raise ControlError(
                f"control fixture {name} came back {got!r}, expected {want!r}; "
                f"the cluster is not enforcing Pod Security as the gate needs. "
                f"Output: {out.strip()[:300]}"
            )


def registered_entry(docs: list[dict], chapter: str, cluster: Cluster) -> rg.NamespaceEntry | None:
    """Return the registry entry that lets a block be judged above `restricted`, or None.

    Every namespaced document must name one and the same namespace, and the
    registry must hold a sound entry for it that names this chapter. Anything
    short of that, such as a second namespace or a document with none, leaves
    the block at `restricted`.
    """
    spaces = set()
    for doc in docs:
        if doc.get("kind") in cluster.scoped:
            continue
        meta = doc.get("metadata")
        space = meta.get("namespace") if isinstance(meta, dict) else None
        spaces.add(space if isinstance(space, str) else None)
    if len(spaces) != 1:
        return None
    space = spaces.pop()
    entry = cluster.exceptions.get(space) if space else None
    return entry if entry and entry.chapter == chapter else None


def judge(block: eb.Block, kubectl: str, cluster: Cluster) -> tuple[str, str]:
    if block.klass == eb.UNPARSEABLE:
        return UNPARSEABLE, block.note
    body = Path(block.path).read_text(encoding="utf-8")
    if block.klass == eb.INSECURE:
        problems = marker_problems(block, body)
        if problems:
            return ERROR, "insecure-on-purpose marker not allowed here: " + ", ".join(problems)
        return SKIPPED, ""
    docs = [d for d in yaml.safe_load_all(body) if isinstance(d, dict)]
    entry = registered_entry(docs, block.chapter, cluster)
    if entry is None:
        return dry_run(kubectl, body, cluster)
    status, out = dry_run(kubectl, body, cluster, entry.level)
    if status != PASS:
        return status, out
    return REGISTERED, f"judged at {entry.level} for registered namespace {entry.namespace}\n{out}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--scope", action="append", default=[], metavar="CHAPTER")
    parser.add_argument("--allow", action="append", default=[], type=Path, metavar="FILE")
    parser.add_argument("--allow-context", action="append", default=[], metavar="NAME")
    parser.add_argument("--root", default="full-guide", type=Path, help="the guide the registry's chapters sit in")
    parser.add_argument("--namespace-registry", type=Path, metavar="FILE")
    parser.add_argument("--today", type=date.fromisoformat, default=None, help="YYYY-MM-DD, to repeat a run as of another day")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--kubectl", default=os.environ.get("KUBECTL", "kubectl"))
    args = parser.parse_args(argv)

    blocks = eb.load_manifest(args.manifest)
    try:
        if not blocks:
            raise ControlError("the manifest holds no blocks, so there is nothing to check")
        check_scopes(blocks, args.scope)
        allow = load_allowlist(args.allow)
        registry = rg.load_namespace_registry(
            args.namespace_registry or rg.DEFAULT_NAMESPACE_REGISTRY,
            args.today or date.today(),
            args.root,
            missing_ok=args.namespace_registry is None,
        )
        for problem in registry.problems:
            print(f"admission gate: {registry.path}: {problem}")
        for entry in registry.entries:
            if entry.problems:
                print(f"admission gate: {registry.path}: namespace {entry.namespace} is not applied: " + "; ".join(entry.problems))
        context = check_context(args.kubectl, args.allow_context)
        print(f"admission gate: kubectl context {context}")
        cluster = Cluster(
            cluster_scoped_kinds(args.kubectl), served_groups(args.kubectl), rg.usable_exceptions(registry)
        )
        ensure_namespace(args.kubectl, cluster)
        check_control(args.kubectl, cluster)
    except (ControlError, sr.RegistryError) as exc:
        print(f"admission gate aborted: {exc}", file=sys.stderr)
        return 2

    rows = []
    for block in blocks:
        try:
            status, out = judge(block, args.kubectl, cluster)
        except ControlError as exc:
            print(f"admission gate aborted: {exc}", file=sys.stderr)
            return 2
        unknown = [k for k in dict.fromkeys(block.kinds) if k not in KNOWN_KINDS]
        pod_template = status == MISSING_CRD and holds_pod_template(
            Path(block.path).read_text(encoding="utf-8")
        )
        rows.append(
            {
                "chapter": block.chapter,
                "index": block.index,
                "line": block.line,
                "source": block.source,
                "klass": block.klass,
                "kinds": block.kinds,
                "status": status,
                "detail": out.strip()[:600],
                "pod_template": pod_template,
                "allowed": pod_template and is_allowed(block.chapter, unknown or ["missing-crd"], allow),
                "in_scope": in_scope(block.chapter, args.scope),
            }
        )

    counts = Counter(r["status"] for r in rows)
    scoped = [r for r in rows if r["in_scope"]]
    failing = {VIOLATION, ERROR, UNPARSEABLE}
    judged = sum(1 for r in scoped if r["status"] in JUDGED)
    unlisted = [r for r in scoped if r["pod_template"] and not r["allowed"]]
    for row in scoped:
        if row["status"] in failing | {MISSING_CRD, REGISTERED}:
            first = row["detail"].splitlines()[0] if row["detail"] else ""
            tail = "  (holds a pod template, not allowlisted)" if row in unlisted else ""
            print(f"{row['status']:<12} {row['chapter']}:{row['line']}  {first[:110]}{tail}")
    order = (PASS, REGISTERED, VIOLATION, MISSING_CRD, ERROR, UNPARSEABLE, SKIPPED)
    print(
        "admission gate: " + ", ".join(f"{counts[s]} {s}" for s in order)
        + f" ({len(scoped)} of {len(rows)} blocks in scope)"
    )  # fmt: skip
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        summary = {
            "blocks": len(rows),
            "by_status": dict(counts),
            "in_scope": len(scoped),
            "in_scope_judged": judged,
            "unlisted_pod_templates": len(unlisted),
            "context": context,
        }
        args.report.write_text(
            json.dumps({"summary": summary, "blocks": rows}, indent=2) + "\n", encoding="utf-8"
        )
    if not judged:
        print(
            "admission gate aborted: no in-scope block was dry-run (every one of the "
            f"{len(scoped)} was skipped or missing a CRD), so a pass would mean nothing",
            file=sys.stderr,
        )
        return 2
    return 1 if any(r["status"] in failing for r in scoped) or unlisted else 0


if __name__ == "__main__":
    sys.exit(main())
