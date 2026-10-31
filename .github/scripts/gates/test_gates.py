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
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import yaml

import admission_gate as ag
import evidence_gate as ev
import extract_blocks as eb
import static_gate as sg

FIXTURES = Path(__file__).resolve().parent / "fixtures"
HAVE_TRIVY = shutil.which("trivy") is not None
REQUIRE_TRIVY = os.environ.get("REQUIRE_TRIVY") == "1"

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

    def test_other_languages_without_a_manifest_are_not_extracted(self):
        write(self.root, "01-a/01-x.md", fenced("kubectl get pods\n", lang="bash") + fenced("a: 1\n", lang="json"))
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


class ManifestSourceTests(unittest.TestCase):
    """G1 must see every manifest a reader applies, not only column-zero yaml fences."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "guide"
        self.out = Path(self._tmp.name) / "out"
        self.root.mkdir()

    def extract_text(self, text, chapter="01-a/01-x.md"):
        write(self.root, chapter, text)
        return eb.extract(self.root, self.out)

    def test_heredoc_manifest_is_extracted(self):
        sh = "kubectl apply -f - <<EOF\n" + POD + "EOF\n"
        (block,) = self.extract_text(fenced(sh, lang="bash"))
        self.assertEqual((block.source, block.klass, block.kinds), ("heredoc", "applyable", ["Pod"]))
        self.assertEqual(Path(block.path).read_text(encoding="utf-8"), POD)

    def test_heredoc_delimiter_styles(self):
        tabbed = "".join("\t" + line + "\n" for line in POD.splitlines())
        for name, text in {
            "quoted": "cat <<'EOF' | kubectl apply -f -\n" + POD + "EOF\n",
            "double-quoted and spaced": 'kubectl apply -f - << "END"\n' + POD + "END\n",
            "escaped": "kubectl apply -f - <<\\EOF\n" + POD + "EOF\n",
            "dash with tabs": "kubectl apply -f - <<-EOF\n" + tabbed + "\tEOF\n",
            "unclosed": "kubectl apply -f - <<EOF\n" + POD,
        }.items():
            with self.subTest(name):
                (block,) = self.extract_text(fenced(text, lang="sh"))
                self.assertEqual((block.source, block.kinds), ("heredoc", ["Pod"]))

    def test_each_heredoc_in_a_fence_is_its_own_block(self):
        text = "kubectl apply -f - <<A\n" + POD + "A\nkubectl apply -f - <<B\n" + ROLE + "B\n"
        blocks = self.extract_text(fenced(text, lang="bash"))
        self.assertEqual([(b.source, b.index, b.kinds) for b in blocks], [("heredoc", 1, ["Pod"]), ("heredoc", 2, ["Role"])])
        self.assertEqual(len({b.path for b in blocks}), 2)

    def test_heredoc_that_is_not_a_manifest_is_ignored(self):
        text = "cat > run.sh <<EOF\necho hi\nEOF\nx=$((1<<3))\n"
        self.assertEqual(self.extract_text(fenced(text, lang="bash")), [])

    def test_marker_before_a_shell_fence_marks_its_heredocs(self):
        text = MARKER + "\n\n" + fenced("kubectl apply -f - <<EOF\n" + POD + "EOF\n", lang="bash")
        (block,) = self.extract_text(text, chapter="05-s/01-x.md")
        self.assertEqual(block.klass, "insecure")

    def test_manifest_in_a_here_string_is_an_unextracted_failure(self):
        text = "kubectl apply -f - <<<'" + POD + "'\n"
        (block,) = self.extract_text(fenced(text, lang="bash"))
        self.assertEqual((block.source, block.klass, block.note), ("unextracted", "unparseable", "unextracted-manifest"))
        self.assertEqual(block.kinds, ["Pod"])

    def test_bare_kind_in_a_text_fence_fails_unless_captured_output_or_markdown(self):
        (block,) = self.extract_text(fenced("kind: Pod\nmetadata: {}\n", lang="text"))
        self.assertEqual(block.klass, "unparseable")
        captured = "<!-- gate: output -->\n\n" + fenced("kind: Pod\nmetadata: {}\n", lang="text")
        self.assertEqual(self.extract_text(captured), [])
        self.assertEqual(self.extract_text(fenced("kind: Pod\n", lang="markdown")), [])

    def test_flow_style_json_and_quoted_key_manifests_in_a_yaml_fence_are_extracted(self):
        flow = "{apiVersion: v1, kind: Pod, metadata: {name: x}, spec: {containers: [{name: a, image: busybox}]}}\n"
        as_json = json.dumps(yaml.safe_load(POD)) + "\n"
        quoted = '"apiVersion": v1\n"kind": Pod\n"metadata": {"name": "x"}\n'
        for name, body in {"flow": flow, "json": as_json, "quoted": quoted}.items():
            with self.subTest(name):
                (block,) = self.extract_text(fenced(body))
                self.assertEqual((block.source, block.klass, block.kinds), ("yaml", "applyable", ["Pod"]))

    def test_json_fence_that_is_a_manifest_is_extracted(self):
        (block,) = self.extract_text(fenced(json.dumps(yaml.safe_load(POD)), lang="json"))
        self.assertEqual((block.source, block.kinds), ("fence", ["Pod"]))

    def test_manifest_is_decided_from_parsed_documents(self):
        self.assertTrue(eb.is_manifest("{apiVersion: v1, kind: Pod}"))
        self.assertTrue(eb.is_manifest("kind: Pod\nmetadata: {{ .x }}"))  # broken, still a manifest
        self.assertFalse(eb.is_manifest("image: busybox\nreplicas: 2\n"))
        self.assertFalse(eb.is_manifest("spec:\n  template:\n    kind: Pod\n"))

    def test_cli_exits_two_when_the_guide_holds_no_manifest(self):
        write(self.root, "01-a/01-x.md", fenced("image: busybox\n"))
        argv = ["--root", str(self.root), "--out", str(self.out)]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(eb.main(argv), 2)
            write(self.root, "01-a/01-y.md", fenced(POD))
            self.assertEqual(eb.main(argv), 0)


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


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


HARDENED = fixture("hardened-deployment.yaml")


def variant(mutate) -> str:
    """Return the hardened Deployment after mutate(doc) has changed its parsed form."""
    doc = yaml.safe_load(HARDENED)
    mutate(doc)
    return yaml.safe_dump(doc, sort_keys=False)


def pod_and_container(doc):
    pod = doc["spec"]["template"]["spec"]
    return pod, pod["containers"][0]


class BaselineCrossCheckTests(unittest.TestCase):
    """Trivy reads a null securityContext as clean and trusts pod-level values."""

    def test_null_security_context_everywhere_fails_every_core_check(self):
        failed, notes = sg.baseline_failures(fixture("violating-null-securitycontext.yaml"))
        self.assertEqual((failed, notes), (set(sg.CORE), {"null-securityContext"}))

    def test_container_override_of_run_as_non_root_fails(self):
        failed, notes = sg.baseline_failures(fixture("violating-runasnonroot-override.yaml"))
        self.assertEqual((failed, notes), ({"KSV-0012"}, set()))

    def test_run_as_user_zero_fails_even_with_run_as_non_root_true(self):
        failed, notes = sg.baseline_failures(fixture("violating-runasuser-zero.yaml"))
        self.assertEqual((failed, notes), ({"KSV-0012"}, set()))

    def test_hardened_workload_has_no_findings(self):
        self.assertEqual(sg.baseline_failures(HARDENED), (set(), set()))

    def test_null_container_context_under_a_hardened_pod_context(self):
        def mutate(doc):
            pod_and_container(doc)[1]["securityContext"] = None

        failed, notes = sg.baseline_failures(variant(mutate))
        # The pod level still supplies runAsNonRoot and the seccomp profile.
        self.assertEqual(failed, {"KSV-0014", "KSV-0001", "KSV-0003"})
        self.assertEqual(notes, {"null-securityContext"})

    def test_non_mapping_security_context_is_named_as_such(self):
        def mutate(doc):
            pod_and_container(doc)[0]["securityContext"] = "restricted"

        failed, notes = sg.baseline_failures(variant(mutate))
        self.assertEqual(notes, {"non-mapping-securityContext"})
        self.assertIn("KSV-0012", failed)

    def test_container_run_as_user_overrides_a_pod_level_zero(self):
        def mutate(doc):
            pod, container = pod_and_container(doc)
            pod["securityContext"]["runAsUser"] = 0
            container["securityContext"]["runAsUser"] = 65532

        self.assertEqual(sg.baseline_failures(variant(mutate)), (set(), set()))

    def test_container_level_run_as_user_zero_fails(self):
        def mutate(doc):
            pod_and_container(doc)[1]["securityContext"]["runAsUser"] = 0

        self.assertEqual(sg.baseline_failures(variant(mutate))[0], {"KSV-0012"})

    def test_init_containers_are_cross_checked_too(self):
        def mutate(doc):
            pod, container = pod_and_container(doc)
            init = yaml.safe_load(yaml.safe_dump(container))
            init["name"] = "init"
            init["securityContext"]["runAsNonRoot"] = False
            pod["initContainers"] = [init]

        self.assertEqual(sg.baseline_failures(variant(mutate))[0], {"KSV-0012"})

    def test_non_workloads_are_not_inspected(self):
        self.assertEqual(sg.baseline_failures(ROLE + "---\nkind: Rollout\nspec:\n  securityContext:\n"), (set(), set()))

    def test_judge_fails_a_block_trivy_reads_as_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in sg.BASELINE_CONTROLS:
                path = Path(tmp) / name
                path.write_text(fixture(name), encoding="utf-8")
                block = blk(["Deployment"], path=str(path))
                status, ids = sg.judge(block, sg.Scan(set(), set(), True))
                self.assertEqual(status, "fail", name)
                self.assertIn("KSV-0012", ids, name)

    def test_the_control_check_accepts_the_shipped_fixtures(self):
        sg.check_baseline_control()

    def test_the_control_check_aborts_when_the_cross_check_goes_blind(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in [*sg.BASELINE_CONTROLS, "hardened-deployment.yaml"]:
                shutil.copy(FIXTURES / name, tmp)
            Path(tmp, "violating-runasuser-zero.yaml").write_text(HARDENED, encoding="utf-8")
            with mock.patch.object(sg, "FIXTURES", Path(tmp)):
                with self.assertRaisesRegex(sg.ControlError, "violating-runasuser-zero"):
                    sg.check_baseline_control()


class MarkerPolicyTests(unittest.TestCase):
    """The insecure-on-purpose marker is for Part 05 labs, never for bookstore or default."""

    LAB = "05-security/02-pod-security.md"

    @staticmethod
    def pod(namespace):
        meta = f"  namespace: {namespace}\n" if namespace else ""
        return POD.replace("  name: demo\n", "  name: demo\n" + meta)

    def problems(self, body, chapter=LAB):
        return sg.marker_problems(blk(["Pod"], klass="insecure", chapter=chapter), body)

    def test_lab_namespace_in_part_05_is_allowed(self):
        self.assertEqual(self.problems(self.pod("lab")), [])

    def test_bookstore_default_and_no_namespace_are_refused(self):
        self.assertEqual(self.problems(self.pod("bookstore")), ["marker-namespace-bookstore"])
        self.assertEqual(self.problems(self.pod("default")), ["marker-namespace-default"])
        self.assertEqual(self.problems(self.pod(None)), ["marker-namespace-none"])

    def test_a_chapter_outside_part_05_is_refused(self):
        self.assertEqual(
            self.problems(self.pod("lab"), chapter="01-core-workloads/01-pods.md"),
            ["marker-outside-part-05"],
        )

    def test_a_namespace_document_named_bookstore_is_refused(self):
        body = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: bookstore\n---\n" + self.pod("lab")
        self.assertEqual(self.problems(body), ["marker-namespace-bookstore"])

    def test_cluster_scoped_and_non_workload_documents_need_no_namespace(self):
        body = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: lab\n---\n" + ROLE + "---\n" + self.pod("lab")
        self.assertEqual(self.problems(body), [])

    def test_a_pod_template_in_a_custom_resource_counts_as_a_workload(self):
        rollout = ROLLOUT_BODY.replace("  name: demo\n", "  name: demo\n  namespace: default\n")
        self.assertEqual(self.problems(rollout), ["marker-namespace-default"])
        self.assertEqual(self.problems(ROLLOUT_BODY), ["marker-namespace-none"])

    def test_judge_fails_a_marked_privileged_pod_in_bookstore(self):
        banner = "# INSECURE ON PURPOSE: a privileged pod. Lab cluster only.\n"
        failing = sg.Scan({"KSV-0012"}, {"KSV-0012"}, True)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.yaml"
            path.write_text(banner + self.pod("bookstore"), encoding="utf-8")
            block = blk(["Pod"], klass="insecure", chapter=self.LAB, path=str(path))
            self.assertEqual(sg.judge(block, failing), ("fail", ["marker-namespace-bookstore"]))
            path.write_text(banner + self.pod("lab"), encoding="utf-8")
            self.assertEqual(sg.judge(block, failing)[0], "pass")
            outside = blk(["Pod"], klass="insecure", chapter="01-a/01-x.md", path=str(path))
            self.assertEqual(sg.judge(outside, failing), ("fail", ["marker-outside-part-05"]))


ROLLOUT_BODY = textwrap.dedent(
    """\
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    metadata:
      name: demo
    spec:
      template:
        spec:
          containers:
            - name: app
              image: busybox
              securityContext:
                privileged: true
    """
)
WIDGET = "apiVersion: example.com/v1\nkind: Widget\nmetadata:\n  name: w\nspec:\n  size: 1\n"
LIST_WITH_POD = (
    "apiVersion: v1\nkind: List\nitems:\n  - apiVersion: v1\n    kind: Pod\n    metadata:\n      name: p\n"
    "    spec:\n      containers:\n        - name: app\n          image: busybox\n"
    "          securityContext:\n            privileged: true\n"
)
POD_TEMPLATE = (
    "apiVersion: v1\nkind: PodTemplate\nmetadata:\n  name: t\ntemplate:\n  spec:\n    containers:\n"
    "      - name: app\n        image: busybox\n        securityContext:\n          privileged: true\n"
)
DUPLICATE_KEY_POD = (
    "apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  containers:\n    - name: app\n"
    "      image: busybox\n      securityContext:\n        privileged: true\n  containers:\n"
    "    - name: app\n      image: busybox\nmetadata:\n  name: q\n"
)


class PodTemplateAndAllowlistTests(unittest.TestCase):
    def test_pod_templates_are_found_in_any_kind(self):
        for name, body in {
            "rollout": ROLLOUT_BODY, "list": LIST_WITH_POD, "podtemplate": POD_TEMPLATE,
            "duplicate keys": DUPLICATE_KEY_POD, "deployment": DEPLOY,
        }.items():  # fmt: skip
            self.assertTrue(sg.holds_pod_template(body), name)

    def test_blocks_with_no_container_hold_no_pod_template(self):
        self.assertFalse(sg.holds_pod_template(WIDGET))
        self.assertFalse(sg.holds_pod_template(ROLE))

    def test_a_body_that_does_not_parse_is_assumed_to_hold_one(self):
        self.assertTrue(sg.holds_pod_template("kind: Pod\n  bad: [unclosed"))

    def test_allowlist_entries_need_a_chapter_a_reason_and_what(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "allow"
            path.write_text("# comment\n\na.md | Rollout | rendered and scanned by hand\n", encoding="utf-8")
            self.assertEqual(sg.load_allowlist([path]), {("a.md", "Rollout")})
            for bad in ("a.md | Rollout\n", "a.md | Rollout |  \n", "a.md Rollout reason\n"):
                path.write_text(bad, encoding="utf-8")
                with self.assertRaises(sg.ControlError, msg=bad):
                    sg.load_allowlist([path])
            with self.assertRaises(sg.ControlError):
                sg.load_allowlist([Path(tmp) / "missing"])

    def test_a_block_is_allowed_only_when_every_reason_is_listed_for_its_chapter(self):
        allow = {("a.md", "Rollout"), ("b.md", "*")}
        self.assertTrue(sg.is_allowed("a.md", ["Rollout"], allow))
        self.assertFalse(sg.is_allowed("a.md", ["Rollout", "Kafka"], allow))
        self.assertFalse(sg.is_allowed("c.md", ["Rollout"], allow))
        self.assertTrue(sg.is_allowed("b.md", ["Kafka", "no-scanner-result"], allow))
        self.assertFalse(sg.is_allowed("a.md", [], allow))


class StaticRunner:
    """Builds a manifest of bodies and runs the static gate on it."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def manifest(self, entries):
        blocks = []
        for i, entry in enumerate(entries):
            chapter, body, *marked = entry
            klass, kinds = eb.classify(body, bool(marked and marked[0]))
            path = self.tmp / f"b{i}.yaml"
            path.write_text(body, encoding="utf-8")
            blocks.append(eb.Block(chapter, 1, 1, klass, kinds, str(path)))
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps([vars(b) for b in blocks]), encoding="utf-8")
        return manifest

    def run_gate(self, manifest, *args):
        report = self.tmp / "report.json"
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = sg.main(["--manifest", str(manifest), "--report", str(report), *args])
        self.output = out.getvalue()
        return rc, json.loads(report.read_text(encoding="utf-8")) if report.exists() else None

    def allow(self, text):
        path = self.tmp / "allow.txt"
        path.write_text(text, encoding="utf-8")
        return ["--allow", str(path)]


