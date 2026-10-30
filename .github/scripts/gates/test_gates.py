#!/usr/bin/env python3
"""Unit tests for the security-first gate scripts.

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

Each gate section below is grouped by the script it covers. The tests use
temporary directories only and never touch the repository's chapters.
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

import admission_gate as ag
import evidence_gate as ev
import extract_blocks as eb
import static_gate as sg

FIXTURES = Path(__file__).resolve().parent / "fixtures"
HAVE_TRIVY = shutil.which("trivy") is not None

POD = textwrap.dedent(
    """\
    apiVersion: v1
    kind: Pod
    metadata:
      name: demo
    spec:
      containers:
        - name: app
          image: busybox
    """
)

ROLE = textwrap.dedent(
    """\
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: demo
    rules: []
    """
)

MARKER = "<!-- gate: insecure-on-purpose -->"


def fenced(body: str, lang: str = "yaml", indent: str = "") -> str:
    """Return body wrapped in a code fence, every line carrying indent."""
    lines = [f"{indent}```{lang}"]
    lines += [f"{indent}{ln}" if ln else ln for ln in body.rstrip("\n").split("\n")]
    lines.append(f"{indent}```")
    return "\n".join(lines) + "\n"


def write(root: Path, rel: str, text: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class ClassifyTests(unittest.TestCase):
    def test_plain_manifest_is_applyable(self):
        self.assertEqual(eb.classify(POD, False), ("applyable", ["Pod"]))

    def test_marker_on_preceding_line_classes_insecure(self):
        self.assertEqual(eb.classify(POD, marked=True)[0], "insecure")

    def test_helm_template_is_unparseable(self):
        klass, kinds = eb.classify("kind: Pod\nmetadata: {{ .x }}", False)
        self.assertEqual(klass, "unparseable")
        self.assertEqual(kinds, ["Pod"])

    def test_marked_helm_template_is_still_unparseable(self):
        # A block nobody can parse cannot be judged either way.
        self.assertEqual(eb.classify("kind: Pod\nname: {{ .x }}", True)[0], "unparseable")

    def test_broken_yaml_is_unparseable(self):
        self.assertEqual(eb.classify("kind: Pod\n  bad: [unclosed", False)[0], "unparseable")

    def test_multi_doc_reports_all_kinds(self):
        self.assertEqual(eb.classify(ROLE + "---\n" + POD, False)[1], ["Role", "Pod"])

    def test_placeholder_kind_is_unparseable(self):
        # A skeleton such as `kind: <Kind>` is not a manifest anyone can judge.
        body = "apiVersion: <group>/<version>\nkind: <Kind>\nmetadata:\n  name: x\n"
        self.assertEqual(eb.classify(body, False)[0], "unparseable")

    def test_nested_kind_alone_is_not_a_manifest(self):
        body = "subjects:\n  - kind: ServiceAccount\n    name: x\n"
        self.assertEqual(eb.top_level_kinds(body), [])


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "guide"
        self.out = Path(self._tmp.name) / "out"
        self.root.mkdir()

    def run_extract(self):
        return eb.extract(self.root, self.out)

    def test_block_without_kind_is_not_gated(self):
        write(self.root, "01-a/01-x.md", fenced("image: busybox\nreplicas: 2\n"))
        self.assertEqual(self.run_extract(), [])

    def test_marker_on_preceding_line_classes_insecure(self):
        text = f"Intro.\n\n{MARKER}\n\n" + fenced(POD)
        write(self.root, "05-s/02-x.md", text)
        (block,) = self.run_extract()
        self.assertEqual(block.klass, "insecure")

    def test_marker_not_nearest_nonblank_line_does_not_count(self):
        text = f"{MARKER}\n\nSome prose in between.\n\n" + fenced(POD)
        write(self.root, "05-s/02-x.md", text)
        (block,) = self.run_extract()
        self.assertEqual(block.klass, "applyable")

    def test_marker_applies_to_one_fence_only(self):
        text = f"{MARKER}\n" + fenced(POD) + "\nThen:\n\n" + fenced(POD)
        write(self.root, "05-s/02-x.md", text)
        first, second = self.run_extract()
        self.assertEqual((first.klass, second.klass), ("insecure", "applyable"))

    def test_helm_template_is_unparseable(self):
        write(self.root, "07-d/01-x.md", fenced("kind: Pod\nmetadata:\n  name: {{ .Values.n }}\n"))
        (block,) = self.run_extract()
        self.assertEqual(block.klass, "unparseable")

    def test_multi_doc_reports_all_kinds(self):
        write(self.root, "05-s/01-x.md", fenced(ROLE + "---\n" + POD))
        (block,) = self.run_extract()
        self.assertEqual(block.kinds, ["Role", "Pod"])

    def test_indented_fence_in_list_is_dedented(self):
        text = "1. Apply this:\n\n" + fenced(POD, indent="   ") + "\n2. Done.\n"
        write(self.root, "01-a/01-x.md", text)
        (block,) = self.run_extract()
        body = Path(block.path).read_text(encoding="utf-8")
        self.assertTrue(body.startswith("apiVersion: v1\nkind: Pod\n"), body)
        self.assertEqual(block.klass, "applyable")

    def test_yml_fence_is_accepted(self):
        write(self.root, "01-a/01-x.md", fenced(POD, lang="yml"))
        self.assertEqual(len(self.run_extract()), 1)

    def test_fence_info_string_attributes_are_ignored(self):
        write(self.root, "01-a/01-x.md", fenced(POD, lang='yaml title="pod.yaml"'))
        self.assertEqual(len(self.run_extract()), 1)

    def test_other_languages_are_not_extracted(self):
        write(self.root, "01-a/01-x.md", fenced(POD, lang="json") + fenced(POD, lang="bash"))
        self.assertEqual(self.run_extract(), [])

    def test_yaml_inside_a_longer_fence_is_not_extracted(self):
        inner = fenced(POD)
        text = "````markdown\n" + inner + "````\n"
        write(self.root, "01-a/01-x.md", text)
        self.assertEqual(self.run_extract(), [])

    def test_examples_and_part_18_are_excluded(self):
        write(self.root, "examples/bookstore/readme.md", fenced(POD))
        write(self.root, "18-attacking-and-hardening-the-cluster/01-x.md", fenced(POD))
        write(self.root, "01-a/01-x.md", fenced(POD))
        blocks = self.run_extract()
        self.assertEqual([b.chapter for b in blocks], ["01-a/01-x.md"])

    def test_index_counts_every_yaml_fence_and_line_is_the_opening_fence(self):
        text = "Top.\n\n" + fenced("image: x\n") + "\n" + fenced(POD)
        write(self.root, "01-a/01-x.md", text)
        (block,) = self.run_extract()
        self.assertEqual(block.index, 2)
        self.assertEqual(block.line, 7)

    def test_files_and_manifest_are_written(self):
        write(self.root, "01-core/01-pods.md", fenced(POD))
        (block,) = self.run_extract()
        self.assertEqual(Path(block.path).name, "01-core__01-pods.md__b01.yaml")
        manifest = json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest[0]["chapter"], "01-core/01-pods.md")
        self.assertEqual(manifest[0]["kinds"], ["Pod"])
        loaded = eb.load_manifest(self.out / "manifest.json")
        self.assertEqual(loaded, [block])


def blk(kinds, klass="applyable", chapter="01-a/01-x.md", path="unused.yaml"):
    return eb.Block(chapter, 1, 1, klass, list(kinds), path)


POD_BLOCK = blk(["Pod"])
MARKED_POD = blk(["Pod"], klass="insecure")
ROLLOUT_BLOCK = blk(["Rollout"])


class VerdictTests(unittest.TestCase):
    def test_workload_missing_a_core_check_fails(self):
        status, ids = sg.verdict(POD_BLOCK, {"KSV-0014"}, set())
        self.assertEqual((status, ids), ("fail", ["KSV-0014"]))

    def test_workload_failing_every_core_check_lists_them_in_core_order(self):
        _, ids = sg.verdict(POD_BLOCK, set(sg.CORE), set())
        self.assertEqual(ids, list(sg.CORE))

    def test_clean_workload_passes(self):
        self.assertEqual(sg.verdict(POD_BLOCK, set(), set()), ("pass", []))

    def test_noncore_low_finding_does_not_fail_a_workload(self):
        self.assertEqual(sg.verdict(POD_BLOCK, {"KSV-0011"}, set())[0], "pass")

    def test_workload_with_noncore_high_finding_fails(self):
        status, ids = sg.verdict(POD_BLOCK, {"KSV-0017"}, {"KSV-0017"})
        self.assertEqual((status, ids), ("fail", ["KSV-0017"]))

    def test_marked_block_failing_a_core_check_passes(self):
        self.assertEqual(sg.verdict(MARKED_POD, {"KSV-0012"}, {"KSV-0012"})[0], "pass")

    def test_marked_block_failing_only_a_core_check_passes(self):
        self.assertEqual(sg.verdict(MARKED_POD, {"KSV-0014"}, set())[0], "pass")

    def test_marked_block_passing_everything_is_stale(self):
        self.assertEqual(sg.verdict(MARKED_POD, set(), set())[0], "stale-marker")

    def test_marked_block_with_only_a_low_noncore_finding_is_stale(self):
        self.assertEqual(sg.verdict(MARKED_POD, {"KSV-0011"}, set())[0], "stale-marker")

    def test_crd_only_block_is_not_evaluated(self):
        status, ids = sg.verdict(ROLLOUT_BLOCK, set(), set())
        self.assertEqual((status, ids), ("not-evaluated", ["Rollout"]))

    def test_marked_crd_block_is_not_evaluated_not_stale(self):
        self.assertEqual(sg.verdict(blk(["Rollout"], klass="insecure"), set(), set())[0], "not-evaluated")

    def test_workload_plus_crd_with_no_findings_is_not_a_pass(self):
        # The Rollout carries a pod template the scanner never read.
        self.assertEqual(sg.verdict(blk(["Service", "Rollout"]), set(), set())[0], "not-evaluated")

    def test_findings_outrank_not_evaluated(self):
        self.assertEqual(sg.verdict(blk(["Pod", "Rollout"]), {"KSV-0001"}, set())[0], "fail")

    def test_role_plus_pod_is_judged_as_workload(self):
        mixed = blk(["Role", "Pod"])
        self.assertEqual(sg.verdict(mixed, {"KSV-0030"}, set()), ("fail", ["KSV-0030"]))
        self.assertEqual(sg.verdict(blk(["Pod", "Role"]), {"KSV-0030"}, set())[0], "fail")
        self.assertEqual(sg.verdict(mixed, set(), set())[0], "pass")

    def test_non_workload_with_high_finding_fails(self):
        status, ids = sg.verdict(blk(["Role"]), {"KSV-0045"}, {"KSV-0045"})
        self.assertEqual((status, ids), ("fail", ["KSV-0045"]))

    def test_core_ids_do_not_apply_to_non_workloads(self):
        self.assertEqual(sg.verdict(blk(["Role"]), {"KSV-0014"}, set())[0], "pass")

    def test_inert_builtin_kind_passes(self):
        self.assertEqual(sg.verdict(blk(["NetworkPolicy"]), set(), set())[0], "pass")

    def test_unparseable_in_scope_fails(self):
        status, ids = sg.verdict(blk(["Pod"], klass="unparseable"), set(), set())
        self.assertEqual((status, ids), ("fail", ["unparseable"]))


class BannerTests(unittest.TestCase):
    def test_banner_first_line_passes(self):
        body = "# INSECURE ON PURPOSE: a privileged pod. Lab cluster only.\n" + POD
        self.assertTrue(sg.banner_ok(body))

    def test_wrapped_banner_passes(self):
        body = "# INSECURE ON PURPOSE: a privileged pod that\n# mounts the node. Lab cluster only.\n" + POD
        self.assertTrue(sg.banner_ok(body))

    def test_missing_or_wrong_banner_fails(self):
        self.assertFalse(sg.banner_ok(POD))
        self.assertFalse(sg.banner_ok("# INSECURE ON PURPOSE: x.\n" + POD))
        self.assertFalse(sg.banner_ok("# note\n# INSECURE ON PURPOSE: x. Lab cluster only.\n" + POD))


DEPLOY = textwrap.dedent(
    """\
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: demo
    spec:
      template:
        spec:
          containers:
            - name: app
              image: busybox
    """
)


class CompletenessTests(unittest.TestCase):
    """Trivy reports a clean file for a document it cannot read, so check first."""

    def test_complete_workload_has_no_gaps(self):
        self.assertEqual(sg.incomplete_documents(DEPLOY), [])

    def test_workload_without_containers_is_a_gap(self):
        body = DEPLOY.split("      containers:")[0] + "      priorityClassName: p\n"
        self.assertEqual(sg.incomplete_documents(body), ["Deployment: no containers"])

    def test_second_document_without_containers_is_a_gap(self):
        body = ROLE + "---\n" + DEPLOY.replace("containers:", "initContainers:")
        self.assertEqual(sg.incomplete_documents(body), ["Deployment: no containers"])

    def test_missing_api_version_or_metadata_is_a_gap(self):
        self.assertEqual(sg.incomplete_documents(DEPLOY.replace("apiVersion: apps/v1\n", "")), ["Deployment: no apiVersion"])
        no_meta = DEPLOY.replace("metadata:\n  name: demo\n", "")
        self.assertEqual(sg.incomplete_documents(no_meta), ["Deployment: no metadata"])

    def test_cronjob_pod_spec_is_found_under_job_template(self):
        cron = (
            "apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: c\nspec:\n  schedule: '* * * * *'\n"
            "  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n"
            "            - name: a\n              image: busybox\n"
        )
        self.assertEqual(sg.incomplete_documents(cron), [])

    def test_bare_pod_spec_is_found_at_the_top(self):
        self.assertEqual(sg.incomplete_documents(POD), [])

    def test_unchecked_kinds_are_not_inspected(self):
        self.assertEqual(sg.incomplete_documents("kind: Rollout\nspec: {}\n"), [])

    def test_judge_turns_a_clean_but_incomplete_block_into_not_evaluated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.yaml"
            path.write_text(DEPLOY.replace("containers:", "initContainers:"), encoding="utf-8")
            block = blk(["Deployment"], path=str(path))
            clean = sg.Scan(set(), set(), True)
            self.assertEqual(sg.judge(block, clean), ("not-evaluated", ["Deployment: no containers"]))
            # A real finding still wins over the gap.
            failing = sg.Scan({"KSV-0014"}, set(), True)
            self.assertEqual(sg.judge(block, failing)[0], "fail")
            # So does a silent scanner, reported as its own reason.
            silent = sg.Scan(set(), set(), False)
            self.assertEqual(sg.judge(block, silent)[0], "not-evaluated")


class ScopeTests(unittest.TestCase):
    BLOCKS = [blk(["Pod"], chapter="01-a/01-x.md"), blk(["Pod"], chapter="05-s/02-y.md")]

    def test_no_scope_puts_everything_in_scope(self):
        self.assertEqual(sg.in_scope(self.BLOCKS[0].chapter, []), True)

    def test_exact_chapter_and_directory_prefix(self):
        self.assertTrue(sg.in_scope("01-a/01-x.md", ["01-a/01-x.md"]))
        self.assertTrue(sg.in_scope("01-a/01-x.md", ["01-a"]))
        self.assertTrue(sg.in_scope("01-a/01-x.md", ["01-a/"]))
        self.assertFalse(sg.in_scope("01-a/01-x.md", ["01-"]))
        self.assertFalse(sg.in_scope("05-s/02-y.md", ["01-a/01-x.md"]))

    def test_scope_matching_no_block_is_a_control_failure(self):
        with self.assertRaises(sg.ControlError):
            sg.check_scopes(self.BLOCKS, ["01-a/01-typo.md"])
        sg.check_scopes(self.BLOCKS, ["01-a/01-x.md"])


class ControlTests(unittest.TestCase):
    ALL = {id_: "HIGH" for id_ in sg.CORE}

    def scan(self, violating, hardened=()):
        def entry(ids):
            return sg.Scan(failed=set(ids), high_crit=set(), seen=True)

        return {
            sg.CONTROL_VIOLATING: entry(violating),
            sg.CONTROL_HARDENED: entry(hardened),
        }

    def test_control_with_all_core_ids_is_accepted(self):
        sg.check_control(self.scan(sg.CORE))

    def test_renamed_check_id_aborts(self):
        renamed = [i for i in sg.CORE if i != "KSV-0030"] + ["KSV-9999"]
        with self.assertRaisesRegex(sg.ControlError, "KSV-0030"):
            sg.check_control(self.scan(renamed))

    def test_empty_results_abort(self):
        with self.assertRaises(sg.ControlError):
            sg.check_control({})

    def test_hardened_control_that_fails_aborts(self):
        with self.assertRaisesRegex(sg.ControlError, "hardened"):
            sg.check_control(self.scan(sg.CORE, hardened=["KSV-0014"]))


@unittest.skipUnless(HAVE_TRIVY, "trivy is not on PATH")
class RealTrivyTests(unittest.TestCase):
    def test_real_trivy_flags_violating_and_clears_hardened(self):
        results = sg.trivy_scan(FIXTURES)
        violating = results["violating-deployment.yaml"]
        hardened = results["hardened-deployment.yaml"]
        self.assertTrue(set(sg.CORE) <= violating.failed, violating.failed)
        self.assertEqual(set(sg.CORE) & hardened.failed, set())
        self.assertEqual(hardened.high_crit, set())

    def test_scan_files_runs_the_control_beside_every_scan(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "pod.yaml"
            target.write_text(POD, encoding="utf-8")
            results = sg.scan_files([target])
        self.assertTrue(set(sg.CORE) <= results[target].failed)
        self.assertNotIn(sg.CONTROL_VIOLATING, [p.name for p in results])


@unittest.skipUnless(HAVE_TRIVY, "trivy is not on PATH")
class StaticGateCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def manifest(self, entries):
        blocks = []
        for i, (chapter, fixture, kinds) in enumerate(entries):
            path = self.tmp / f"b{i}.yaml"
            shutil.copy(FIXTURES / fixture, path)
            blocks.append(eb.Block(chapter, 1, 1, "applyable", kinds, str(path)))
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps([vars(b) for b in blocks]), encoding="utf-8")
        return manifest

    def run_gate(self, manifest, *args):
        report = self.tmp / "report.json"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rc = sg.main(["--manifest", str(manifest), "--report", str(report), *args])
        return rc, json.loads(report.read_text(encoding="utf-8")) if report.exists() else None

    def test_exit_codes_follow_scope(self):
        manifest = self.manifest([
            ("a/good.md", "hardened-deployment.yaml", ["Deployment"]),
            ("b/bad.md", "violating-deployment.yaml", ["Deployment"]),
        ])
        rc, report = self.run_gate(manifest, "--scope", "a/good.md")
        self.assertEqual(rc, 0)
        rc, report = self.run_gate(manifest, "--scope", "b/bad.md")
        self.assertEqual(rc, 1)
        by_chapter = {b["chapter"]: b for b in report["blocks"]}
        self.assertEqual(by_chapter["b/bad.md"]["status"], "fail")
        self.assertTrue(by_chapter["b/bad.md"]["in_scope"])
        self.assertFalse(by_chapter["a/good.md"]["in_scope"])
        # No scope means everything is in scope, so the bad block fails the run.
        self.assertEqual(self.run_gate(manifest)[0], 1)

    def test_scope_typo_exits_two(self):
        manifest = self.manifest([("a/good.md", "hardened-deployment.yaml", ["Deployment"])])
        self.assertEqual(self.run_gate(manifest, "--scope", "a/god.md")[0], 2)


WARN_OUT = (
    'Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false '
    '(container "app" must set securityContext.allowPrivilegeEscalation=false)\n'
    "deployment.apps/x created (server dry run)\n"
)
FORBIDDEN_OUT = (
    'Error from server (Forbidden): error when creating "STDIN": pods "x" is forbidden: '
    'violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false\n'
)
NO_CRD_OUT = (
    'error: resource mapping not found for name: "x" namespace: "gate-restricted" from "STDIN": '
    'no matches for kind "Rollout" in version "argoproj.io/v1alpha1"\n'
    "ensure CRDs are installed first\n"
)


class ClassifyOutputTests(unittest.TestCase):
    def test_warning_with_exit_zero_is_a_violation(self):
        self.assertEqual(ag.classify_output(0, WARN_OUT), "violation")

    def test_forbidden_pod_is_a_violation(self):
        self.assertEqual(ag.classify_output(1, FORBIDDEN_OUT), "violation")

    def test_no_matches_for_kind_is_missing_crd(self):
        self.assertEqual(ag.classify_output(1, NO_CRD_OUT), "missing-crd")

    def test_clean_dry_run_passes(self):
        self.assertEqual(ag.classify_output(0, "deployment.apps/x created (server dry run)\n"), "pass")

    def test_unrelated_warning_with_exit_zero_still_passes(self):
        out = "Warning: v1 Endpoints is deprecated in v1.33+\nservice/x created (server dry run)\n"
        self.assertEqual(ag.classify_output(0, out), "pass")

    def test_other_nonzero_exit_is_error(self):
        self.assertEqual(ag.classify_output(1, 'Error from server (Invalid): spec.replicas: Invalid value: -1\n'), "error")
        self.assertEqual(ag.classify_output(1, ""), "error")

    def test_violation_outranks_a_missing_crd_in_the_same_block(self):
        self.assertEqual(ag.classify_output(1, WARN_OUT + NO_CRD_OUT), "violation")


class RetargetTests(unittest.TestCase):
    def test_retarget_overrides_namespace_and_skips_cluster_scoped(self):
        docs = [
            {"kind": "Pod", "metadata": {"name": "a", "namespace": "bookstore"}},
            {"kind": "Service", "metadata": {"name": "b"}},
            {"kind": "Namespace", "metadata": {"name": "bookstore"}},
            {"kind": "ClusterRole", "metadata": {"name": "c"}},
        ]
        original = json.loads(json.dumps(docs))
        out = ag.retarget(docs, "gate-restricted", {"Namespace", "ClusterRole"})
        self.assertEqual(out[0]["metadata"]["namespace"], "gate-restricted")
        self.assertEqual(out[1]["metadata"]["namespace"], "gate-restricted")
        self.assertNotIn("namespace", out[2]["metadata"])
        self.assertNotIn("namespace", out[3]["metadata"])
        self.assertEqual(docs, original, "the input must not be modified")

    def test_retarget_adds_metadata_when_missing(self):
        (doc,) = ag.retarget([{"kind": "Pod"}], "ns", set())
        self.assertEqual(doc["metadata"]["namespace"], "ns")


FAKE_KUBECTL = """#!{python}
import os, sys
args = sys.argv[1:]
if "api-resources" in args:
    print("namespaces   ns   v1   false   Namespace")
    print("clusterroles      rbac.authorization.k8s.io/v1   false   ClusterRole")
    sys.exit(0)
