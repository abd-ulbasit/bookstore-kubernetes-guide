#!/usr/bin/env python3
"""G4: the runtime gate.

G1 to G3 read manifests. This gate runs them. It deploys the Bookstore the way
a reader can, in one of five forms, into a namespace that enforces the
`restricted` Pod Security level, and waits until every workload is Ready or
Complete:

raw                the files under raw-manifests/, in order
helm               the chart with its default values (`helm template`)
kustomize-dev      `kubectl kustomize overlays/dev`
kustomize-staging  `kubectl kustomize overlays/staging`
kustomize-prod     `kubectl kustomize overlays/prod`

The images are built and loaded into the kind cluster by the caller; the gate
only deploys. A form must create the `bookstore` namespace itself with
`pod-security.kubernetes.io/enforce: restricted`. The gate does not add the
label for it, because a form that forgets the label would then pass here and
run unrestricted for a reader.

What counts as ready: a Deployment, StatefulSet or DaemonSet has all its
replicas updated and ready; a Job is Complete; a Pod is Ready or Succeeded; a
CronJob is run once by hand (`kubectl create job --from`) and that Job must be
Complete. A Job that fails fails the gate at once, without waiting out the
timeout.

Three things fail the gate that a plain `kubectl apply` would let through:

* a Pod Security warning on apply ("would violate PodSecurity"). The namespace
  warns at `restricted`, and a Deployment that breaks the level is admitted
  with only that warning, while its ReplicaSet can never create a Pod;
* a document of a kind the cluster does not serve (a ServiceMonitor, a KEDA
  ScaledObject) that holds a pod template. Documents without one are skipped
  and listed, because a plain kind cluster has no such CRDs and they run no
  container;
* a Secret the workloads read that no document creates, other than
  `db-credentials`. The production overlay leaves that one to an external
  secrets operator, so the gate creates a stand-in with a random password, as
  that operator would.

`raw` treats 01-catalog-pod.yaml and 02-catalog-pod-sidecar.yaml as two states
of one Pod (the chapters delete one before applying the other), so it applies
each alone, waits for it to be Ready and deletes it before the rest.

The gate writes to the cluster, so it refuses to run unless the kubectl
context is a kind cluster (`kind-` prefix) or one named with --allow-context.

Exit codes: 0 every workload reached Ready or Complete. 1 a workload did not,
a Job failed, a form failed to render or apply, or one of the checks above
failed. 2 the gate could not run: no kind context, a missing tool, or nothing
to deploy.

Usage:
    runtime_gate.py --variant raw|helm|kustomize-dev|kustomize-staging|kustomize-prod
                    [--tree full-guide/examples/bookstore] [--timeout 900]
                    [--allow-context NAME ...] [--cleanup] [--report OUT.json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml

NAMESPACE = "bookstore"
TREE = "full-guide/examples/bookstore"
VARIANTS = ("raw", "helm", "kustomize-dev", "kustomize-staging", "kustomize-prod")
WORKLOAD_KINDS = ("Pod", "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
SNAPSHOT_FILES = ("01-catalog-pod.yaml", "02-catalog-pod-sidecar.yaml")
HEAD_FILES = ("00-namespace.yaml", "05-serviceaccounts-rbac.yaml")
STAND_IN_SECRET = "db-credentials"
PSA_WARNING = "would violate PodSecurity"
POLL_SECONDS = 5
TOOL_TIMEOUT = 300


class GateError(Exception):
    """The gate cannot run or cannot trust what it sees (exit 2)."""


class Failure(Exception):
    """The deployment is wrong (exit 1)."""


@dataclass
class Doc:
    body: dict
    source: str

    @property
    def kind(self) -> str:
        return str(self.body.get("kind", ""))

    @property
    def name(self) -> str:
        return str((self.body.get("metadata") or {}).get("name", ""))

    @property
    def api_version(self) -> str:
        return str(self.body.get("apiVersion", ""))

    def label(self) -> str:
        return f"{self.kind}/{self.name}"


@dataclass
class Result:
    variant: str
    context: str = ""
    skipped: list[str] = field(default_factory=list)
    stand_ins: list[str] = field(default_factory=list)
    workloads: dict[str, str] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)
    seconds: float = 0.0


def run_tool(argv: list[str], stdin: str | None = None, timeout: int = TOOL_TIMEOUT) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError as exc:
        raise GateError(f"{argv[0]} is not installed") from exc
    except subprocess.TimeoutExpired as exc:
        raise GateError(f"{' '.join(argv[:3])} did not finish in {timeout}s") from exc
    return proc.returncode, proc.stdout, proc.stderr


def load_docs(text: str, source: str) -> list[Doc]:
    docs = []
    try:
        for body in yaml.safe_load_all(text):
            if isinstance(body, dict) and body.get("kind"):
                if body["kind"] == "List":
                    docs += [Doc(item, source) for item in body.get("items") or [] if isinstance(item, dict)]
                else:
                    docs.append(Doc(body, source))
    except yaml.YAMLError as exc:
        raise Failure(f"{source} is not valid YAML: {exc}") from exc
    return docs


def raw_forms(tree: Path) -> tuple[list[Doc], list[tuple[str, list[Doc]]]]:
    """Return the documents to apply in order, and the snapshot Pods to run one at a time."""
    folder = tree / "raw-manifests"
    files = sorted(folder.glob("*.yaml"))
    if not files:
        raise GateError(f"{folder} holds no manifests")
    head, snapshots, rest = [], [], []
    for path in files:
        docs = load_docs(path.read_text(encoding="utf-8"), path.name)
        if path.name in SNAPSHOT_FILES:
            snapshots.append((path.name, docs))
        elif path.name in HEAD_FILES:
            head += docs
        else:
            rest += docs
    return head + rest, snapshots


def render(variant: str, tree: Path, helm: str, kubectl: str) -> tuple[list[Doc], list[tuple[str, list[Doc]]]]:
    if variant == "raw":
        return raw_forms(tree)
    if variant == "helm":
        argv = [helm, "template", "bookstore", str(tree / "helm" / "bookstore"), "--namespace", NAMESPACE]
    else:
        argv = [kubectl, "kustomize", str(tree / "kustomize" / "overlays" / variant.removeprefix("kustomize-"))]
    rc, out, err = run_tool(argv)
    if rc != 0:
        raise Failure(f"{variant} does not render: {err.strip()[:600]}")
    return load_docs(out, variant), []


def current_context(kubectl: str) -> str:
    rc, out, err = run_tool([kubectl, "config", "current-context"])
    if rc != 0 or not out.strip():
        raise GateError(f"no kubectl context: {err.strip()[:300]}")
    return out.strip()


def served_kinds(kubectl: str) -> set[tuple[str, str]]:
    """Return (apiVersion, kind) for every resource the cluster serves."""
    rc, out, err = run_tool([kubectl, "api-resources", "--no-headers"])
    if rc != 0 or not out.strip():
        raise GateError(f"cannot list the served resources: {err.strip()[:300]}")
    return parse_api_resources(out)


def parse_api_resources(text: str) -> set[tuple[str, str]]:
    served = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            served.add((parts[-3], parts[-1]))
    return served


def pod_specs(doc: Doc) -> list[dict]:
    """Every pod spec a document carries, whatever its kind."""
    found: list[dict] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            if isinstance(node.get("containers"), list):
                found.append(node)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(doc.body)
    return found


def runs_pods(doc: Doc) -> bool:
    """True if the document would start containers: a Pod, or anything with a pod template.

    A policy that matches Pods (a Kyverno ClusterPolicy) shows a `containers`
    list in its pattern, but it starts nothing, so only a top-level
    `spec.containers` or a `template` holding `spec.containers` counts.
    """
    spec = doc.body.get("spec")
    if isinstance(spec, dict) and isinstance(spec.get("containers"), list):
        return True

    def walk(node: object) -> bool:
        if isinstance(node, dict):
            template = node.get("template")
            if isinstance(template, dict) and isinstance((template.get("spec") or {}).get("containers"), list):
                return True
            return any(walk(value) for value in node.values())
        if isinstance(node, list):
            return any(walk(value) for value in node)
        return False

    return walk(doc.body)


def split_unserved(docs: list[Doc], served: set[tuple[str, str]]) -> tuple[list[Doc], list[Doc]]:
    keep, skip = [], []
    for doc in docs:
        (keep if (doc.api_version, doc.kind) in served else skip).append(doc)
    return keep, skip


def referenced_secrets(docs: list[Doc]) -> dict[str, set[str]]:
    """Secret name -> keys read through secretKeyRef or mounted as a volume."""
    refs: dict[str, set[str]] = {}
    for doc in docs:
        for spec in pod_specs(doc):
            for ctr in (spec.get("containers") or []) + (spec.get("initContainers") or []):
                for env in ctr.get("env") or []:
                    ref = ((env.get("valueFrom") or {}).get("secretKeyRef")) or {}
                    if ref.get("name") and not ref.get("optional"):
                        refs.setdefault(ref["name"], set()).add(ref.get("key", ""))
                for source in ctr.get("envFrom") or []:
                    ref = source.get("secretRef") or {}
                    if ref.get("name") and not ref.get("optional"):
                        refs.setdefault(ref["name"], set())
            for volume in spec.get("volumes") or []:
                ref = volume.get("secret") or {}
                if ref.get("secretName") and not ref.get("optional"):
                    refs.setdefault(ref["secretName"], set())
    return refs


def missing_secrets(docs: list[Doc]) -> dict[str, set[str]]:
    defined = {d.name for d in docs if d.kind == "Secret"}
    return {name: keys for name, keys in referenced_secrets(docs).items() if name not in defined}


def stand_in_manifest(name: str, keys: set[str]) -> dict:
    data = {}
    for key in sorted(k for k in keys if k) or ["value"]:
        data[key] = "bookstore" if key in ("POSTGRES_USER", "POSTGRES_DB") else secrets.token_urlsafe(18)
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": NAMESPACE},
        "type": "Opaque",
        "stringData": data,
    }


def namespace_problem(docs: list[Doc]) -> str | None:
    for doc in docs:
        if doc.kind == "Namespace" and doc.name == NAMESPACE:
            labels = (doc.body.get("metadata") or {}).get("labels") or {}
            level = labels.get("pod-security.kubernetes.io/enforce")
            if level != "restricted":
                return f"Namespace {NAMESPACE} enforces {level or 'nothing'}, not restricted"
            return None
    return f"no document creates Namespace {NAMESPACE}"


def expected_workloads(docs: list[Doc]) -> list[Doc]:
    return [d for d in docs if d.kind in WORKLOAD_KINDS]


def replicas_of(obj: dict) -> int:
    value = (obj.get("spec") or {}).get("replicas")
    return 1 if value is None else int(value)


def condition(obj: dict, kind: str) -> str | None:
    for cond in (obj.get("status") or {}).get("conditions") or []:
        if cond.get("type") == kind:
            return cond.get("status")
    return None


def workload_state(kind: str, obj: dict | None) -> tuple[str, str]:
    """Return ("ready"|"waiting"|"failed", why) for one live object."""
    if obj is None:
        return "waiting", "not created yet"
    status = obj.get("status") or {}
    spec = obj.get("spec") or {}
    meta = obj.get("metadata") or {}
    if kind == "Deployment":
        want = replicas_of(obj)
        if status.get("observedGeneration", 0) < meta.get("generation", 0):
            return "waiting", "spec not observed yet"
        have = (status.get("updatedReplicas", 0), status.get("readyReplicas", 0), status.get("availableReplicas", 0))
        if all(n >= want for n in have) and status.get("replicas", 0) <= want:
            return "ready", f"{want}/{want} ready"
        return "waiting", f"{status.get('readyReplicas', 0)}/{want} ready"
    if kind == "StatefulSet":
        want = replicas_of(obj)
        if status.get("observedGeneration", 0) < meta.get("generation", 0):
            return "waiting", "spec not observed yet"
        if status.get("readyReplicas", 0) >= want and status.get("updatedReplicas", 0) >= want:
            return "ready", f"{want}/{want} ready"
        return "waiting", f"{status.get('readyReplicas', 0)}/{want} ready"
    if kind == "DaemonSet":
        want = status.get("desiredNumberScheduled", 0)
        if want and status.get("numberReady", 0) >= want and status.get("updatedNumberScheduled", 0) >= want:
            return "ready", f"{want}/{want} ready"
        return "waiting", f"{status.get('numberReady', 0)}/{want} ready"
    if kind == "Job":
        if condition(obj, "Complete") == "True":
            return "ready", "complete"
        if condition(obj, "Failed") == "True":
            return "failed", "the Job failed"
        want = spec.get("completions") or 1
        return "waiting", f"{status.get('succeeded', 0)}/{want} complete"
    if kind == "Pod":
        if status.get("phase") == "Succeeded" or condition(obj, "Ready") == "True":
            return "ready", "ready"
        if status.get("phase") == "Failed":
            return "failed", "the Pod failed"
        return "waiting", status.get("phase", "Pending")
    return "waiting", "unknown kind"


def parse_items(text: str) -> dict[tuple[str, str], dict]:
    try:
        items = json.loads(text).get("items", [])
    except ValueError as exc:
        raise GateError(f"kubectl returned something that is not JSON: {exc}") from exc
    return {(i.get("kind", ""), i["metadata"]["name"]): i for i in items if i.get("metadata", {}).get("name")}


def live_objects(kubectl: str) -> dict[tuple[str, str], dict]:
    rc, out, err = run_tool(
        [kubectl, "get", "pods,deployments,statefulsets,daemonsets,jobs", "--namespace", NAMESPACE, "--output", "json"]
    )
    if rc != 0:
        raise GateError(f"cannot read the namespace: {err.strip()[:300]}")
    return parse_items(out)


def warnings_in(stderr: str) -> list[str]:
    return [line.strip() for line in stderr.splitlines() if PSA_WARNING in line]


def apply_docs(kubectl: str, docs: list[Doc], what: str) -> None:
    text = yaml.safe_dump_all([d.body for d in docs], sort_keys=False)
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as handle:
        handle.write(text)
        path = handle.name
    try:
        rc, out, err = run_tool([kubectl, "apply", "--filename", path, "--namespace", NAMESPACE])
    finally:
        os.unlink(path)
    if out.strip():
        print(out.strip())
    if rc != 0:
        raise Failure(f"kubectl apply failed for {what}: {err.strip()[:900]}")
    bad = warnings_in(err)
    if bad:
        raise Failure(f"{what} breaks the restricted level:\n  " + "\n  ".join(bad[:6]))


def diagnostics(kubectl: str, pending: list[str]) -> None:
    print("---- not ready: " + ", ".join(pending), flush=True)
    for argv in (
        [kubectl, "get", "pods", "--namespace", NAMESPACE, "--output", "wide"],
        [kubectl, "get", "events", "--namespace", NAMESPACE, "--sort-by=.lastTimestamp"],
    ):
        _, out, _ = run_tool(argv)
        lines = out.strip().splitlines()
        print("$ " + " ".join(argv[1:]))
        print("\n".join(lines[:1] + lines[-25:] if len(lines) > 26 else lines))
    for (kind, name), pod in sorted(live_objects(kubectl).items()):
        if kind == "Pod" and workload_state("Pod", pod)[0] != "ready":
            _, logs, _ = run_tool([kubectl, "logs", name, "--namespace", NAMESPACE, "--all-containers", "--tail=15"])
            print(f"$ kubectl logs {name} --tail=15\n{logs.strip()}")


def wait_for(kubectl: str, docs: list[Doc], deadline: float, result: Result) -> None:
    """Poll until every expected workload is ready, one has failed, or time is up."""
    expected = [d for d in expected_workloads(docs) if d.kind != "CronJob"]
    last: dict[str, str] = {}
    finished: set[str] = set()  # a Job may be deleted by its TTL once it is Complete
    while True:
        live = live_objects(kubectl)
        pending, failed = [], []
        for doc in expected:
            if doc.label() in finished:
                continue
            state, why = workload_state(doc.kind, live.get((doc.kind, doc.name)))
            if state == "ready" and doc.kind == "Job":
                finished.add(doc.label())
            result.workloads[doc.label()] = f"{state}: {why}"
            if state == "failed":
                failed.append(f"{doc.label()} ({why})")
            elif state != "ready":
                pending.append(f"{doc.label()} ({why})")
        snapshot = {k: v for k, v in result.workloads.items() if not v.startswith("ready")}
        if snapshot != last:
            for key, value in sorted(snapshot.items()):
                print(f"  {key}: {value}", flush=True)
            last = snapshot
        if failed:
            diagnostics(kubectl, failed)
            raise Failure("failed: " + ", ".join(failed))
        if not pending:
            return
        if time.monotonic() > deadline:
            diagnostics(kubectl, pending)
            raise Failure("timed out waiting for: " + ", ".join(pending))
        time.sleep(POLL_SECONDS)


def run_cronjobs(kubectl: str, docs: list[Doc], deadline: float, result: Result) -> None:
    """Run each CronJob once by hand: its Job must Complete."""
    for doc in (d for d in docs if d.kind == "CronJob"):
        job = f"gate-{doc.name}"[:52]
        rc, out, err = run_tool([kubectl, "create", "job", job, f"--from=cronjob/{doc.name}", "--namespace", NAMESPACE])
        if rc != 0:
            raise Failure(f"cannot run CronJob/{doc.name} once: {err.strip()[:400]}")
        while True:
            live = live_objects(kubectl).get(("Job", job))
            state, why = workload_state("Job", live)
            if state == "ready":
                result.workloads[doc.label()] = f"ready: ran once as Job/{job}, {why}"
                print(f"  {doc.label()}: ran once as Job/{job}, {why}", flush=True)
                break
            if state == "failed" or time.monotonic() > deadline:
                diagnostics(kubectl, [f"{doc.label()} ({why})"])
                raise Failure(f"CronJob/{doc.name} did not complete when run once: {why}")
            time.sleep(POLL_SECONDS)


def run_snapshots(kubectl: str, snapshots: list[tuple[str, list[Doc]]], deadline: float, result: Result) -> None:
    for name, docs in snapshots:
        print(f"snapshot Pod {name}: apply alone, wait for Ready, delete", flush=True)
        apply_docs(kubectl, docs, name)
        pods = [d for d in docs if d.kind == "Pod"]
        if not pods:
            raise Failure(f"{name} is expected to hold a Pod")
        try:
            wait_for(kubectl, pods, deadline, result)
        finally:
            for pod in pods:
                run_tool([kubectl, "delete", "pod", pod.name, "--namespace", NAMESPACE, "--ignore-not-found", "--wait=true"])
        for pod in pods:
            result.workloads.pop(pod.label(), None)
            result.workloads[f"{pod.label()} ({name})"] = "ready: applied alone, then deleted"


def cleanup(kubectl: str, docs: list[Doc]) -> None:
    run_tool([kubectl, "delete", "namespace", NAMESPACE, "--ignore-not-found", "--wait=true", "--timeout=120s"])
    for doc in docs:
        if doc.kind in ("PriorityClass", "StorageClass") and doc.name:
            run_tool([kubectl, "delete", doc.kind.lower(), doc.name, "--ignore-not-found"])


def deploy(args: argparse.Namespace, result: Result) -> list[Doc]:
    docs, snapshots = render(args.variant, args.tree, args.helm, args.kubectl)
    if not docs:
        raise GateError(f"{args.variant} renders no documents")
    served = served_kinds(args.kubectl)
    docs, skipped = split_unserved(docs, served)
    snapshot_docs = [d for _, group in snapshots for d in group]
    holding = [d.label() for d in skipped if runs_pods(d)]
    result.skipped = sorted({d.label() for d in skipped})
    if holding:
        raise Failure("a kind this cluster does not serve holds a pod template, so it would go unrun: " + ", ".join(holding))
    if not expected_workloads(docs):
        raise GateError(f"{args.variant} holds no workload, so there is nothing to wait for")
    problem = namespace_problem(docs)
    if problem:
        raise Failure(problem)
    for kind in sorted({d.kind for d in skipped}):
        names = sorted(d.name for d in skipped if d.kind == kind)
        print(f"skipped (no such CRD on a plain kind cluster, no pod template): {kind} {', '.join(names)}")

    deadline = time.monotonic() + args.timeout
    head = [d for d in docs if d.kind in ("Namespace", "ResourceQuota", "LimitRange", "ServiceAccount", "PriorityClass", "StorageClass")]
    apply_docs(args.kubectl, head, "the namespace and its governance objects")
    for name, keys in sorted(missing_secrets(docs + snapshot_docs).items()):
        if name != STAND_IN_SECRET:
            raise Failure(f"workloads read Secret {name}, and no document creates it")
        apply_docs(args.kubectl, load_docs(yaml.safe_dump(stand_in_manifest(name, keys)), "stand-in"), f"stand-in Secret {name}")
        result.stand_ins.append(name)
        print(f"created a stand-in Secret/{name} with random values: this form leaves it to an external secrets operator")
    if snapshots:
        run_snapshots(args.kubectl, snapshots, deadline, result)
    apply_docs(args.kubectl, [d for d in docs if d not in head], f"{args.variant}")
    wait_for(args.kubectl, docs, deadline, result)
    run_cronjobs(args.kubectl, docs, deadline, result)
    return docs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--variant", required=True, choices=VARIANTS)
    parser.add_argument("--tree", default=Path(TREE), type=Path)
    parser.add_argument("--timeout", default=900, type=int, help="seconds to wait for every workload")
    parser.add_argument("--allow-context", action="append", default=[], metavar="NAME")
    parser.add_argument("--cleanup", action="store_true", help="delete the namespace and cluster-scoped objects afterwards")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--kubectl", default=os.environ.get("KUBECTL", "kubectl"))
    parser.add_argument("--helm", default=os.environ.get("HELM", "helm"))
    args = parser.parse_args(argv)

    result = Result(args.variant)
    started = time.monotonic()
    docs: list[Doc] = []
    code = 0
    trusted = False
    try:
        result.context = current_context(args.kubectl)
        if not result.context.startswith("kind-") and result.context not in args.allow_context:
            raise GateError(f"kubectl context {result.context!r} is not a kind cluster; pass --allow-context to use it")
        trusted = True
        print(f"runtime gate: {args.variant} on kubectl context {result.context}", flush=True)
        docs = deploy(args, result)
    except Failure as exc:
        result.problems.append(str(exc))
        print(f"runtime gate FAILED ({args.variant}): {exc}", file=sys.stderr)
        code = 1
    except GateError as exc:
        result.problems.append(str(exc))
        print(f"runtime gate aborted: {exc}", file=sys.stderr)
        code = 2
    finally:
        result.seconds = round(time.monotonic() - started, 1)
        if args.cleanup and trusted:
            cleanup(args.kubectl, docs)
    if code == 0:
        ready = sum(1 for v in result.workloads.values() if v.startswith("ready"))
        print(f"runtime gate: {args.variant}: {ready} workloads Ready or Complete in {result.seconds}s")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result.__dict__, indent=2) + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    sys.exit(main())