class StaticGateGuardTests(StaticRunner, unittest.TestCase):
    """Runs that must stop with exit 2 before Trivy is asked anything."""

    def test_an_empty_manifest_exits_two(self):
        self.assertEqual(self.run_gate(self.manifest([]))[0], 2)
        self.assertIn("nothing to check", self.output)

    def test_an_also_path_that_does_not_exist_exits_two(self):
        manifest = self.manifest([("a.md", HARDENED)])
        self.assertEqual(self.run_gate(manifest, "--also", str(self.tmp / "does-not-exist"))[0], 2)
        self.assertIn("does not exist", self.output)

    def test_an_also_directory_with_no_manifest_exits_two(self):
        manifest = self.manifest([("a.md", HARDENED)])
        empty = self.tmp / "empty"
        empty.mkdir()
        self.assertEqual(self.run_gate(manifest, "--also", str(empty))[0], 2)
        (empty / "notes.txt").write_text(POD, encoding="utf-8")
        (empty / "values.yaml").write_text("image: busybox\n", encoding="utf-8")
        self.assertEqual(self.run_gate(manifest, "--also", str(empty))[0], 2)
        self.assertIn("holds no YAML manifest", self.output)

    def test_an_also_file_that_is_not_a_manifest_exits_two(self):
        manifest = self.manifest([("a.md", HARDENED)])
        values = self.tmp / "values.yaml"
        values.write_text("image: busybox\n", encoding="utf-8")
        self.assertEqual(self.run_gate(manifest, "--also", str(values))[0], 2)

    def test_also_suffixes_are_matched_without_regard_to_case(self):
        files = sg._also_blocks([self._also_dir("bad.YAML", "ok.Yml", "skip.txt")])
        self.assertEqual(sorted(Path(b.chapter).name for b in files), ["bad.YAML", "ok.Yml"])

    def _also_dir(self, *names):
        directory = self.tmp / "also"
        directory.mkdir(exist_ok=True)
        for name in names:
            (directory / name).write_text(POD, encoding="utf-8")
        return str(directory)


