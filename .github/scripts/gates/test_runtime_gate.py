#!/usr/bin/env python3
"""Tests for the runtime gate (`runtime_gate.py`, G4).

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

The gate needs a real cluster to prove itself, and that is what CI gives it.
These tests cover the parts a cluster cannot: the readiness rules, the
checks that fail a deployment kubectl would accept, and the exit codes, using
a fake `kubectl` that plays a cluster from a state file. They also render the
real Bookstore forms with Helm and kubectl, so a form that stops being
deployable in the shapes the gate expects fails here before it reaches CI.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import yaml

import runtime_gate as rg

ROOT = Path(__file__).resolve().parents[3]
TREE = ROOT / "full-guide" / "examples" / "bookstore"
HAVE_RENDERERS = bool(shutil.which("helm") and shutil.which("kubectl"))

PLAIN_KINDS = """\
namespaces                         ns           v1                  false        Namespace
secrets                                         v1                  true         Secret
serviceaccounts                    sa           v1                  true         ServiceAccount
pods                               po           v1                  true         Pod
deployments                        deploy       apps/v1             true         Deployment
statefulsets                       sts          apps/v1             true         StatefulSet
jobs                                            batch/v1            true         Job
cronjobs                           cj           batch/v1            true         CronJob
"""

NAMESPACE_DOC = {
    "apiVersion": "v1",
    "kind": "Namespace",
    "metadata": {"name": "bookstore", "labels": {"pod-security.kubernetes.io/enforce": "restricted"}},
}


def doc(kind: str, name: str, api: str = "apps/v1", **extra) -> rg.Doc:
    body = {"apiVersion": api, "kind": kind, "metadata": {"name": name}}
    body.update(extra)
    return rg.Doc(body, "test")


def deployment(name: str, replicas: int | None = 1, env: list | None = None) -> rg.Doc:
    container = {"name": "app", "image": "x"}
    if env:
        container["env"] = env
    spec: dict = {"template": {"spec": {"containers": [container]}}}
    if replicas is not None:
        spec["replicas"] = replicas
    return doc("Deployment", name, spec=spec)


class StateTests(unittest.TestCase):
    def test_a_deployment_needs_every_replica_updated_ready_and_available(self) -> None:
        live = {"metadata": {"generation": 2}, "spec": {"replicas": 3},
                "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3, "readyReplicas": 3, "availableReplicas": 3}}
        self.assertEqual(rg.workload_state("Deployment", live)[0], "ready")
        live["status"]["readyReplicas"] = 2
        self.assertEqual(rg.workload_state("Deployment", live), ("waiting", "2/3 ready"))

    def test_a_deployment_that_has_not_observed_its_spec_is_not_ready(self) -> None:
        live = {"metadata": {"generation": 2}, "spec": {"replicas": 1},
                "status": {"observedGeneration": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1}}
        self.assertEqual(rg.workload_state("Deployment", live)[0], "waiting")

    def test_a_deployment_still_running_old_replicas_is_not_ready(self) -> None:
        live = {"metadata": {"generation": 1}, "spec": {"replicas": 1},
                "status": {"observedGeneration": 1, "replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1}}
        self.assertEqual(rg.workload_state("Deployment", live)[0], "waiting")

    def test_a_statefulset_waits_for_its_ready_replicas(self) -> None:
        live = {"metadata": {"generation": 1}, "spec": {"replicas": 1}, "status": {"observedGeneration": 1}}
        self.assertEqual(rg.workload_state("StatefulSet", live)[0], "waiting")
        live["status"].update(readyReplicas=1, updatedReplicas=1)
        self.assertEqual(rg.workload_state("StatefulSet", live)[0], "ready")

    def test_a_daemonset_with_nothing_scheduled_is_not_ready(self) -> None:
        self.assertEqual(rg.workload_state("DaemonSet", {"status": {"desiredNumberScheduled": 0}})[0], "waiting")

    def test_a_job_is_ready_only_when_complete_and_failed_when_failed(self) -> None:
        done = {"status": {"conditions": [{"type": "Complete", "status": "True"}]}}
        broken = {"status": {"conditions": [{"type": "Failed", "status": "True"}]}}
        running = {"spec": {"completions": 1}, "status": {"active": 1}}
        self.assertEqual(rg.workload_state("Job", done)[0], "ready")
        self.assertEqual(rg.workload_state("Job", broken)[0], "failed")
        self.assertEqual(rg.workload_state("Job", running)[0], "waiting")

    def test_a_pod_is_ready_or_succeeded(self) -> None:
        ready = {"status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}
        self.assertEqual(rg.workload_state("Pod", ready)[0], "ready")
        self.assertEqual(rg.workload_state("Pod", {"status": {"phase": "Succeeded"}})[0], "ready")
        self.assertEqual(rg.workload_state("Pod", {"status": {"phase": "Pending"}})[0], "waiting")
        self.assertEqual(rg.workload_state("Pod", {"status": {"phase": "Failed"}})[0], "failed")

    def test_an_object_that_does_not_exist_yet_is_waiting(self) -> None:
        self.assertEqual(rg.workload_state("Deployment", None)[0], "waiting")


class ChecksTests(unittest.TestCase):
    def test_the_namespace_must_enforce_restricted_itself(self) -> None:
        self.assertIsNone(rg.namespace_problem([rg.Doc(NAMESPACE_DOC, "t")]))
        weak = yaml.safe_load(yaml.safe_dump(NAMESPACE_DOC))
        weak["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] = "baseline"
        self.assertIn("baseline", rg.namespace_problem([rg.Doc(weak, "t")]))
        weak["metadata"]["labels"] = {}
        self.assertIn("nothing", rg.namespace_problem([rg.Doc(weak, "t")]))
        self.assertIn("no document creates", rg.namespace_problem([deployment("a")]))

    def test_a_pod_security_warning_is_found_in_kubectl_stderr(self) -> None:
        err = 'Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false\nx\n'
        self.assertEqual(len(rg.warnings_in(err)), 1)
        self.assertEqual(rg.warnings_in("Warning: something else\n"), [])

    def test_api_resources_are_read_with_and_without_short_names(self) -> None:
        served = rg.parse_api_resources(PLAIN_KINDS)
        self.assertIn(("apps/v1", "Deployment"), served)
        self.assertIn(("v1", "Secret"), served)
        self.assertNotIn(("monitoring.coreos.com/v1", "ServiceMonitor"), served)

    def test_unserved_kinds_are_split_out(self) -> None:
        served = rg.parse_api_resources(PLAIN_KINDS)
        monitor = doc("ServiceMonitor", "m", api="monitoring.coreos.com/v1")
        keep, skip = rg.split_unserved([deployment("a"), monitor], served)
        self.assertEqual([d.name for d in keep], ["a"])
        self.assertEqual([d.kind for d in skip], ["ServiceMonitor"])

    def test_a_pod_template_is_found_in_any_kind(self) -> None:
        rollout = doc("Rollout", "r", api="argoproj.io/v1alpha1", spec={"template": {"spec": {"containers": [{"name": "a"}]}}})
        scaled = doc("ScaledJob", "j", api="keda.sh/v1alpha1", spec={"jobTemplate": {"spec": {"template": {"spec": {"containers": [{"name": "a"}]}}}}})
        monitor = doc("ServiceMonitor", "m", api="monitoring.coreos.com/v1", spec={"endpoints": []})
        pod = doc("Pod", "p", "v1", spec={"containers": [{"name": "a"}]})
        for item in (rollout, scaled, pod):
            self.assertTrue(rg.runs_pods(item), item.kind)
        self.assertFalse(rg.runs_pods(monitor))

    def test_a_policy_that_matches_pods_does_not_run_any(self) -> None:
        policy = doc("ClusterPolicy", "p", api="kyverno.io/v1", spec={"rules": [{"validate": {"pattern": {"spec": {"containers": [{"image": "*@sha256:*"}]}}}}]})
        self.assertFalse(rg.runs_pods(policy))

    def test_a_secret_nobody_creates_is_reported_with_its_keys(self) -> None:
        env = [{"name": "U", "valueFrom": {"secretKeyRef": {"name": "db-credentials", "key": "POSTGRES_USER"}}}]
        missing = rg.missing_secrets([deployment("a", env=env)])
        self.assertEqual(missing, {"db-credentials": {"POSTGRES_USER"}})
        defined = doc("Secret", "db-credentials", api="v1")
        self.assertEqual(rg.missing_secrets([deployment("a", env=env), defined]), {})

    def test_an_optional_secret_is_not_required(self) -> None:
        env = [{"name": "U", "valueFrom": {"secretKeyRef": {"name": "x", "key": "k", "optional": True}}}]
        self.assertEqual(rg.missing_secrets([deployment("a", env=env)]), {})

    def test_the_stand_in_secret_has_random_values_and_fixed_names(self) -> None:
        first = rg.stand_in_manifest("db-credentials", {"POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"})
        second = rg.stand_in_manifest("db-credentials", {"POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"})
        self.assertEqual(first["stringData"]["POSTGRES_USER"], "bookstore")
        self.assertEqual(first["stringData"]["POSTGRES_DB"], "bookstore")
        self.assertNotEqual(first["stringData"]["POSTGRES_PASSWORD"], second["stringData"]["POSTGRES_PASSWORD"])
        self.assertGreaterEqual(len(first["stringData"]["POSTGRES_PASSWORD"]), 16)

    def test_cronjobs_and_pods_count_as_workloads_but_services_do_not(self) -> None:
        kinds = [d.kind for d in rg.expected_workloads([doc("CronJob", "c", "batch/v1"), doc("Service", "s", "v1"), doc("Pod", "p", "v1")])]
        self.assertEqual(kinds, ["CronJob", "Pod"])


FAKE_KUBECTL = '''\
#!/usr/bin/env python3
"""Plays a cluster for runtime_gate.py. State lives in $FAKE_STATE (JSON)."""
import json, os, sys
import yaml

path = os.environ["FAKE_STATE"]
state = json.load(open(path))
args = sys.argv[1:]

def save():
    json.dump(state, open(path, "w"))

def flag(name):
    return args[args.index(name) + 1] if name in args else None

if args[:2] == ["config", "current-context"]:
    print(state["context"])
elif args[0] == "api-resources":
    print(state["served"], end="")
elif args[0] == "apply":
    docs = [d for d in yaml.safe_load_all(open(flag("--filename"))) if d]
    for d in docs:
        state["applied"].append([d["kind"], d["metadata"]["name"]])
        print(d["kind"].lower() + "/" + d["metadata"]["name"] + " created")
    save()
    if state.get("warn"):
        sys.stderr.write('Warning: would violate PodSecurity "restricted:latest": runAsNonRoot != true\\n')
elif args[0] == "get" and args[1].startswith("pods,"):
    mode = state["mode"]
    items = []
    for kind, name in state["applied"]:
        status = {}
        spec = {}
        if kind == "Deployment":
            status = {"observedGeneration": 1, "replicas": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1}
            if mode == "stuck":
                status["readyReplicas"] = 0
        elif kind == "StatefulSet":
            status = {"observedGeneration": 1, "readyReplicas": 1, "updatedReplicas": 1}
        elif kind == "Job":
            ctype = "Failed" if mode == "job-fails" else "Complete"
            status = {"conditions": [{"type": ctype, "status": "True"}]}
        elif kind == "Pod":
            status = {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}
        else:
            continue
        items.append({"kind": kind, "metadata": {"name": name, "generation": 1}, "spec": spec, "status": status})
    for name in state.get("manual_jobs", []):
        items.append({"kind": "Job", "metadata": {"name": name}, "spec": {}, "status": {"conditions": [{"type": "Complete", "status": "True"}]}})
    print(json.dumps({"items": items}))
elif args[0] == "create" and args[1] == "job":
    state.setdefault("manual_jobs", []).append(args[2])
    save()
    print("job.batch/" + args[2] + " created")
elif args[0] == "delete":
    state["applied"] = [x for x in state["applied"] if not (x[0].lower() == args[1] and x[1] == args[2])]
    save()
else:
    print("")
'''


def secret_env() -> list:
    return [{"name": "U", "valueFrom": {"secretKeyRef": {"name": "db-credentials", "key": "POSTGRES_USER"}}}]


class FakeCluster(unittest.TestCase):
    """Run the gate end to end against a pretend kubectl."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.state_path = self.dir / "state.json"
        self.fake = self.dir / "kubectl"
        self.fake.write_text(FAKE_KUBECTL, encoding="utf-8")
        self.fake.chmod(self.fake.stat().st_mode | stat.S_IXUSR)
        self.fake.write_text(f"#!{sys.executable}\n" + FAKE_KUBECTL.split("\n", 1)[1], encoding="utf-8")
        self.state = {"context": "kind-bookstore", "served": PLAIN_KINDS, "applied": [], "mode": "ok", "warn": False}
        patcher = mock.patch.object(rg, "POLL_SECONDS", 0)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tree(self, files: dict[str, list[dict]]) -> Path:
        folder = self.dir / "tree" / "raw-manifests"
        folder.mkdir(parents=True)
        for name, docs in files.items():
            bodies = [d.body if isinstance(d, rg.Doc) else d for d in docs]
            (folder / name).write_text(yaml.safe_dump_all(bodies), encoding="utf-8")
        return self.dir / "tree"

    def gate(self, tree: Path, *extra: str, timeout: int = 5) -> tuple[int, str, str]:
        self.state_path.write_text(json.dumps(self.state), encoding="utf-8")
        argv = ["--variant", "raw", "--tree", str(tree), "--kubectl", str(self.fake), "--timeout", str(timeout), *extra]
        out, err = io.StringIO(), io.StringIO()
        env = {**os.environ, "FAKE_STATE": str(self.state_path)}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = rg.main(argv)
        return code, out.getvalue(), err.getvalue()

    def good_tree(self, with_cron: bool = False) -> Path:
        files = {
            "00-namespace.yaml": [NAMESPACE_DOC],
            "10-app.yaml": [deployment("catalog", env=secret_env())],
            "20-db.yaml": [doc("StatefulSet", "postgres", spec={"replicas": 1, "template": {"spec": {"containers": [{"name": "p"}]}}})],
            "21-job.yaml": [doc("Job", "db-migrate", "batch/v1", spec={"template": {"spec": {"containers": [{"name": "m"}]}}})],
        }
        if with_cron:
            files["22-cron.yaml"] = [doc("CronJob", "cleanup", "batch/v1", spec={"jobTemplate": {"spec": {"template": {"spec": {"containers": [{"name": "c"}]}}}}})]
        return self.tree(files)

    def test_a_deployment_that_comes_up_passes_and_gets_a_stand_in_secret(self) -> None:
        code, out, err = self.gate(self.good_tree())
        self.assertEqual(code, 0, out + err)
        self.assertIn("stand-in Secret/db-credentials", out)
        self.assertIn("workloads Ready or Complete", out)
        self.assertNotIn("password", out.lower())

    def test_a_cronjob_is_run_once_by_hand(self) -> None:
        code, out, err = self.gate(self.good_tree(with_cron=True))
        self.assertEqual(code, 0, out + err)
        self.assertIn("ran once as Job/gate-cleanup", out)

    def test_a_workload_that_never_becomes_ready_times_out_with_exit_1(self) -> None:
        self.state["mode"] = "stuck"
        code, out, err = self.gate(self.good_tree(), timeout=0)
        self.assertEqual(code, 1, out + err)
        self.assertIn("timed out waiting for", err)
        self.assertIn("Deployment/catalog", err)

    def test_a_failed_job_fails_at_once(self) -> None:
        self.state["mode"] = "job-fails"
        code, _, err = self.gate(self.good_tree(), timeout=600)
        self.assertEqual(code, 1)
        self.assertIn("Job/db-migrate", err)

    def test_a_pod_security_warning_on_apply_fails_even_though_kubectl_exits_0(self) -> None:
        self.state["warn"] = True
        code, _, err = self.gate(self.good_tree())
        self.assertEqual(code, 1)
        self.assertIn("breaks the restricted level", err)

    def test_a_namespace_without_the_restricted_label_fails(self) -> None:
        weak = yaml.safe_load(yaml.safe_dump(NAMESPACE_DOC))
        weak["metadata"]["labels"] = {}
        tree = self.tree({"00-namespace.yaml": [weak], "10-app.yaml": [deployment("catalog")]})
        code, _, err = self.gate(tree)
        self.assertEqual(code, 1)
        self.assertIn("not restricted", err)

    def test_a_crd_kind_without_a_pod_template_is_skipped_and_listed(self) -> None:
        monitor = doc("ServiceMonitor", "catalog", api="monitoring.coreos.com/v1", spec={"endpoints": []})
        tree = self.tree({"00-namespace.yaml": [NAMESPACE_DOC], "10-app.yaml": [deployment("catalog")], "80-sm.yaml": [monitor]})
        report = self.dir / "report.json"
        code, out, err = self.gate(tree, "--report", str(report))
        self.assertEqual(code, 0, out + err)
        self.assertIn("skipped", out)
        self.assertEqual(json.loads(report.read_text())["skipped"], ["ServiceMonitor/catalog"])

    def test_a_crd_kind_that_holds_a_pod_template_fails(self) -> None:
        rollout = doc("Rollout", "catalog", api="argoproj.io/v1alpha1", spec={"template": {"spec": {"containers": [{"name": "a"}]}}})
        tree = self.tree({"00-namespace.yaml": [NAMESPACE_DOC], "10-app.yaml": [deployment("catalog")], "30-rollout.yaml": [rollout]})
        code, _, err = self.gate(tree)
        self.assertEqual(code, 1)
        self.assertIn("go unrun", err)

    def test_a_secret_other_than_db_credentials_that_nobody_creates_fails(self) -> None:
        env = [{"name": "U", "valueFrom": {"secretKeyRef": {"name": "api-token", "key": "t"}}}]
        tree = self.tree({"00-namespace.yaml": [NAMESPACE_DOC], "10-app.yaml": [deployment("catalog", env=env)]})
        code, _, err = self.gate(tree)
        self.assertEqual(code, 1)
        self.assertIn("api-token", err)

    def test_a_context_that_is_not_kind_aborts_with_exit_2(self) -> None:
        self.state["context"] = "gke_project_zone_cluster"
        code, _, err = self.gate(self.good_tree())
        self.assertEqual(code, 2)
        self.assertIn("not a kind cluster", err)
        self.assertEqual(json.loads(self.state_path.read_text())["applied"], [])

    def test_a_named_context_is_allowed(self) -> None:
        self.state["context"] = "lab"
        code, out, err = self.gate(self.good_tree(), "--allow-context", "lab")
        self.assertEqual(code, 0, out + err)

    def test_a_form_with_no_workload_aborts_with_exit_2(self) -> None:
        tree = self.tree({"00-namespace.yaml": [NAMESPACE_DOC]})
        code, _, err = self.gate(tree)
        self.assertEqual(code, 2)
        self.assertIn("no workload", err)

    def test_the_snapshot_pods_are_applied_alone_and_deleted(self) -> None:
        pod = lambda name: doc("Pod", name, "v1", spec={"containers": [{"name": "c"}]})  # noqa: E731
        tree = self.tree(
            {
                "00-namespace.yaml": [NAMESPACE_DOC],
                "01-catalog-pod.yaml": [pod("catalog")],
                "02-catalog-pod-sidecar.yaml": [pod("catalog")],
                "10-app.yaml": [deployment("catalog")],
            }
        )
        report = self.dir / "report.json"
        code, out, err = self.gate(tree, "--report", str(report))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(out.count("snapshot Pod"), 2)
        workloads = json.loads(report.read_text())["workloads"]
        self.assertIn("Pod/catalog (01-catalog-pod.yaml)", workloads)
        self.assertIn("Pod/catalog (02-catalog-pod-sidecar.yaml)", workloads)
        self.assertEqual([k for k, v in json.loads(self.state_path.read_text()).items() if k == "applied"], ["applied"])
        left = [x for x in json.loads(self.state_path.read_text())["applied"] if x[0] == "Pod"]
        self.assertEqual(left, [])


