#!/usr/bin/env python3
"""Tests for the scanner half of the exceptions registry (`.trivyignore.yaml`).

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

Covers the registry file (entries, the 12-month rule, path matching) and how
the static gate honours it: a finding is dropped only for a sound, unexpired
entry, and the control fixtures are never silenced.
"""

from __future__ import annotations

import tempfile
import unittest
from datetime import date, datetime, timedelta
from pathlib import Path

import scanner_registry as sr
from test_also_trees import HAVE_HELM, VIOLATING_TEMPLATE, make_chart
from test_gates import HARDENED, HAVE_TRIVY, StaticRunner, fixture, write
import static_gate as sg

TODAY = date.today()


def entry(id_="KSV-0012", paths=("a/b.yaml",), statement="checked by hand", expired_at=None, section="misconfigurations"):
    return {
        "section": section,
        "body": {
            "id": id_, "paths": list(paths), "statement": statement,
            "expired_at": expired_at or TODAY + timedelta(days=200),
        },  # fmt: skip
    }


def registry_text(*entries) -> str:
    sections: dict[str, list] = {}
    for item in entries:
        sections.setdefault(item["section"], []).append(item["body"])
    import yaml

    return yaml.safe_dump(sections, sort_keys=False)


class MonthMathTests(unittest.TestCase):
    def test_add_months(self):
        self.assertEqual(sr.add_months(date(2026, 10, 31), 12), date(2027, 10, 31))
        self.assertEqual(sr.add_months(date(2028, 2, 29), 12), date(2029, 2, 28))
        self.assertEqual(sr.add_months(date(2026, 1, 31), 1), date(2026, 2, 28))
        self.assertEqual(sr.add_months(date(2026, 12, 15), 1), date(2027, 1, 15))


class DateRuleTests(unittest.TestCase):
    def test_a_date_inside_the_window_is_sound(self):
        for value in (TODAY + timedelta(days=1), sr.add_months(TODAY, 12), (TODAY + timedelta(days=30)).isoformat()):
            self.assertIsNone(sr.date_problem(value, TODAY), value)

    def test_a_datetime_counts_as_its_date(self):
        self.assertIsNone(sr.date_problem(datetime.combine(TODAY + timedelta(days=5), datetime.min.time()), TODAY))

    def test_today_and_the_past_are_expired(self):
        for value in (TODAY, TODAY - timedelta(days=1)):
            self.assertIn("expired", sr.date_problem(value, TODAY))

    def test_more_than_twelve_months_out_is_refused(self):
        self.assertIn("12 months", sr.date_problem(sr.add_months(TODAY, 12) + timedelta(days=1), TODAY))

    def test_a_missing_or_garbled_date_is_refused(self):
        for value in (None, "", "soon", "2026-13-40", 20270101, ["2027-01-01"]):
            self.assertIn("date", sr.date_problem(value, TODAY), repr(value))


class PathMatchTests(unittest.TestCase):
    def test_matching_rules(self):
        cases = [
            ("a/b.yaml", "a/b.yaml", False, True),
            ("./a/b.yaml", "a/b.yaml", False, True),
            ("a/*.yaml", "a/b.yaml", False, True),
            ("a/*.yaml", "a/x/b.yaml", False, False),
            ("a/**/*.yaml", "a/x/y/b.yaml", False, True),
            ("a/**", "a/x/b.yaml", False, True),
            ("**/b.yaml", "/abs/dir/b.yaml", False, True),
            ("**/b.yaml", "b.yaml", False, True),
            ("a/b?.yaml", "a/bc.yaml", False, True),
            ("a", "a/x/b.yaml", False, True),  # a directory covers what is under it
            ("a/", "a/x/b.yaml", False, True),
            ("ab", "a/x/b.yaml", False, False),
            ("a/c.yaml", "a/b.yaml", False, False),
            ("x/y/templates/*.yaml", "x/y", True, True),  # a rendered directory covers paths inside it
            ("x/y/templates/*.yaml", "x/y", False, False),
            ("x/other/*.yaml", "x/y", True, False),
            ("x", "x/y", True, True),
        ]
        for pattern, target, within, want in cases:
            with self.subTest(pattern=pattern, target=target, within=within):
                self.assertEqual(sr.path_matches(pattern, target, within=within), want)


class RegistryLoadTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def load(self, text):
        path = self.tmp / ".trivyignore.yaml"
        path.write_text(text, encoding="utf-8")
        return sr.load(path, TODAY)

    def test_a_comment_only_file_is_an_empty_registry(self):
        registry = self.load("# nothing excepted yet\n")
        self.assertEqual((registry.entries, registry.problems), ([], []))

    def test_a_missing_file_is_an_empty_registry_only_when_asked(self):
        self.assertEqual(sr.load(self.tmp / "absent.yaml", TODAY, missing_ok=True).entries, [])
        with self.assertRaises(sr.RegistryError):
            sr.load(self.tmp / "absent.yaml", TODAY)

    def test_entries_are_read_by_section(self):
        registry = self.load(registry_text(entry("KSV-0012"), entry("CVE-2026-1", section="vulnerabilities")))
        self.assertEqual([(e.section, e.id, e.problems) for e in registry.entries],
                         [("misconfigurations", "KSV-0012", ()), ("vulnerabilities", "CVE-2026-1", ())])  # fmt: skip
        self.assertTrue(all(e.honoured for e in registry.entries))

    def test_structure_errors_are_file_problems(self):
        for text in ("- just\n- a list\n", "bogus: []\n", "misconfigurations: nope\n", "misconfigurations:\n  - plain string\n"):
            with self.subTest(text):
                self.assertTrue(self.load(text).problems)

    def test_invalid_yaml_is_a_registry_error(self):
        with self.assertRaises(sr.RegistryError):
            self.load("misconfigurations: [unclosed\n")

    def test_each_way_an_entry_can_be_unsound(self):
        base = entry()["body"]
        cases = {
            "no statement": {**base, "statement": " "},
            "no paths": {**base, "paths": []},
            "paths not a list": {**base, "paths": "a/b.yaml"},
            "no id": {**base, "id": ""},
            "expired": {**base, "expired_at": TODAY - timedelta(days=1)},
            "too far": {**base, "expired_at": sr.add_months(TODAY, 12) + timedelta(days=1)},
            "no date": {k: v for k, v in base.items() if k != "expired_at"},
            "purls": {**base, "purls": ["pkg:npm/x"]},
        }
        for name, body in cases.items():
            with self.subTest(name):
                registry = self.load(registry_text({"section": "misconfigurations", "body": body}))
                (found,) = registry.entries
                self.assertTrue(found.problems, name)
                self.assertFalse(found.honoured)


class CoverageTests(unittest.TestCase):
    def registry(self, *entries):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        path = Path(self._dir.name) / ".trivyignore.yaml"
        path.write_text(registry_text(*entries), encoding="utf-8")
        return sr.load(path, TODAY)

    def test_covered_returns_only_the_ids_an_entry_names_for_that_path(self):
        registry = self.registry(entry("KSV-0012", ["a/b.yaml"]), entry("KSV-0014", ["other.yaml"]))
        self.assertEqual(registry.covered({"KSV-0012", "KSV-0014", "KSV-0001"}, "a/b.yaml"), {"KSV-0012"})

    def test_the_avd_prefix_is_the_same_id(self):
        registry = self.registry(entry("AVD-KSV-0012", ["a/b.yaml"]))
        self.assertEqual(registry.covered({"KSV-0012"}, "a/b.yaml"), {"KSV-0012"})

    def test_an_unsound_entry_covers_nothing(self):
        registry = self.registry(entry("KSV-0012", ["a/b.yaml"], statement=""))
        self.assertEqual(registry.covered({"KSV-0012"}, "a/b.yaml"), set())

    def test_other_sections_do_not_cover_misconfigurations(self):
        registry = self.registry(entry("KSV-0012", ["a/b.yaml"], section="vulnerabilities"))
        self.assertEqual(registry.covered({"KSV-0012"}, "a/b.yaml"), set())

    def test_a_rendered_directory_is_covered_by_a_path_inside_it(self):
        registry = self.registry(entry("KSV-0012", ["x/y/templates/*.yaml"]))
        self.assertEqual(registry.covered({"KSV-0012"}, "x/y", within=True), {"KSV-0012"})
        self.assertEqual(registry.covered({"KSV-0012"}, "x/y"), set())