@unittest.skipUnless(HAVE_TRIVY, "trivy is not on PATH")
class StaticGateExitTests(StaticRunner, unittest.TestCase):
    """Exit codes for runs that judged little or nothing."""

    def test_a_chapter_whose_only_block_is_a_rollout_exits_two(self):
        rc, report = self.run_gate(self.manifest([("a.md", ROLLOUT_BODY)]))
        self.assertEqual(rc, 2)
        self.assertEqual(report["summary"]["in_scope_judged"], 0)
        self.assertEqual(report["blocks"][0]["status"], "not-evaluated")

    def test_a_scope_of_only_unjudged_blocks_exits_two_even_when_other_chapters_pass(self):
        manifest = self.manifest([("a.md", HARDENED), ("b.md", ROLLOUT_BODY)])
        self.assertEqual(self.run_gate(manifest, "--scope", "b.md")[0], 2)

    def test_a_rollout_beside_a_judged_block_exits_one_until_it_is_allowlisted(self):
        manifest = self.manifest([("a.md", HARDENED), ("a.md", ROLLOUT_BODY)])
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 1)
        self.assertIn("holds a pod template", self.output)
        self.assertEqual(report["summary"]["unlisted_pod_templates"], 1)
        rc, report = self.run_gate(manifest, *self.allow("a.md | Rollout | rendered and scanned by hand\n"))
        self.assertEqual(rc, 0)
        self.assertTrue(report["blocks"][1]["allowed"])
        # An entry for another chapter, or for another kind, allows nothing.
        self.assertEqual(self.run_gate(manifest, *self.allow("b.md | Rollout | not this one\n"))[0], 1)
        self.assertEqual(self.run_gate(manifest, *self.allow("a.md | Kafka | not this kind\n"))[0], 1)

    def test_a_list_a_pod_template_and_a_duplicate_key_pod_all_exit_one(self):
        for name, body in {
            "list": LIST_WITH_POD, "podtemplate": POD_TEMPLATE, "duplicate keys": DUPLICATE_KEY_POD,
        }.items():  # fmt: skip
            with self.subTest(name):
                rc, report = self.run_gate(self.manifest([("a.md", HARDENED), ("a.md", body)]))
                self.assertEqual(rc, 1, self.output)
                self.assertEqual(report["blocks"][1]["status"], "not-evaluated")
                self.assertTrue(report["blocks"][1]["pod_template"])

    def test_a_custom_resource_with_no_pod_template_does_not_fail_the_run(self):
        rc, report = self.run_gate(self.manifest([("a.md", HARDENED), ("a.md", WIDGET)]))
        self.assertEqual(rc, 0)
        self.assertEqual(report["blocks"][1]["status"], "not-evaluated")
        self.assertFalse(report["blocks"][1]["pod_template"])

    def test_also_suffix_case_does_not_hide_a_file(self):
        bad = self.tmp / "bad.YAML"
        shutil.copy(FIXTURES / "violating-deployment.yaml", bad)
        self.assertEqual(self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(bad))[0], 1)

    def test_an_also_file_that_is_clean_passes(self):
        good = self.tmp / "good.YML"
        good.write_text(HARDENED, encoding="utf-8")
        self.assertEqual(self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(good))[0], 0)

    def test_trivy_blind_workloads_fail_the_run(self):
        # Trivy reports 0 failures for each of these; only the cross-check sees them.
        for name in sg.BASELINE_CONTROLS:
            with self.subTest(name):
                rc, report = self.run_gate(self.manifest([("a.md", fixture(name))]))
                self.assertEqual((rc, report["blocks"][0]["status"]), (1, "fail"))
                self.assertIn("KSV-0012", report["blocks"][0]["ids"])

    def test_the_marker_is_refused_outside_part_05_and_in_bookstore(self):
        banner = "# INSECURE ON PURPOSE: a privileged pod. Lab cluster only.\n"
        privileged = POD.replace("image: busybox\n", "image: busybox\n      securityContext:\n        privileged: true\n")
        lab = banner + privileged.replace("  name: demo\n", "  name: demo\n  namespace: lab\n")
        shared = lab.replace("namespace: lab", "namespace: bookstore")
        cases = {
            "lab in part 05": (("05-security/01-x.md", lab, True), 0),
            "bookstore in part 05": (("05-security/01-x.md", shared, True), 1),
            "lab in part 01": (("01-core-workloads/01-x.md", lab, True), 1),
        }
        for name, (entry, expected) in cases.items():
            with self.subTest(name):
                rc, report = self.run_gate(self.manifest([entry, ("a.md", HARDENED)]))
                self.assertEqual(rc, expected, self.output)
        _, report = self.run_gate(self.manifest([cases["lab in part 01"][0], ("a.md", HARDENED)]))
        self.assertEqual(report["blocks"][0]["ids"], ["marker-outside-part-05"])


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