@unittest.skipUnless(HAVE_RENDERERS, "needs helm and kubectl to render the Bookstore forms")
class RealForms(unittest.TestCase):
    """The forms the gate deploys in CI must stay deployable in the shapes it expects."""

    def forms(self) -> dict[str, tuple[list[rg.Doc], list]]:
        out = {}
        for variant in rg.VARIANTS:
            out[variant] = rg.render(variant, TREE, shutil.which("helm") or "helm", shutil.which("kubectl") or "kubectl")
        return out

    def test_every_form_creates_a_restricted_namespace_and_holds_workloads(self) -> None:
        for variant, (docs, _) in self.forms().items():
            with self.subTest(variant=variant):
                self.assertIsNone(rg.namespace_problem(docs))
                kinds = {d.kind for d in rg.expected_workloads(docs)}
                self.assertTrue({"Deployment", "StatefulSet", "Job", "CronJob"} <= kinds, kinds)

    def test_every_pod_template_in_every_form_is_a_kind_a_plain_cluster_serves(self) -> None:
        served = rg.parse_api_resources(PLAIN_KINDS)
        for variant, (docs, snapshots) in self.forms().items():
            with self.subTest(variant=variant):
                everything = docs + [d for _, group in snapshots for d in group]
                _, skipped = rg.split_unserved(everything, served)
                self.assertEqual([d.label() for d in skipped if rg.runs_pods(d)], [])

    def test_only_the_production_overlay_leaves_db_credentials_to_the_gate(self) -> None:
        for variant, (docs, snapshots) in self.forms().items():
            with self.subTest(variant=variant):
                everything = docs + [d for _, group in snapshots for d in group]
                expected = {"db-credentials"} if variant == "kustomize-prod" else set()
                self.assertEqual(set(rg.missing_secrets(everything)), expected)

    def test_the_raw_form_holds_two_snapshot_pods(self) -> None:
        _, snapshots = rg.render("raw", TREE, "helm", "kubectl")
        self.assertEqual([name for name, _ in snapshots], list(rg.SNAPSHOT_FILES))


if __name__ == "__main__":
    unittest.main()
