#!/usr/bin/env python3
"""Tests for `chapter_summary.py`, the verdict of the gates workflow.

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

The script decides whether a pull request stays green. Any chapter that fails
a gate fails the job, except the outlines named in the report-only file. Each
test builds small reports and checks one rule.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import chapter_summary as cs

PASSING = "01-core-workloads/01-pods.md"
FAILING = "01-core-workloads/04-replicasets-and-deployments.md"


def static_row(chapter: str, status: str = "pass", **extra) -> dict:
    row = {"chapter": chapter, "line": 12, "status": status, "ids": [], "pod_template": False, "allowed": False, "in_scope": True}
    row.update(extra)
    return row


def admission_row(chapter: str, status: str = "pass", **extra) -> dict:
    row = {"chapter": chapter, "line": 30, "status": status, "detail": "", "pod_template": False, "allowed": False, "in_scope": True}
    row.update(extra)
    return row


class Case(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.root = self.dir / "full-guide"
        for chapter in (PASSING, FAILING, "05-security/02-pod-security.md"):
            path = self.root / chapter
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# chapter\n", encoding="utf-8")
        (self.root / "examples/bookstore/raw-manifests").mkdir(parents=True)
        (self.root / "16-outline").mkdir()
        (self.root / "16-outline/README.md").write_text("# outline\n", encoding="utf-8")

    def report(self, name: str, rows: list[dict]) -> str:
        path = self.dir / f"{name}.json"
        path.write_text(json.dumps({"summary": {}, "blocks": rows}), encoding="utf-8")
        return str(path)

    def enforced(self, *entries: str) -> Path:
        path = self.dir / "enforced.txt"
        path.write_text("# comment\n" + "\n".join(entries) + "\n", encoding="utf-8")
        return path

    def report_only(self, *entries: str) -> Path:
        path = self.dir / "report-only.txt"
        path.write_text("# comment\n" + "\n".join(entries) + "\n", encoding="utf-8")
        return path

    def run_main(self, gates: list[str], enforced: Path, report_only: Path | None = None) -> tuple[int, str, str]:
        argv = ["--enforced", str(enforced), "--root", str(self.root)]
        if report_only is not None:
            argv += ["--report-only", str(report_only)]
        for gate in gates:
            argv += ["--gate", gate]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cs.main(argv)
        return code, out.getvalue(), err.getvalue()


class VerdictTests(Case):
    def test_a_failing_chapter_on_no_list_fails_the_job(self) -> None:
        static = self.report("static", [static_row(PASSING), static_row(FAILING, "fail", ids=["KSV-0014"])])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1, out)
        self.assertIn(FAILING, out)
        self.assertIn("KSV-0014", out)

    def test_a_failing_report_only_chapter_is_listed_and_does_not_fail_the_job(self) -> None:
        static = self.report("static", [static_row(PASSING), static_row(FAILING, "fail", ids=["KSV-0014"])])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING), self.report_only(FAILING))
        self.assertEqual(code, 0, out)
        self.assertIn("Failing, report only", out)
        self.assertIn(FAILING, out)
        self.assertIn("KSV-0014", out)

    def test_a_report_only_directory_covers_the_chapters_under_it(self) -> None:
        static = self.report("static", [static_row(PASSING), static_row("16-outline/01-first.md", "fail")])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING), self.report_only("16-outline/"))
        self.assertEqual(code, 0, out)
        self.assertIn("16-outline/01-first.md", out)

    def test_a_report_only_entry_does_not_excuse_another_chapter(self) -> None:
        static = self.report("static", [static_row(PASSING, "fail"), static_row(FAILING, "fail")])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING), self.report_only(FAILING))
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL: " + PASSING, out)

    def test_an_enforced_chapter_that_fails_fails_the_job(self) -> None:
        static = self.report("static", [static_row(PASSING, "fail", ids=["KSV-0001"]), static_row(FAILING, "fail")])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL: " + PASSING, out)

    def test_an_enforced_chapter_that_fails_one_of_two_gates_fails_the_job(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        admission = self.report("admission", [admission_row(PASSING, "violation")])
        code, out, _ = self.run_main([f"G2:static:{static}:0", f"G3:admission:{admission}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1, out)
        self.assertIn("G3", out)

    def test_every_gate_passing_passes(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        admission = self.report("admission", [admission_row(PASSING)])
        code, out, _ = self.run_main([f"G2:static:{static}:0", f"G3:admission:{admission}:0"], self.enforced(PASSING))
        self.assertEqual(code, 0, out)
        self.assertIn("Verdict: PASS", out)

    def test_an_unread_pod_template_counts_as_a_failure(self) -> None:
        static = self.report("static", [static_row(PASSING, "not-evaluated", pod_template=True, allowed=False)])
        code, _, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1)

    def test_an_allowlisted_pod_template_does_not(self) -> None:
        static = self.report("static", [static_row(PASSING, "not-evaluated", pod_template=True, allowed=True)])
        code, _, _ = self.run_main([f"G2:static:{static}:0"], self.enforced(PASSING))
        self.assertEqual(code, 0)

    def test_missing_crd_is_not_a_failure_on_its_own(self) -> None:
        admission = self.report("admission", [admission_row(PASSING), admission_row(PASSING, "missing-crd")])
        code, _, _ = self.run_main([f"G3:admission:{admission}:0"], self.enforced(PASSING))
        self.assertEqual(code, 0)

    def test_an_out_of_scope_row_is_ignored(self) -> None:
        static = self.report("static", [static_row(PASSING), static_row(FAILING, "fail", in_scope=False)])
        code, out, _ = self.run_main([f"G2:static:{static}:0"], self.enforced(PASSING))
        self.assertEqual(code, 0, out)

    def test_a_stale_marker_fails_an_enforced_chapter(self) -> None:
        static = self.report("static", [static_row(PASSING, "stale-marker")])
        code, _, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1)


class SafetyTests(Case):
    def test_an_aborted_gate_fails_the_job_even_with_nothing_enforced(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        code, out, _ = self.run_main([f"G2:static:{static}:2"], self.enforced())
        self.assertEqual(code, 1, out)
        self.assertIn("aborted", out)

    def test_a_failed_gate_with_no_failing_row_fails_the_job(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1, out)
        self.assertIn("names no failing block", out)

    def test_an_enforced_chapter_no_report_mentions_fails(self) -> None:
        static = self.report("static", [static_row(FAILING, "fail")])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced(PASSING))
        self.assertEqual(code, 1, out)
        self.assertIn("NOT CHECKED", out)

    def test_a_report_only_path_that_does_not_exist_is_an_input_error(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        code, _, err = self.run_main([f"G2:static:{static}:0"], self.enforced(PASSING), self.report_only("16-gone/"))
        self.assertEqual(code, 2)
        self.assertIn("never be checked", err)

    def test_a_missing_report_only_file_is_an_input_error(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        code, _, err = self.run_main([f"G2:static:{static}:0"], self.enforced(PASSING), self.dir / "none.txt")
        self.assertEqual(code, 2)
        self.assertIn("report-only list", err)

    def test_an_enforced_path_that_does_not_exist_is_an_input_error(self) -> None:
        static = self.report("static", [static_row(PASSING)])
        code, _, err = self.run_main([f"G2:static:{static}:0"], self.enforced("01-core-workloads/99-gone.md"))
        self.assertEqual(code, 2)
        self.assertIn("never be checked", err)

    def test_a_missing_report_is_an_input_error(self) -> None:
        code, _, err = self.run_main([f"G2:static:{self.dir}/nope.json:0"], self.enforced(PASSING))
        self.assertEqual(code, 2)
        self.assertIn("does not exist", err)

    def test_no_gates_is_an_input_error(self) -> None:
        code, _, err = self.run_main([], self.enforced(PASSING))
        self.assertEqual(code, 2)
        self.assertIn("nothing to summarise", err)

    def test_a_malformed_gate_spec_is_an_input_error(self) -> None:
        code, _, err = self.run_main(["G2:static:only-three"], self.enforced(PASSING))
        self.assertEqual(code, 2)
        self.assertIn("NAME:static|admission:REPORT:EXIT", err)


class MatchingTests(Case):
    def test_a_directory_entry_enforces_everything_under_it(self) -> None:
        tree = "full-guide/examples/bookstore/raw-manifests/10-catalog-deploy.yaml"
        static = self.report("static", [static_row(tree, "fail")])
        code, out, _ = self.run_main([f"G2:static:{static}:1"], self.enforced("examples/bookstore/raw-manifests"))
        self.assertEqual(code, 1, out)

    def test_a_rendered_chart_is_covered_by_its_directory(self) -> None:
        (self.root / "examples/bookstore/helm/bookstore").mkdir(parents=True)
        rendered = "full-guide/examples/bookstore/helm/bookstore [helm template -f values-prod.yaml]"
        static = self.report("static", [static_row(rendered, "fail")])
        code, _, _ = self.run_main([f"G2:static:{static}:1"], self.enforced("examples/bookstore/helm/bookstore"))
        self.assertEqual(code, 1)

    def test_a_prefix_that_is_not_a_path_boundary_does_not_match(self) -> None:
        self.assertTrue(cs.covers("01-core-workloads", "01-core-workloads/01-pods.md"))
        self.assertFalse(cs.covers("01-core", "01-core-workloads/01-pods.md"))
        self.assertTrue(cs.covers("01-core-workloads/01-pods.md", "01-core-workloads/01-pods.md"))

    def test_chapter_names_lose_the_guide_prefix(self) -> None:
        self.assertEqual(cs.normalise("full-guide/examples/bookstore/x.yaml"), "examples/bookstore/x.yaml")
        self.assertEqual(cs.normalise("05-security/02-pod-security.md"), "05-security/02-pod-security.md")


if __name__ == "__main__":
    unittest.main()