REMOVED_OUT = (
    'error: resource mapping not found for name: "x" namespace: "gate-restricted" from "STDIN": '
    'no matches for kind "Deployment" in version "extensions/v1beta1"\n'
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

    def test_a_removed_apiversion_on_a_builtin_kind_is_an_error(self):
        for gv in ("extensions/v1beta1", "apps/v1beta1", "policy/v1beta1", "v2", "networking.k8s.io/v1beta1"):
            out = f'error: no matches for kind "Thing" in version "{gv}"\nensure CRDs are installed first\n'
            self.assertEqual(ag.classify_output(1, out), "error", gv)

    def test_a_group_the_cluster_serves_is_an_error_too(self):
        out = 'no matches for kind "Rollout" in version "argoproj.io/v1alpha1"\nensure CRDs are installed first\n'
        self.assertEqual(ag.classify_output(1, out, {"argoproj.io"}), "error")
        self.assertEqual(ag.classify_output(1, out, {"cert-manager.io"}), "missing-crd")

    def test_custom_groups_under_k8s_io_are_still_missing_crds(self):
        out = 'no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"\nensure CRDs are installed first\n'
        self.assertEqual(ag.classify_output(1, out), "missing-crd")

    def test_one_builtin_group_among_several_missing_kinds_makes_it_an_error(self):
        self.assertEqual(ag.classify_output(1, NO_CRD_OUT + REMOVED_OUT), "error")

    def test_a_not_found_message_without_a_version_stays_a_missing_crd(self):
        self.assertEqual(ag.classify_output(1, "the server could not find the requested resource\n"), "missing-crd")


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


TODAY = "2026-10-31"  # the day the admission tests pretend it is

FAKE_KUBECTL = """#!{python}
import os, sys
args = sys.argv[1:]
if os.environ.get("FAKE_LOG"):
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(" ".join(args) + "\\n")
if args[:2] == ["config", "current-context"]:
    print(os.environ.get("FAKE_CONTEXT", "kind-fake"))
    sys.exit(0)
if args == ["api-versions"]:
    print("v1")
    print("apps/v1")
    print("batch/v1")
    for extra in os.environ.get("FAKE_SERVED", "").split():
        print(extra)
    sys.exit(0)
if "api-resources" in args:
    print("namespaces   ns   v1   false   Namespace")
    print("clusterroles      rbac.authorization.k8s.io/v1   false   ClusterRole")
    sys.exit(0)
if args[:2] == ["get", "serviceaccount"]:
    sys.exit(1 if os.environ.get("FAKE_NO_DEFAULT_SA") else 0)
body = sys.stdin.read()
if "--dry-run=server" not in args:
    if os.environ.get("FAKE_APPLIED"):
        with open(os.environ["FAKE_APPLIED"], "a") as applied:
            applied.write(body + "---\\n")
    sys.exit(0)  # creating a gate namespace
level = "restricted"
for name in ("privileged", "baseline"):
    if "namespace: gate-" + name in body:
        level = name
if "gate-control-violating-nullsc" in body and os.environ.get("FAKE_BLIND_NULLSC"):
    print("deployment.apps/x created (server dry run)")
elif "gate-control-violating" in body and not os.environ.get("FAKE_BLIND"):
    sys.stderr.write({warn!r})
    print("deployment.apps/gate-control-violating created (server dry run)")
elif "VIOLATE" in body:
    sys.stderr.write({warn!r})
    print("deployment.apps/x created (server dry run)")
elif ("NEEDS_PRIVILEGED" in body and level != "privileged") or ("NEEDS_BASELINE" in body and level == "restricted"):
    sys.stderr.write({warn!r})
    print("deployment.apps/x created (server dry run)")
elif "extensions/v1beta1" in body:
    sys.stderr.write({removed!r})
    sys.exit(1)
elif "Rollout" in body:
    sys.stderr.write({nocrd!r})
    sys.exit(1)
elif "BOOM" in body:
    sys.stderr.write("Error from server (Invalid): boom\\n")
    sys.exit(1)
else:
    print("object created in gate-" + level + " (server dry run)")
"""


class ReferencedServiceAccountTests(unittest.TestCase):
    """A server dry-run creates nothing, so a named ServiceAccount must already exist."""

    def _names(self, body):
        docs = [d for d in yaml.safe_load_all(body) if isinstance(d, dict)]
        return ag.referenced_service_accounts(docs)

    def test_bare_pod_names_its_service_account(self):
        self.assertEqual(self._names("kind: Pod\nspec: {serviceAccountName: catalog-sa}"), {"catalog-sa"})

    def test_workload_and_cronjob_templates_are_read(self):
        dep = "kind: Deployment\nspec: {template: {spec: {serviceAccountName: a}}}"
        cron = "kind: CronJob\nspec: {jobTemplate: {spec: {template: {spec: {serviceAccountName: b}}}}}"
        self.assertEqual(self._names(dep + "\n---\n" + cron), {"a", "b"})

    def test_default_and_absent_names_are_ignored(self):
        self.assertEqual(self._names("kind: Pod\nspec: {serviceAccountName: default}"), set())
        self.assertEqual(self._names("kind: Pod\nspec: {containers: []}"), set())

    def test_non_mapping_spec_does_not_crash(self):
        self.assertEqual(self._names("kind: Foo\nspec: 3"), set())


class ReferencedRuntimeClassTests(unittest.TestCase):
    """A server dry-run creates nothing, so a named RuntimeClass must already exist."""

    def _names(self, body):
        docs = [d for d in yaml.safe_load_all(body) if isinstance(d, dict)]
        return ag.referenced_runtime_classes(docs)

    def test_bare_pod_and_templates_are_read(self):
        pod = "kind: Pod\nspec: {runtimeClassName: gvisor}"
        dep = "kind: Deployment\nspec: {template: {spec: {runtimeClassName: kata}}}"
        cron = "kind: CronJob\nspec: {jobTemplate: {spec: {template: {spec: {runtimeClassName: wasm}}}}}"
        self.assertEqual(self._names(pod + "\n---\n" + dep + "\n---\n" + cron), {"gvisor", "kata", "wasm"})

    def test_absent_name_and_non_mapping_spec_are_ignored(self):
        self.assertEqual(self._names("kind: Pod\nspec: {containers: []}"), set())
        self.assertEqual(self._names("kind: Foo\nspec: 3"), set())


class AdmissionCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.kubectl = self.tmp / "kubectl"
        self.kubectl.write_text(
            FAKE_KUBECTL.format(python=sys.executable, warn=WARN_OUT, nocrd=NO_CRD_OUT, removed=REMOVED_OUT),
            encoding="utf-8",
        )
        self.kubectl.chmod(self.kubectl.stat().st_mode | stat.S_IEXEC)
        self.guide = self.tmp / "guide"
        self.registry = self.tmp / "namespace-exceptions.yaml"
        self.register()

    def manifest(self, entries):
        bodies = []
        for i, (chapter, klass, kind, extra) in enumerate(entries):
            namespace = "lab" if klass == "insecure" else "bookstore"
            body = f"apiVersion: v1\nkind: {kind}\nmetadata:\n  name: n{i}\n  namespace: {namespace}\n{extra}"
            bodies.append((chapter, klass, [kind], body))
        return self.manifest_bodies(bodies)

    def manifest_bodies(self, entries):
        blocks = []
        for i, (chapter, klass, kinds, body) in enumerate(entries):
            path = self.tmp / f"b{i}.yaml"
            path.write_text(body, encoding="utf-8")
            blocks.append(eb.Block(chapter, 1, 1, klass, list(kinds), str(path)))
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps([vars(b) for b in blocks]), encoding="utf-8")
        return manifest

    def run_gate(self, manifest, *args):
        report = self.tmp / "report.json"
        argv = [
            "--manifest", str(manifest), "--kubectl", str(self.kubectl), "--report", str(report),
            "--root", str(self.guide), "--namespace-registry", str(self.registry), "--today", TODAY,
            *args,
        ]  # fmt: skip
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = ag.main(argv)
        self.output = out.getvalue()
        return rc, (json.loads(report.read_text(encoding="utf-8")) if report.exists() else None)

    def statuses(self, report):
        return {(b["chapter"]): b["status"] for b in report["blocks"]}

    def test_each_outcome_gets_its_own_status_and_exit_code(self):
        manifest = self.manifest([
            ("a.md", "applyable", "ConfigMap", ""),
            ("b.md", "applyable", "ConfigMap", "data:\n  x: VIOLATE\n"),
            ("c.md", "applyable", "Rollout", ""),
            ("d.md", "applyable", "ConfigMap", "data:\n  x: BOOM\n"),
            ("05-security/e.md", "insecure", "ConfigMap", "data:\n  x: VIOLATE\n"),
            ("f.md", "unparseable", "ConfigMap", ""),
        ])
        rc, report = self.run_gate(manifest, "--scope", "a.md")
        self.assertEqual(rc, 0)
        self.assertEqual(
            self.statuses(report),
            {"a.md": "pass", "b.md": "violation", "c.md": "missing-crd", "d.md": "error",
             "05-security/e.md": "skipped-insecure", "f.md": "unparseable"},
        )
        # c.md and e.md hold nothing the cluster judged, so the run is exit 2, not a pass.
        for chapter, expected in (("b.md", 1), ("c.md", 2), ("d.md", 1), ("05-security/e.md", 2), ("f.md", 1)):
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

    # ---- context guard, zero-judged runs, wrong apiVersions, marker policy ----

    def set_env(self, name, value):
        os.environ[name] = value
        self.addCleanup(os.environ.pop, name, None)

    def test_a_context_that_is_not_kind_is_refused_before_anything_is_written(self):
        log = self.tmp / "kubectl.log"
        self.set_env("FAKE_LOG", str(log))
        self.set_env("FAKE_CONTEXT", "arn:aws:eks:prod")
        manifest = self.manifest([("a.md", "applyable", "ConfigMap", "")])
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 2)
        self.assertIsNone(report)
        self.assertIn("--allow-context", self.output)
        calls = log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(calls, ["config current-context"], "no kubectl call may follow the refusal")

    def test_an_explicitly_allowed_context_runs_and_is_printed(self):
        self.set_env("FAKE_CONTEXT", "lab-cluster")
        manifest = self.manifest([("a.md", "applyable", "ConfigMap", "")])
        self.assertEqual(self.run_gate(manifest)[0], 2)
        rc, report = self.run_gate(manifest, "--allow-context", "lab-cluster")
        self.assertEqual(rc, 0)
        self.assertIn("kubectl context lab-cluster", self.output)
        self.assertEqual(report["summary"]["context"], "lab-cluster")

    def test_a_kind_context_is_accepted_and_printed_before_the_namespace_is_applied(self):
        log = self.tmp / "kubectl.log"
        self.set_env("FAKE_LOG", str(log))
        rc, _ = self.run_gate(self.manifest([("a.md", "applyable", "ConfigMap", "")]))
        self.assertEqual(rc, 0)
        self.assertIn("kubectl context kind-fake", self.output)
        calls = log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(calls[0], "config current-context")
        self.assertIn("apply -f -", calls)

    def test_an_empty_manifest_exits_two(self):
        self.assertEqual(self.run_gate(self.manifest([]))[0], 2)

    def test_a_missing_crd_block_with_a_pod_template_exits_one_until_it_is_allowlisted(self):
        rollout = (
            "apiVersion: argoproj.io/v1alpha1\nkind: Rollout\nmetadata:\n  name: r\nspec:\n  template:\n"
            "    spec:\n      containers:\n        - name: app\n          image: busybox\n"
        )
        widget = "apiVersion: argoproj.io/v1alpha1\nkind: Rollout\nmetadata:\n  name: w\nspec:\n  size: 1\n"
        pass_body = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ok\n"
        manifest = self.manifest_bodies([
            ("a.md", "applyable", ["ConfigMap"], pass_body),
            ("b.md", "applyable", ["Rollout"], rollout),
        ])
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 1)
        self.assertIn("holds a pod template", self.output)
        allow = self.tmp / "allow.txt"
        allow.write_text("b.md | Rollout | rendered and checked by hand\n", encoding="utf-8")
        self.assertEqual(self.run_gate(manifest, "--allow", str(allow))[0], 0)
        # A missing CRD that holds no pod template is listed, and is not a failure.
        plain = self.manifest_bodies([
            ("a.md", "applyable", ["ConfigMap"], pass_body),
            ("b.md", "applyable", ["Rollout"], widget),
        ])
        self.assertEqual(self.run_gate(plain)[0], 0)

    def test_a_removed_api_version_on_a_builtin_kind_is_an_error_not_a_missing_crd(self):
        removed = (
            "apiVersion: extensions/v1beta1\nkind: Deployment\nmetadata:\n  name: d\nspec:\n  template:\n"
            "    spec:\n      containers:\n        - name: app\n          image: busybox\n"
        )
        manifest = self.manifest_bodies([("a.md", "applyable", ["Deployment"], removed)])
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(report["blocks"][0]["status"], "error")

    def test_a_group_the_cluster_serves_is_an_error_when_the_version_is_wrong(self):
        rollout = "apiVersion: argoproj.io/v1alpha1\nkind: Rollout\nmetadata:\n  name: w\nspec:\n  size: 1\n"
        manifest = self.manifest_bodies([("a.md", "applyable", ["Rollout"], rollout)])
        self.set_env("FAKE_SERVED", "argoproj.io/v1beta1")
        rc, report = self.run_gate(manifest)
        self.assertEqual((rc, report["blocks"][0]["status"]), (1, "error"))

    def test_the_marker_policy_applies_to_the_skip_too(self):
        lab = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: l\n  namespace: lab\n"
        shared = lab.replace("namespace: lab", "namespace: default")
        passing = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ok\n"
        for name, entry, status, rc in (
            ("lab in part 05", ("05-security/01-x.md", "insecure", ["ConfigMap"], lab), "skipped-insecure", 0),
            ("default in part 05", ("05-security/01-x.md", "insecure", ["ConfigMap"], shared), "error", 1),
            ("lab outside part 05", ("01-a/01-x.md", "insecure", ["ConfigMap"], lab), "error", 1),
        ):
            with self.subTest(name):
                manifest = self.manifest_bodies([entry, ("a.md", "applyable", ["ConfigMap"], passing)])
                got_rc, report = self.run_gate(manifest)
                self.assertEqual((got_rc, report["blocks"][0]["status"]), (rc, status), self.output)

    def test_a_cluster_blind_to_the_trivy_blind_fixtures_aborts(self):
        self.set_env("FAKE_BLIND_NULLSC", "1")
        manifest = self.manifest([("a.md", "applyable", "ConfigMap", "")])
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 2)
        self.assertIn("violating-null-securitycontext", self.output)
        self.assertIsNone(report)

    # ---- registered exceptions: judged at the registered level, and nothing else ----

    CHAPTER = "01-a/06-x.md"

    def register(self, *overrides):
        """Write the namespace registry. Each override changes a sound `node-logs` entry."""
        sound = {
            "namespace": "node-logs", "level": "privileged",
            "reason": "the agent reads the node's pod logs through hostPath",
            "upstream": "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
            "chapter": self.CHAPTER, "expires": "2027-06-30",
        }  # fmt: skip
        entries = [sound | override for override in overrides]
        for entry in entries:
            write(self.guide, entry["chapter"], "# chapter\n")
        self.registry.write_text(yaml.safe_dump({"exceptions": entries}, sort_keys=False), encoding="utf-8")

    @staticmethod
    def workload(marker, namespace="node-logs", name="agent"):
        """A document that the fake cluster refuses below the level its marker names."""
        space = f"  namespace: {namespace}\n" if namespace else ""
        return f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\n{space}data:\n  x: {marker}\n"

    def block(self, *bodies, chapter=CHAPTER, klass="applyable"):
        return self.manifest_bodies([(chapter, klass, ["ConfigMap"], "---\n".join(bodies))])

    def gate_namespaces(self):
        """The labels of every gate namespace the run created."""
        applied = self.tmp / "applied.yaml"
        if not applied.exists():
            return {}
        docs = [d for d in yaml.safe_load_all(applied.read_text(encoding="utf-8")) if isinstance(d, dict)]
        return {d["metadata"]["name"]: d["metadata"]["labels"] for d in docs if d.get("kind") == "Namespace"}

    def judged(self, manifest, *args):
        """Run the gate; return (exit code, status of the first block)."""
        self.set_env("FAKE_APPLIED", str(self.tmp / "applied.yaml"))
        rc, report = self.run_gate(manifest, *args)
        return rc, report["blocks"][0]["status"], report

    def test_a_registered_namespace_is_judged_at_its_registered_level(self):
        self.register({})
        rc, status, report = self.judged(self.block(self.workload("NEEDS_PRIVILEGED")), "--scope", self.CHAPTER)
        self.assertEqual((rc, status), (0, "registered"), self.output)
        self.assertIn("gate-privileged", report["blocks"][0]["detail"])
        self.assertEqual(report["summary"]["in_scope_judged"], 1, "a registered block is judged")
        self.assertIn("node-logs", self.output)
        self.assertEqual(
            self.gate_namespaces()["gate-privileged"],
            {"pod-security.kubernetes.io/enforce": "privileged", "pod-security.kubernetes.io/warn": "privileged"},
        )

    def test_the_same_namespace_from_a_chapter_the_entry_does_not_name_is_a_violation(self):
        self.register({})
        manifest = self.block(self.workload("NEEDS_PRIVILEGED"), chapter="01-a/07-y.md")
        rc, status, _ = self.judged(manifest)
        self.assertEqual((rc, status), (1, "violation"), self.output)
        self.assertNotIn("gate-privileged", self.gate_namespaces(), "no exception namespace for a stranger")

    def test_a_privileged_workload_in_a_baseline_only_namespace_is_a_violation(self):
        self.register({"level": "baseline"})
        rc, status, _ = self.judged(self.block(self.workload("NEEDS_PRIVILEGED")))
        self.assertEqual((rc, status), (1, "violation"), self.output)
        self.assertEqual(
            self.gate_namespaces()["gate-baseline"],
            {"pod-security.kubernetes.io/enforce": "baseline", "pod-security.kubernetes.io/warn": "baseline"},
        )
        self.assertNotIn("gate-privileged", self.gate_namespaces())
        # What baseline does admit is registered, in the baseline namespace.
        rc, status, report = self.judged(self.block(self.workload("NEEDS_BASELINE")))
        self.assertEqual((rc, status), (0, "registered"), self.output)
        self.assertIn("gate-baseline", report["blocks"][0]["detail"])

    def test_an_unregistered_namespace_is_a_violation(self):
        self.register({})
        manifest = self.block(self.workload("NEEDS_PRIVILEGED", namespace="other-logs"))
        rc, status, _ = self.judged(manifest)
        self.assertEqual((rc, status), (1, "violation"), self.output)
        self.assertNotIn("gate-privileged", self.gate_namespaces())

    def test_an_entry_that_is_expired_or_unsound_grants_nothing(self):
        cases = {
            "expired yesterday": {"expires": "2026-10-30"},
            "expires today": {"expires": "2026-10-31"},
            "more than 12 months out": {"expires": "2027-11-01"},
            "no expiry": {"expires": None},
            "no reason": {"reason": ""},
            "no citation": {"upstream": ""},
        }
        for name, override in cases.items():
            with self.subTest(name):
                self.register(override)
                rc, status, _ = self.judged(self.block(self.workload("NEEDS_PRIVILEGED")))
                self.assertEqual((rc, status), (1, "violation"), self.output)
                self.assertIn("node-logs", self.output, "the run says why the entry was not applied")
        self.register({})
        (self.guide / self.CHAPTER).unlink()
        rc, status, _ = self.judged(self.block(self.workload("NEEDS_PRIVILEGED")))
        self.assertEqual((rc, status), (1, "violation"), "a chapter that is not in the guide")
        self.assertNotIn("gate-privileged", self.gate_namespaces())

    def test_a_namespace_registered_twice_grants_nothing(self):
        self.register({}, {"level": "baseline"})
        rc, status, _ = self.judged(self.block(self.workload("NEEDS_BASELINE")))
        self.assertEqual((rc, status), (1, "violation"), self.output)

    def test_a_block_that_reaches_outside_the_registered_namespace_is_judged_at_restricted(self):
        self.register({})
        for name, other in (
            ("another namespace", self.workload("OK", namespace="bookstore", name="other")),
            ("no namespace", self.workload("OK", namespace=None, name="other")),
        ):
            with self.subTest(name):
                rc, status, _ = self.judged(self.block(self.workload("NEEDS_PRIVILEGED"), other))
                self.assertEqual((rc, status), (1, "violation"), self.output)

    def test_cluster_scoped_documents_do_not_change_where_a_block_is_judged(self):
        self.register({})
        namespace = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: node-logs\n"
        rc, status, _ = self.judged(self.block(namespace, self.workload("NEEDS_PRIVILEGED")))
        self.assertEqual((rc, status), (0, "registered"), self.output)

    def test_only_a_pass_becomes_registered(self):
        self.register({})
        for marker, status in (("BOOM", "error"), ("VIOLATE", "violation")):
            with self.subTest(marker):
                rc, got, _ = self.judged(self.block(self.workload(marker)))
                self.assertEqual((rc, got), (1, status), self.output)

    def test_the_marker_policy_is_not_relaxed_for_a_registered_namespace(self):
        self.register({})
        manifest = self.block(self.workload("NEEDS_PRIVILEGED"), klass="insecure")
        rc, status, _ = self.judged(manifest)
        self.assertEqual((rc, status), (1, "error"), self.output)

    def test_an_unreadable_registry_exits_two(self):
        manifest = self.block(self.workload("NEEDS_PRIVILEGED"))
        self.registry.write_text("exceptions: [unclosed\n", encoding="utf-8")
        rc, report = self.run_gate(manifest)
        self.assertEqual((rc, report), (2, None), self.output)
        rc, report = self.run_gate(manifest, "--namespace-registry", str(self.tmp / "absent.yaml"))
        self.assertEqual((rc, report), (2, None), self.output)

    def test_a_gate_namespace_is_ready_for_pods_before_a_block_is_dry_run_in_it(self):
        log = self.tmp / "kubectl.log"
        self.set_env("FAKE_LOG", str(log))
        self.register({})
        rc, status, _ = self.judged(self.block(self.workload("NEEDS_PRIVILEGED")))
        self.assertEqual((rc, status), (0, "registered"), self.output)
        calls = log.read_text(encoding="utf-8").splitlines()
        wait = "get serviceaccount default -n gate-privileged -o name"
        self.assertIn(wait, calls)
        self.assertLess(calls.index(wait), max(i for i, c in enumerate(calls) if "--dry-run=server" in c))

    def test_a_namespace_that_never_gets_its_default_service_account_aborts(self):
        self.set_env("FAKE_NO_DEFAULT_SA", "1")
        manifest = self.block(self.workload("OK"))
        with mock.patch.object(ag, "SERVICE_ACCOUNT_POLLS", 2), mock.patch.object(ag.time, "sleep"):
            rc, report = self.run_gate(manifest)
        self.assertEqual((rc, report), (2, None), self.output)
        self.assertIn("default ServiceAccount", self.output)

    def test_a_registry_with_a_structure_error_grants_nothing(self):
        self.registry.write_text("exceptions: nope\n", encoding="utf-8")
        rc, status, _ = self.judged(self.block(self.workload("NEEDS_PRIVILEGED")))
        self.assertEqual((rc, status), (1, "violation"), self.output)


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