body = sys.stdin.read()
if "--dry-run=server" not in args:
    sys.exit(0)  # creating the gate namespace
if "gate-control-violating" in body and not os.environ.get("FAKE_BLIND"):
    sys.stderr.write({warn!r})
    print("deployment.apps/gate-control-violating created (server dry run)")
elif "VIOLATE" in body:
    sys.stderr.write({warn!r})
    print("deployment.apps/x created (server dry run)")
elif "Rollout" in body:
    sys.stderr.write({nocrd!r})
    sys.exit(1)
elif "BOOM" in body:
    sys.stderr.write("Error from server (Invalid): boom\\n")
    sys.exit(1)
else:
    print("object created (server dry run)")
"""


class AdmissionCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.kubectl = self.tmp / "kubectl"
        self.kubectl.write_text(
            FAKE_KUBECTL.format(python=sys.executable, warn=WARN_OUT, nocrd=NO_CRD_OUT),
            encoding="utf-8",
        )
        self.kubectl.chmod(self.kubectl.stat().st_mode | stat.S_IEXEC)

    def manifest(self, entries):
        blocks = []
        for i, (chapter, klass, kind, extra) in enumerate(entries):
            path = self.tmp / f"b{i}.yaml"
            path.write_text(
                f"apiVersion: v1\nkind: {kind}\nmetadata:\n  name: n{i}\n  namespace: bookstore\n{extra}",
                encoding="utf-8",
            )
            blocks.append(eb.Block(chapter, 1, 1, klass, [kind], str(path)))
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps([vars(b) for b in blocks]), encoding="utf-8")
        return manifest

    def run_gate(self, manifest, *args):
        report = self.tmp / "report.json"
        argv = ["--manifest", str(manifest), "--kubectl", str(self.kubectl), "--report", str(report), *args]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rc = ag.main(argv)
        return rc, (json.loads(report.read_text(encoding="utf-8")) if report.exists() else None)

    def statuses(self, report):
        return {(b["chapter"]): b["status"] for b in report["blocks"]}

    def test_each_outcome_gets_its_own_status_and_exit_code(self):
        manifest = self.manifest([
            ("a.md", "applyable", "ConfigMap", ""),
            ("b.md", "applyable", "ConfigMap", "data:\n  x: VIOLATE\n"),
            ("c.md", "applyable", "Rollout", ""),
            ("d.md", "applyable", "ConfigMap", "data:\n  x: BOOM\n"),
            ("e.md", "insecure", "ConfigMap", "data:\n  x: VIOLATE\n"),
            ("f.md", "unparseable", "ConfigMap", ""),
        ])
        rc, report = self.run_gate(manifest, "--scope", "a.md")
        self.assertEqual(rc, 0)
        self.assertEqual(
            self.statuses(report),
            {"a.md": "pass", "b.md": "violation", "c.md": "missing-crd", "d.md": "error",
             "e.md": "skipped-insecure", "f.md": "unparseable"},
        )
        for chapter, expected in (("b.md", 1), ("c.md", 0), ("d.md", 1), ("e.md", 0), ("f.md", 1)):
            self.assertEqual(self.run_gate(manifest, "--scope", chapter)[0], expected, chapter)

    def test_blind_cluster_aborts_with_exit_two(self):
        manifest = self.manifest([("a.md", "applyable", "ConfigMap", "")])
        os.environ["FAKE_BLIND"] = "1"
        self.addCleanup(os.environ.pop, "FAKE_BLIND", None)
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 2)
        self.assertIsNone(report, "no result may be written when the control failed")

    def test_scope_typo_exits_two(self):
        manifest = self.manifest([("a.md", "applyable", "ConfigMap", "")])
        self.assertEqual(self.run_gate(manifest, "--scope", "z.md")[0], 2)

    def test_missing_kubectl_exits_two(self):
        manifest = self.manifest([("a.md", "applyable", "ConfigMap", "")])
        self.kubectl.unlink()
        self.assertEqual(self.run_gate(manifest)[0], 2)


OUTPUT = "<!-- gate: output -->"

TRANSCRIPT = textwrap.dedent(
    """\
    $ kubectl get pods -n lab
    NAME    READY   STATUS    RESTARTS   AGE
    web-0   1/1     Running   0          12s
    web-1   1/1     Running   0          9s
    $ kubectl get svc -n lab
    NAME   TYPE        CLUSTER-IP     PORT(S)
    web    ClusterIP   10.96.12.40    80/TCP
    """
)


class OutputBlockTests(unittest.TestCase):
    def test_only_fences_marked_as_output_are_returned(self):
        md = (
            "Run it:\n\n```bash\nkubectl get pods\n```\n\n"
            + OUTPUT + "\n\n```text\nNAME  READY\nweb-0 1/1\n```\n\n"
            "```text\nunmarked output\n```\n"
        )
        self.assertEqual(ev.output_blocks(md), ["NAME  READY\nweb-0 1/1"])

    def test_marker_must_be_the_nearest_nonblank_line(self):
        md = OUTPUT + "\n\nprose in between\n\n```text\nx\n```\n"
        self.assertEqual(ev.output_blocks(md), [])

    def test_indented_output_fence_is_dedented(self):
        md = "1. Check:\n\n   " + OUTPUT + "\n\n   ```text\n   a\n   b\n   ```\n"
        self.assertEqual(ev.output_blocks(md), ["a\nb"])


class MissingLinesTests(unittest.TestCase):
    def test_output_present_in_order_passes(self):
        block = "NAME    READY   STATUS    RESTARTS   AGE\nweb-0   1/1     Running   0          12s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), [])

    def test_output_lines_out_of_order_are_missing(self):
        block = "web-0   1/1     Running   0          12s\nNAME    READY   STATUS    RESTARTS   AGE"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), ["NAME    READY   STATUS    RESTARTS   AGE"])

    def test_invented_line_is_missing(self):
        block = "web-0   1/1     Running   0          12s\nweb-9   1/1     Running   0          1s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), ["web-9   1/1     Running   0          1s"])

    def test_elision_line_is_allowed(self):
        block = "NAME    READY   STATUS    RESTARTS   AGE\n# ...\nweb-1   1/1     Running   0          9s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), [])

    def test_omitting_a_line_without_an_elision_is_missing(self):
        block = "NAME    READY   STATUS    RESTARTS   AGE\nweb-1   1/1     Running   0          9s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), ["web-1   1/1     Running   0          9s"])

    def test_elision_matches_nothing_in_the_transcript(self):
        self.assertEqual(ev.missing_lines("# ...", TRANSCRIPT), [])

    def test_trailing_whitespace_and_crlf_do_not_matter(self):
        block = "NAME    READY   STATUS    RESTARTS   AGE   \nweb-0   1/1     Running   0          12s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT.replace("\n", "\r\n")), [])

    def test_a_line_cannot_be_matched_twice(self):
        block = "web-0   1/1     Running   0          12s\n# ...\nweb-0   1/1     Running   0          12s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), ["web-0   1/1     Running   0          12s"])

    def test_one_miss_does_not_cascade(self):
        block = "invented\nweb-0   1/1     Running   0          12s\nweb-1   1/1     Running   0          9s"
        self.assertEqual(ev.missing_lines(block, TRANSCRIPT), ["invented"])


class LeakTests(unittest.TestCase):
    def test_public_ip_home_path_and_email_leak(self):
        text = "node 8.8.4.4 ready\ncd /Users/jane/work\nssh /home/jane/.ssh\nowner jane@corp.io\n"
        self.assertEqual(ev.leaks(text), ["8.8.4.4", "/Users/jane", "/home/jane", "jane@corp.io"])

    def test_private_ips_and_metadata_endpoint_do_not_leak(self):
        for ip in ("10.244.0.5", "172.18.0.2", "127.0.0.1", "169.254.169.254", "192.168.1.5", "0.0.0.0"):
            self.assertEqual(ev.leaks(f"addr {ip} ok"), [], ip)

    def test_tailnet_address_leaks(self):
        self.assertEqual(ev.leaks("peer 100.64.1.9"), ["100.64.1.9"])

    def test_container_home_directories_do_not_leak(self):
        self.assertEqual(ev.leaks("HOME=/home/nonroot and /home/node/app"), [])

    def test_version_numbers_and_digests_do_not_leak(self):
        self.assertEqual(ev.leaks("kubectl v1.37.2 image@sha256:abc123 chart 3.1.0"), [])

    def test_aws_account_and_key_ids_leak(self):
        text = "role arn:aws:iam::123456789012:role/x key AKIAABCDEFGHIJKLMNOP"
        self.assertEqual(ev.leaks(text), ["arn:aws:iam::123456789012:", "AKIAABCDEFGHIJKLMNOP"])

    def test_duplicates_are_reported_once(self):
        self.assertEqual(ev.leaks("8.8.4.4 and again 8.8.4.4"), ["8.8.4.4"])

    def test_invalid_octets_are_not_addresses(self):
        self.assertEqual(ev.leaks("999.300.1.1"), [])


class EvidenceCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.transcript = self.tmp / "05-02.txt"
        self.transcript.write_text(TRANSCRIPT, encoding="utf-8")

    def run_gate(self, chapter_text, transcript=None):
        chapter = self.tmp / "ch.md"
        chapter.write_text(chapter_text, encoding="utf-8")
        argv = ["--chapter", str(chapter), "--transcript", str(transcript or self.transcript)]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            return ev.main(argv), out.getvalue()

    def chapter(self, body):
        return f"# Lab\n\n{OUTPUT}\n\n```text\n{body}\n```\n"

    def test_matching_output_passes(self):
        rc, _ = self.run_gate(self.chapter("web-0   1/1     Running   0          12s"))
        self.assertEqual(rc, 0)

    def test_invented_output_fails_and_names_the_line(self):
        rc, out = self.run_gate(self.chapter("web-7   1/1     Running   0          12s"))
        self.assertEqual(rc, 1)
        self.assertIn("web-7", out)

    def test_leak_in_the_transcript_fails(self):
        leaky = self.tmp / "leaky.txt"
        leaky.write_text(TRANSCRIPT + "connected to 8.8.4.4\n", encoding="utf-8")
        rc, out = self.run_gate(self.chapter("web-0   1/1     Running   0          12s"), leaky)
        self.assertEqual(rc, 1)
        self.assertIn("8.8.4.4", out)

    def test_chapter_without_output_blocks_aborts(self):
        rc, _ = self.run_gate("# Lab\n\n```text\nnothing marked\n```\n")
        self.assertEqual(rc, 2)

    def test_empty_or_missing_transcript_aborts(self):
        empty = self.tmp / "empty.txt"
        empty.write_text("\n", encoding="utf-8")
        self.assertEqual(self.run_gate(self.chapter("x"), empty)[0], 2)
        self.assertEqual(self.run_gate(self.chapter("x"), self.tmp / "nope.txt")[0], 2)


if __name__ == "__main__":
    unittest.main()