@unittest.skipUnless(HAVE_TRIVY, "trivy is not on PATH")
class RegistryHonouredTests(StaticRunner, unittest.TestCase):
    """The static gate drops a finding only for a sound, unexpired registry entry."""

    def setUp(self):
        super().setUp()
        self.tree = self.tmp / "examples"
        write(self.tree, "bad.yaml", fixture("violating-deployment.yaml"))
        self.base = self.manifest([("a.md", HARDENED)])
        rc, report = self.run_gate(self.base, "--also", str(self.tree))
        self.assertEqual(rc, 1, self.output)
        self.ids = next(b["ids"] for b in report["blocks"] if b["chapter"].endswith("bad.yaml"))

    def registry(self, ids=None, paths=("**/bad.yaml",), **kwargs):
        path = self.tmp / ".trivyignore.yaml"
        path.write_text(registry_text(*[entry(i, paths, **kwargs) for i in ids or self.ids]), encoding="utf-8")
        return ["--registry", str(path)]

    def gate(self, *args):
        return self.run_gate(self.base, "--also", str(self.tree), *args)

    def test_a_sound_entry_per_finding_clears_the_file_and_the_run_says_so(self):
        rc, report = self.gate(*self.registry())
        self.assertEqual(rc, 0, self.output)
        row = next(b for b in report["blocks"] if b["chapter"].endswith("bad.yaml"))
        self.assertEqual((row["status"], sorted(row["suppressed"])), ("pass", sorted(self.ids)))
        self.assertEqual(report["summary"]["suppressed"], len(self.ids))
        self.assertIn("suppressed by the registry", self.output)

    def test_one_finding_left_uncovered_still_fails_the_file(self):
        rc, report = self.gate(*self.registry(ids=self.ids[1:]))
        self.assertEqual(rc, 1)
        row = next(b for b in report["blocks"] if b["chapter"].endswith("bad.yaml"))
        self.assertEqual(row["ids"], self.ids[:1])

    def test_an_expired_entry_changes_nothing_and_is_named(self):
        rc, _ = self.gate(*self.registry(expired_at=TODAY - timedelta(days=1)))
        self.assertEqual(rc, 1)
        self.assertIn("not honoured", self.output)
        self.assertIn("expired", self.output)

    def test_an_entry_more_than_a_year_out_changes_nothing(self):
        rc, _ = self.gate(*self.registry(expired_at=sr.add_months(TODAY, 12) + timedelta(days=1)))
        self.assertEqual(rc, 1)
        self.assertIn("12 months", self.output)

    def test_an_entry_without_a_statement_changes_nothing(self):
        self.assertEqual(self.gate(*self.registry(statement=""))[0], 1)

    def test_an_entry_for_another_path_changes_nothing(self):
        self.assertEqual(self.gate(*self.registry(paths=("**/other.yaml",)))[0], 1)

    def test_a_catch_all_path_cannot_silence_the_control_fixtures(self):
        # The control runs on the raw scan, so a registry that covers every path
        # leaves the gate able to see a violation and does not abort it.
        rc, _ = self.gate(*self.registry(ids=sorted(set(sg.CORE) | set(self.ids)), paths=("**",)))
        self.assertEqual(rc, 0, self.output)
        self.assertNotIn("aborted", self.output)

    def test_a_chapter_block_is_addressed_by_its_path_under_the_guide_root(self):
        manifest = self.manifest([("x/y.md", fixture("violating-deployment.yaml")), ("a.md", HARDENED)])
        self.assertEqual(self.run_gate(manifest)[0], 1)
        for guide_root, paths in (("full-guide", ["full-guide/x/y.md"]), ("docs", ["docs/x/y.md"]), ("docs", ["full-guide/x/y.md"])):
            with self.subTest(guide_root=guide_root, paths=paths):
                rc, _ = self.run_gate(manifest, "--guide-root", guide_root, *self.registry(paths=paths))
                self.assertEqual(rc, 0 if paths == [f"{guide_root}/x/y.md"] else 1, self.output)

    def test_a_missing_or_unreadable_registry_aborts(self):
        self.assertEqual(self.gate("--registry", str(self.tmp / "absent.yaml"))[0], 2)
        broken = self.tmp / "broken.yaml"
        broken.write_text("misconfigurations: [unclosed\n", encoding="utf-8")
        self.assertEqual(self.gate("--registry", str(broken))[0], 2)
        broken.write_text("- a\n- list\n", encoding="utf-8")
        self.assertEqual(self.gate("--registry", str(broken))[0], 2)

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_rendered_chart_is_addressed_by_its_directory_or_a_path_inside_it(self):
        chart_tree = self.tmp / "charts"
        make_chart(chart_tree, template=VIOLATING_TEMPLATE)
        rc, report = self.run_gate(self.base, "--also", str(chart_tree))
        self.assertEqual(rc, 1)
        ids = next(b["ids"] for b in report["blocks"] if b["chapter"].endswith("[helm template]"))
        for paths in (["**/helm/web"], ["**/helm/web/templates/*.yaml"]):
            with self.subTest(paths=paths):
                rc, _ = self.run_gate(self.base, "--also", str(chart_tree), *self.registry(ids=ids, paths=paths))
                self.assertEqual(rc, 0, self.output)

    def test_an_inline_trivy_ignore_comment_is_a_failure_not_a_suppression(self):
        manifest = self.manifest([("a.md", HARDENED + "# trivy:ignore:KSV-0014\n"), ("b.md", HARDENED)])
        rc, report = self.run_gate(manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(report["blocks"][0]["ids"], ["inline-trivy-ignore"])


if __name__ == "__main__":
    unittest.main()