class EvidenceGuardTests(unittest.TestCase):
    """Blocks and markers that must not read as evidence."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.transcript = self.tmp / "05-02.txt"
        self.transcript.write_text(TRANSCRIPT, encoding="utf-8")

    def run_gate(self, chapter_text):
        chapter = self.tmp / "ch.md"
        chapter.write_text(chapter_text, encoding="utf-8")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = ev.main(["--chapter", str(chapter), "--transcript", str(self.transcript)])
        return rc, out.getvalue()

    def chapter(self, body):
        return f"# Lab\n\n{OUTPUT}\n\n```text\n{body}\n```\n"

    def test_a_block_of_only_an_elision_fails(self):
        rc, out = self.run_gate(self.chapter("# ..."))
        self.assertEqual(rc, 1)
        self.assertIn("no output lines", out)

    def test_a_block_with_nothing_in_it_fails(self):
        rc, out = self.run_gate(self.chapter(""))
        self.assertEqual(rc, 1)
        self.assertIn("no output lines", out)

    def test_an_elision_beside_real_lines_is_fine(self):
        rc, _ = self.run_gate(self.chapter("# ...\nweb-1   1/1     Running   0          9s"))
        self.assertEqual(rc, 0)

    def test_near_miss_markers_fail_the_run_and_are_named(self):
        fake = "web-9   1/1     Running   0          1s"
        text = self.chapter("web-0   1/1     Running   0          12s")
        text += f"\n<!--gate: output-->\n\n```text\n{fake}\n```\n"
        text += f"\n<!-- gate: Output -->\n\n```text\n{fake}\n```\n"
        rc, out = self.run_gate(text)
        self.assertEqual(rc, 1)
        self.assertIn("<!--gate: output-->", out)
        self.assertIn("<!-- gate: Output -->", out)

    def test_other_misspelt_gate_comments_fail(self):
        for comment in (
            "<!--  GATE : output -->", "<!-- gate: insecure_on_purpose -->",
            "<!-- gate: output", "<!-- gate:output -->",
        ):  # fmt: skip
            with self.subTest(comment):
                rc, _ = self.run_gate(self.chapter("web-0   1/1     Running   0          12s") + f"\n{comment}\n")
                self.assertEqual(rc, 1)

    def test_known_markers_and_fenced_examples_are_not_flagged(self):
        text = self.chapter("web-0   1/1     Running   0          12s")
        text += f"\n{eb.MARKER}\n\n```yaml\nkind: Pod\n```\n"
        text += "\n````markdown\n<!--gate: output-->\n````\n"
        text += "\n   <!-- gate: output -->\n"  # indented under a list item
        text += "\n<!-- link-later: 05.05 -->\n"
        self.assertEqual(self.run_gate(text)[0], 0)

    def test_bad_gate_comments_reports_the_line(self):
        md = "intro\n<!--gate: output-->\n```text\nx\n```\n"
        self.assertEqual(ev.bad_gate_comments(md), [(2, "<!--gate: output-->")])


class RepeatedHeaderTests(unittest.TestCase):
    """kubectl prints the same table header again and again."""

    TRANSCRIPT = textwrap.dedent(
        """\
        $ kubectl get pods
        NAME   STATUS
        web    Pending
        $ kubectl get pods
        NAME   STATUS
        web    Running
        """
    )

    def test_a_block_matches_the_later_occurrence_of_its_first_line(self):
        self.assertEqual(ev.missing_lines("NAME   STATUS\nweb    Running", self.TRANSCRIPT), [])

    def test_each_run_between_elisions_is_matched_whole(self):
        block = "NAME   STATUS\nweb    Pending\n# ...\nNAME   STATUS\nweb    Running"
        self.assertEqual(ev.missing_lines(block, self.TRANSCRIPT), [])

    def test_a_run_that_matches_nowhere_still_reports_only_the_lines_not_found(self):
        self.assertEqual(ev.missing_lines("NAME   STATUS\nweb    Failed", self.TRANSCRIPT), ["web    Failed"])

    def test_cli_accepts_the_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "t.txt"
            transcript.write_text(self.TRANSCRIPT, encoding="utf-8")
            chapter = Path(tmp) / "c.md"
            chapter.write_text(f"{OUTPUT}\n\n```text\nNAME   STATUS\nweb    Running\n```\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ev.main(["--chapter", str(chapter), "--transcript", str(transcript)]), 0)


class WiderLeakTests(unittest.TestCase):
    def test_public_ipv6_leaks(self):
        self.assertEqual(ev.leaks("resolver 2606:4700:4700::1111 up"), ["2606:4700:4700::1111"])
        self.assertEqual(ev.leaks("addr 2606:4700:4700::1111: refused"), ["2606:4700:4700::1111"])

    def test_private_and_documentation_ipv6_and_lookalikes_do_not_leak(self):
        for text in ("::1", "fe80::1", "fd00::1", "2001:db8::1", "at 10:30:45 today", "mac 02:42:ac:11:00:02", "::"):
            self.assertEqual(ev.leaks(text), [], text)

    def test_leading_zero_octets_still_count_as_an_address(self):
        self.assertEqual(ev.leaks("dns 008.008.008.008"), ["008.008.008.008"])
        self.assertEqual(ev.leaks("dns 010.000.000.001"), [])

    def test_aws_registry_and_host_names_leak(self):
        self.assertEqual(
            ev.leaks("image 123456789012.dkr.ecr.us-east-1.amazonaws.com/app:1"),
            ["123456789012.dkr.ecr.us-east-1.amazonaws.com"],
        )
        self.assertEqual(
            ev.leaks("host ec2-54-23-1-9.compute-1.amazonaws.com"), ["ec2-54-23-1-9.compute-1.amazonaws.com"]
        )
        self.assertEqual(ev.leaks("node ip-10-0-1-5.ec2.internal"), [])

    def test_a_gcp_project_in_a_registry_path_leaks_but_public_projects_do_not(self):
        self.assertEqual(ev.leaks("image gcr.io/acme-prod-12345/app:1"), ["gcr.io/acme-prod-12345"])
        self.assertEqual(
            ev.leaks("image us-docker.pkg.dev/acme-prod-12345/repo/app:1"),
            ["us-docker.pkg.dev/acme-prod-12345"],
        )
        for image in (
            "gcr.io/distroless/static:nonroot", "k8s.gcr.io/pause:3.9", "registry.k8s.io/pause:3.10",
            "gcr.io/google-containers/pause:3.2", "us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0",
            "gcr.io/PROJECT_ID/app", "gcr.io/k8s-staging-images/foo/bar",
        ):  # fmt: skip
            self.assertEqual(ev.leaks(f"image {image}"), [], image)

    def test_a_prompt_that_names_a_user_and_host_leaks(self):
        self.assertEqual(ev.leaks("jane@laptop:~$ ls"), ["jane@laptop:~$"])
        self.assertEqual(ev.leaks("[jane@laptop ~]$ ls"), ["[jane@laptop ~]$"])

    def test_container_prompts_do_not_leak(self):
        for prompt in ("root@web-0:/# ls", "nonroot@web-0:/app$ ls", "root@kind-control-plane:/# id"):
            self.assertEqual(ev.leaks(prompt), [], prompt)


class TrivyRequiredTests(unittest.TestCase):
    """With REQUIRE_TRIVY=1 a missing Trivy is a failure, not a skip."""

    def test_trivy_is_installed_when_required(self):
        if REQUIRE_TRIVY:
            self.assertTrue(HAVE_TRIVY, "trivy is not on PATH, so the real-Trivy tests were skipped")


class RequireTrivyMetaTests(unittest.TestCase):
    """Run the guard in a child process that cannot find Trivy."""

    def run_guard(self, **env):
        base = {k: v for k, v in os.environ.items() if k != "REQUIRE_TRIVY"}
        proc = subprocess.run(
            [sys.executable, "-m", "unittest", "test_gates.TrivyRequiredTests"],
            cwd=Path(__file__).resolve().parent,
            env={**base, "PATH": "/nonexistent", "PYTHONDONTWRITEBYTECODE": "1", **env},
            capture_output=True, text=True, check=False,
        )  # fmt: skip
        return proc.returncode, proc.stderr

    def test_a_missing_trivy_fails_the_suite_when_it_is_required(self):
        rc, err = self.run_guard(REQUIRE_TRIVY="1")
        self.assertNotEqual(rc, 0, err)
        self.assertIn("trivy is not on PATH", err)

    def test_a_missing_trivy_is_tolerated_when_it_is_not_required(self):
        rc, err = self.run_guard()
        self.assertEqual(rc, 0, err)

    def test_the_makefile_requires_trivy_for_the_unit_tests(self):
        makefile = (Path(__file__).resolve().parents[3] / "Makefile").read_text(encoding="utf-8")
        recipe = makefile.split("\ngates-test:")[1].split("\n\n")[0]
        self.assertIn("REQUIRE_TRIVY=1", recipe)
        self.assertIn("command -v trivy", recipe)


if __name__ == "__main__":
    unittest.main()
