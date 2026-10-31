#!/usr/bin/env python3
"""Tests for the registry half of G5 (`registry_gate.py`).

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

The gate has two registries and checks each in both directions. Namespaces
above `restricted` live in `security/namespace-exceptions.yaml`; scanner
exceptions live in `.trivyignore.yaml`. Temporary trees only.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import textwrap
import unittest
from collections import Counter
from datetime import date, timedelta
from pathlib import Path
from unittest import mock

import yaml

import registry_gate as rg
import scanner_registry as sr
from test_gates import HARDENED, HAVE_TRIVY, fenced, fixture, write
from test_also_trees import HAVE_HELM, make_chart
from test_scanner_registry import entry, registry_text

TODAY = date.today()
CITATION = "https://kubernetes.io/docs/concepts/security/pod-security-standards/"


def namespace_doc(name: str, **labels: str) -> str:
    lines = ["apiVersion: v1", "kind: Namespace", "metadata:", f"  name: {name}", "  labels:"]
    lines += [f"    pod-security.kubernetes.io/{mode}: {level}" for mode, level in labels.items()]
    return "\n".join(lines) + "\n"


def ns_entry(namespace="psa-lab", level="privileged", **over) -> dict:
    body = {
        "namespace": namespace, "level": level,
        "reason": "the lab shows what the privileged profile allows",
        "upstream": CITATION, "chapter": "01-core/01-a.md",
        "expires": TODAY + timedelta(days=200),
    }  # fmt: skip
    body.update(over)
    return {k: v for k, v in body.items() if v is not None}


def ns_registry_text(*entries: dict) -> str:
    return yaml.safe_dump({"exceptions": list(entries)}, sort_keys=False)


LAB_CHAPTER = (
    "# Lab\n\nThe namespace is labelled `pod-security.kubernetes.io/enforce=privileged` here.\n\n"
    + fenced("kubectl create ns psa-lab\nkubectl label ns psa-lab pod-security.kubernetes.io/enforce=privileged\n", "bash")
    + "\n"
    + fenced(namespace_doc("bookstore", enforce="restricted", warn="restricted"))
)


class LabelReaderTests(unittest.TestCase):
    def uses(self, uses):
        return {(u.namespace, u.mode, u.level) for u in uses}

    def test_namespace_documents_give_one_use_per_mode_and_ignore_versions(self):
        text = namespace_doc("tools", enforce="privileged", warn="baseline", **{"enforce-version": "latest"})
        text += "    team: platform\n"
        uses = rg.labels_in_documents(list(yaml.safe_load_all(text)), "x.yaml")
        self.assertEqual(self.uses(uses), {("tools", "enforce", "privileged"), ("tools", "warn", "baseline")})
        self.assertEqual({u.where for u in uses}, {"x.yaml"})

    def test_a_namespace_nested_in_another_object_is_found(self):
        doc = {
            "kind": "Composition",
            "spec": {"resources": [{"base": {"spec": {"manifest": yaml.safe_load(namespace_doc("tenant", audit="baseline"))}}}]},
        }  # fmt: skip
        self.assertEqual(self.uses(rg.labels_in_documents([doc], "c")), {("tenant", "audit", "baseline")})

    def test_the_same_labels_on_another_kind_are_not_a_namespace(self):
        text = namespace_doc("x", enforce="privileged").replace("kind: Namespace", "kind: Deployment")
        self.assertEqual(rg.labels_in_documents(list(yaml.safe_load_all(text)), "d"), [])

    def test_shell_forms(self):
        key = "pod-security.kubernetes.io"
        cases = {
            f"kubectl label ns psa-lab {key}/enforce=privileged": {("psa-lab", "enforce", "privileged")},
            f"kubectl label namespace x {key}/enforce=baseline --overwrite": {("x", "enforce", "baseline")},
            f"kubectl label --overwrite ns/runtime-test {key}/enforce=baseline": {("runtime-test", "enforce", "baseline")},
            f"kubectl --context kind-lab label ns x {key}/audit=privileged": {("x", "audit", "privileged")},
            f"$ kubectl label ns x {key}/warn=baseline": {("x", "warn", "baseline")},
            f"kubectl label ns x \\\n  {key}/enforce=baseline \\\n  {key}/warn=baseline --overwrite":
                {("x", "enforce", "baseline"), ("x", "warn", "baseline")},
            f"kubectl label ns x {key}/enforce=restricted": {("x", "enforce", "restricted")},
            f'kubectl label ns "$NS" {key}/enforce=privileged': {("$NS", "enforce", "privileged")},
            f"kubectl label ns x {key}/enforce-": set(),
            f"kubectl label ns x {key}/enforce-version=latest": set(),
            f"kubectl label pod web {key}/enforce=privileged": set(),
            "kubectl label ns x team=platform": set(),
            f"# kubectl label ns x {key}/enforce=privileged": set(),
        }  # fmt: skip
        for text, want in cases.items():
            with self.subTest(text):
                self.assertEqual(self.uses(rg.labels_in_shell(text + "\n", "s")), want)

    def test_terraform_labels_take_the_nearest_name_above_them(self):
        text = textwrap.dedent(
            """\
            resource "kubernetes_namespace" "falco" {
              metadata {
                name = "falco"
                labels = {
                  "pod-security.kubernetes.io/enforce"         = "privileged"
                  "pod-security.kubernetes.io/enforce-version" = "latest"
                  "pod-security.kubernetes.io/warn"            = "baseline"
                }
              }
            }
            resource "kubernetes_namespace" "other" {
              metadata {
                name = "other"
                labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
              }
            }
            """
        )
        self.assertEqual(
            self.uses(rg.labels_in_terraform(text, "falco.tf")),
            {("falco", "enforce", "privileged"), ("falco", "warn", "baseline"), ("other", "enforce", "restricted")},
        )
        self.assertEqual(rg.labels_in_terraform('"pod-security.kubernetes.io/enforce" = "privileged"\n', "t.tf"), [])

    def test_hits_count_every_literal_label_above_restricted_and_skip_comments(self):
        text = textwrap.dedent(
            """\
            pod-security.kubernetes.io/enforce: privileged
            # pod-security.kubernetes.io/enforce: baseline
            kubectl label ns a pod-security.kubernetes.io/warn=baseline
            "pod-security.kubernetes.io/audit" = "privileged"
            ns.Labels["pod-security.kubernetes.io/enforce"] = "privileged"
            pod-security.kubernetes.io/enforce-version: privileged
            pod-security.kubernetes.io/enforce: restricted
            """
        )
        self.assertEqual(
            rg.hits_above_restricted(text),
            Counter({("enforce", "privileged"): 2, ("warn", "baseline"): 1, ("audit", "privileged"): 1}),
        )


class TreeScanTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "guide"
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.key = "pod-security.kubernetes.io"

    def scan(self, **kwargs):
        return rg.scan_labels(self.root, self.work, **kwargs)

    def found(self, scan):
        return {(u.namespace, u.mode, u.level) for u in scan.uses}

    def test_every_place_a_label_is_written_is_read(self):
        write(self.root, "01-core/01-a.md", LAB_CHAPTER)
        write(self.root, "examples/ns.yaml", namespace_doc("tools", enforce="baseline"))
        write(self.root, "examples/lab.sh", f"kubectl label ns shell-lab {self.key}/enforce=privileged\n")
        write(self.root, "examples/evidence.txt", f"$ kubectl label ns shell-lab {self.key}/enforce=privileged\nnamespace/shell-lab labeled\n")
        write(
            self.root, "examples/falco.tf",
            f'resource "kubernetes_namespace" "falco" {{\n  metadata {{\n    name = "falco"\n    labels = {{\n      "{self.key}/enforce" = "privileged"\n    }}\n  }}\n}}\n',
        )  # fmt: skip
        write(
            self.root, "01-core/02-b.md",
            "# B\n\n" + fenced(f"kubectl apply -f - <<EOF\n{namespace_doc('heredoc-ns', enforce='baseline')}EOF\n", "bash"),
        )
        scan = self.scan()
        self.assertEqual(scan.unattached, [])
        self.assertEqual(
            self.found(scan),
            {
                ("psa-lab", "enforce", "privileged"), ("bookstore", "enforce", "restricted"), ("bookstore", "warn", "restricted"),
                ("tools", "enforce", "baseline"), ("shell-lab", "enforce", "privileged"), ("falco", "enforce", "privileged"),
                ("heredoc-ns", "enforce", "baseline"),
            },
        )  # fmt: skip

    def test_prose_outside_a_fence_is_not_a_label(self):
        write(self.root, "01-core/01-a.md", LAB_CHAPTER)
        self.assertEqual(self.scan().unattached, [])

    def test_captured_output_is_not_a_label_anyone_writes(self):
        shown = namespace_doc("shown", enforce="privileged")
        write(self.root, "01-core/01-a.md", "# A\n\n<!-- gate: output -->\n\n" + fenced(shown))
        write(self.root, "examples/ns.yaml", namespace_doc("bookstore", enforce="restricted"))
        scan = self.scan()
        self.assertEqual((scan.unattached, {u.namespace for u in scan.uses}), ([], {"bookstore"}))

    def test_unpublished_part_18_is_not_read(self):
        write(self.root, "18-scratch/x.md", fenced(f"kubectl label ns hidden {self.key}/enforce=privileged\n", "bash"))
        write(self.root, "examples/ns.yaml", namespace_doc("bookstore", enforce="restricted"))
        self.assertNotIn("hidden", {u.namespace for u in self.scan().uses})

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_raw_chart_templates_are_not_read(self):
        # The raw template mentions `privileged`, but the rendered chart never sets it.
        template = (
            "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {{ .Release.Name }}\n  labels:\n"
            f"    {self.key}/enforce: restricted\n"
            f"{{{{- if .Values.never }}}}\n    {self.key}/warn: privileged\n{{{{- end }}}}\n"
        )
        make_chart(self.root / "examples", rel="helm/c", template=template)
        write(self.root / "examples/helm/c", "values.yaml", "never: false\n")
        scan = self.scan()
        self.assertEqual(scan.unattached, [])
        self.assertEqual({u.level for u in scan.uses}, {"restricted"})

    def test_a_label_no_reader_can_attach_to_a_namespace_is_named(self):
        write(self.root, "examples/ctrl.go", f'ns.Labels["{self.key}/enforce"] = "privileged"\n')
        write(self.root, "examples/ns.yaml", namespace_doc("bookstore", enforce="restricted"))
        (message,) = self.scan().unattached
        self.assertIn("ctrl.go", message)
        self.assertIn("enforce=privileged", message)

    def test_a_manifest_that_does_not_parse_cannot_hide_its_label(self):
        write(self.root, "examples/broken.yaml", f"kind: Namespace\nmetadata: [unclosed\n  labels:\n    {self.key}/enforce: privileged\n")
        (message,) = self.scan().unattached
        self.assertIn("broken.yaml", message)

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_chart_is_read_rendered_with_each_values_file(self):
        template = f"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: web\n  labels:\n    {self.key}/enforce: {{{{ .Values.level }}}}\n"
        make_chart(self.root / "examples", template=template, **{"values-priv.yaml": "level: privileged\n"})
        write(self.root / "examples/helm/web", "values.yaml", "level: restricted\n")
        scan = self.scan()
        by_where = {u.where: u.level for u in scan.uses}
        self.assertEqual(
            sorted(by_where.values()), ["privileged", "restricted"], by_where
        )
        self.assertTrue(any("values-priv.yaml" in where for where in by_where), by_where)
        self.assertEqual(scan.unattached, [])


class NamespaceRegistryTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        write(self.tmp / "guide", "01-core/01-a.md", "# A\n")

    def load(self, *entries, raw=None):
        path = self.tmp / "ns.yaml"
        path.write_text(raw if raw is not None else ns_registry_text(*entries), encoding="utf-8")
        return rg.load_namespace_registry(path, TODAY, self.tmp / "guide")

    def test_a_sound_entry_has_no_problems(self):
        registry = self.load(ns_entry())
        self.assertEqual((registry.problems, [e.problems for e in registry.entries]), ([], [()]))

    def test_a_comment_only_file_is_empty(self):
        registry = self.load(raw="# none yet\n")
        self.assertEqual((registry.entries, registry.problems), ([], []))

    def test_each_way_an_entry_can_be_unsound(self):
        cases = {
            "no reason": ns_entry(reason=" "),
            "no reason key": ns_entry(reason=None),
            "no citation": ns_entry(upstream=""),
            "no namespace": ns_entry(namespace=None),
            "not a namespace name": ns_entry(namespace="Not_A_Name"),
            "restricted is not an exception": ns_entry(level="restricted"),
            "unknown level": ns_entry(level="open"),
            "no level": ns_entry(level=None),
            "chapter missing from the guide": ns_entry(chapter="01-core/99-nope.md"),
            "no chapter": ns_entry(chapter=None),
            "expired": ns_entry(expires=TODAY - timedelta(days=1)),
            "expires today": ns_entry(expires=TODAY),
            "too far out": ns_entry(expires=sr.add_months(TODAY, 12) + timedelta(days=1)),
            "no expiry": ns_entry(expires=None),
            "garbled expiry": ns_entry(expires="someday"),
        }
        for name, body in cases.items():
            with self.subTest(name):
                (found,) = self.load(body).entries
                self.assertTrue(found.problems, name)

    def test_the_last_allowed_day_is_twelve_months_out(self):
        (found,) = self.load(ns_entry(expires=sr.add_months(TODAY, 12))).entries
        self.assertEqual(found.problems, ())

    def test_a_namespace_registered_twice_is_a_problem(self):
        registry = self.load(ns_entry(), ns_entry())
        self.assertTrue(any("twice" in p for p in registry.problems), registry.problems)

    def test_only_sound_unique_entries_are_usable_exceptions(self):
        registry = self.load(
            ns_entry("good", "baseline"),
            ns_entry("expired", expires=TODAY - timedelta(days=1)),
            ns_entry("twice"),
            ns_entry("twice", "baseline"),
        )
        usable = rg.usable_exceptions(registry)
        self.assertEqual({name: entry.level for name, entry in usable.items()}, {"good": "baseline"})
        self.assertEqual(usable["good"].chapter, "01-core/01-a.md")

    def test_structure_errors_are_file_problems(self):
        for raw in ("- a\n", "exceptions: nope\n", "exceptions:\n  - text\n", "other: []\n"):
            with self.subTest(raw):
                self.assertTrue(self.load(raw=raw).problems)

    def test_invalid_yaml_is_an_error(self):
        with self.assertRaises(sr.RegistryError):
            self.load(raw="exceptions: [unclosed\n")


class NamespaceCheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        write(self.tmp / "guide", "01-core/01-a.md", "# A\n")

    def check(self, uses, *entries):
        path = self.tmp / "ns.yaml"
        path.write_text(ns_registry_text(*entries), encoding="utf-8")
        registry = rg.load_namespace_registry(path, TODAY, self.tmp / "guide")
        return rg.namespace_problems(rg.TreeScan(uses, []), registry)

    @staticmethod
    def use(namespace, mode, level, where="a.md"):
        return rg.LabelUse(namespace, mode, level, where)

    def test_a_registered_namespace_in_use_is_clean(self):
        uses = [self.use("psa-lab", "enforce", "privileged"), self.use("bookstore", "enforce", "restricted")]
        self.assertEqual(self.check(uses, ns_entry()), [])

    def test_an_unregistered_namespace_above_restricted_is_named_with_where(self):
        problems = self.check([self.use("falco", "enforce", "privileged", "falco.tf")])
        (message,) = problems
        for needle in ("falco", "privileged", "falco.tf", "not registered"):
            self.assertIn(needle, message)

    def test_a_registered_namespace_nothing_uses_is_stale(self):
        (message,) = self.check([self.use("bookstore", "enforce", "restricted")], ns_entry())
        self.assertIn("psa-lab", message)
        self.assertIn("no longer", message)

    def test_a_namespace_now_restricted_everywhere_is_stale(self):
        (message,) = self.check([self.use("psa-lab", "enforce", "restricted")], ns_entry())
        self.assertIn("no longer", message)

    def test_the_registered_level_must_be_the_one_in_use(self):
        (low,) = self.check([self.use("psa-lab", "enforce", "privileged")], ns_entry(level="baseline"))
        self.assertIn("privileged", low)
        (high,) = self.check([self.use("psa-lab", "enforce", "baseline")], ns_entry(level="privileged"))
        self.assertIn("baseline", high)

    def test_the_most_permissive_mode_decides_the_level(self):
        uses = [self.use("psa-lab", "enforce", "baseline"), self.use("psa-lab", "warn", "privileged")]
        self.assertEqual(self.check(uses, ns_entry(level="privileged")), [])

    def test_an_unsound_entry_is_reported_even_when_the_namespace_matches(self):
        problems = self.check([self.use("psa-lab", "enforce", "privileged")], ns_entry(reason=""))
        self.assertTrue(any("reason" in p for p in problems), problems)

    def test_unattached_labels_are_problems(self):
        path = self.tmp / "ns.yaml"
        path.write_text(ns_registry_text(), encoding="utf-8")
        registry = rg.load_namespace_registry(path, TODAY, self.tmp / "guide")
        problems = rg.namespace_problems(rg.TreeScan([], ["ctrl.go: 1 label"]), registry)
        self.assertEqual(problems, ["ctrl.go: 1 label"])


class RegistryGateCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "guide"
        write(self.root, "01-core/01-a.md", LAB_CHAPTER)
        self.ns_file = self.tmp / "ns.yaml"
        self.ns_file.write_text(ns_registry_text(ns_entry()), encoding="utf-8")
        self.scanner_file = self.tmp / "ignore.yaml"
        self.scanner_file.write_text("# nothing excepted\n", encoding="utf-8")

    def run_gate(self, *args, namespaces=True, scanner=True):
        argv = ["--root", str(self.root), "--scan", str(self.tmp), "--trivy", "no-such-trivy-binary"]
        if namespaces:
            argv += ["--namespace-registry", str(self.ns_file)]
        if scanner:
            argv += ["--scanner-registry", str(self.scanner_file)]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = rg.main([*argv, *args])
        self.output = out.getvalue()
        return rc

    def test_a_tree_and_registry_that_agree_pass(self):
        self.assertEqual(self.run_gate(), 0, self.output)
        self.assertIn("registry gate", self.output)

    def test_an_unregistered_namespace_fails_and_is_named(self):
        self.ns_file.write_text(ns_registry_text(), encoding="utf-8")
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("psa-lab", self.output)

    def test_a_stale_registration_fails(self):
        self.ns_file.write_text(ns_registry_text(ns_entry(), ns_entry("falco")), encoding="utf-8")
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("falco", self.output)

    def test_an_expired_and_a_too_distant_entry_fail(self):
        for expires in (TODAY - timedelta(days=1), sr.add_months(TODAY, 12) + timedelta(days=1)):
            with self.subTest(expires=expires):
                self.ns_file.write_text(ns_registry_text(ns_entry(expires=expires)), encoding="utf-8")
                self.assertEqual(self.run_gate(), 1)
                self.assertIn("expire", self.output)

    def test_today_can_be_pinned_for_a_repeatable_run(self):
        self.ns_file.write_text(ns_registry_text(ns_entry(expires=date(2030, 1, 1))), encoding="utf-8")
        self.assertEqual(self.run_gate("--today", "2029-12-31"), 0, self.output)
        self.assertEqual(self.run_gate("--today", "2030-01-01"), 1)

    def test_a_label_no_reader_can_attach_fails(self):
        write(self.root, "examples/ctrl.go", 'ns.Labels["pod-security.kubernetes.io/enforce"] = "privileged"\n')
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("ctrl.go", self.output)

    def test_a_tree_with_no_restricted_label_at_all_means_the_reader_is_blind(self):
        (self.root / "01-core/01-a.md").write_text(
            fenced("kubectl label ns psa-lab pod-security.kubernetes.io/enforce=privileged\n", "bash"), encoding="utf-8"
        )
        self.assertEqual(self.run_gate(), 2)
        self.assertIn("restricted", self.output)

    def test_a_missing_root_or_registry_exits_two(self):
        self.assertEqual(self.run_gate("--root", str(self.tmp / "nope")), 2)
        self.assertEqual(self.run_gate("--namespace-registry", str(self.tmp / "absent.yaml")), 2)
        self.assertEqual(self.run_gate("--scanner-registry", str(self.tmp / "absent.yaml")), 2)

    def test_an_unreadable_registry_exits_two(self):
        self.ns_file.write_text("exceptions: [unclosed\n", encoding="utf-8")
        self.assertEqual(self.run_gate(), 2)

    def test_an_absent_default_registry_is_an_empty_one(self):
        with mock.patch.object(rg, "DEFAULT_NAMESPACE_REGISTRY", self.tmp / "none.yaml"):
            self.assertEqual(self.run_gate(namespaces=False), 1)
        self.assertIn("psa-lab", self.output)

    def test_the_report_lists_what_was_found(self):
        report = self.tmp / "report.json"
        self.assertEqual(self.run_gate("--report", str(report)), 0, self.output)
        data = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(data["problems"], [])
        self.assertIn(["psa-lab", "privileged"], [[n["namespace"], n["level"]] for n in data["namespaces"]])

    def test_a_trivyignore_text_file_is_a_suppression_outside_the_registry(self):
        write(self.root, "examples/.trivyignore", "KSV-0012\n")
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("outside the registry", self.output)

    def test_a_second_yaml_ignore_file_is_a_suppression_outside_the_registry(self):
        write(self.root, "examples/app/.trivyignore.yaml", "misconfigurations: []\n")
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("outside the registry", self.output)

    def test_trivy_is_not_needed_while_the_scanner_registry_is_empty(self):
        self.assertEqual(self.run_gate(), 0, self.output)

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_label_set_only_by_a_values_file_is_found_and_must_be_registered(self):
        template = f"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: web\n  labels:\n    pod-security.kubernetes.io/enforce: {{{{ .Values.level }}}}\n"
        make_chart(self.root / "examples", template=template, **{"values-priv.yaml": "level: privileged\n"})
        write(self.root / "examples/helm/web", "values.yaml", "level: restricted\n")
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("web", self.output)
        self.ns_file.write_text(ns_registry_text(ns_entry(), ns_entry("web")), encoding="utf-8")
        self.assertEqual(self.run_gate(), 0, self.output)


class ScannerEntryUnitTests(unittest.TestCase):
    """Which scanner entries still match a finding, with the findings handed in."""

    def entries(self, *items):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "i.yaml"
            path.write_text(registry_text(*items), encoding="utf-8")
            return sr.load(path, TODAY).entries

    def test_an_entry_matches_a_finding_with_its_id_at_one_of_its_paths(self):
        (e,) = self.entries(entry("KSV-0012", ["a/*.yaml", "b/c.yaml"]))
        self.assertTrue(rg.entry_matches(e, [("b/c.yaml", "KSV-0012", False)]))
        self.assertTrue(rg.entry_matches(e, [("a/x.yaml", "AVD-KSV-0012", False)]))

    def test_the_wrong_id_or_the_wrong_path_matches_nothing(self):
        (e,) = self.entries(entry("KSV-0012", ["a/*.yaml"]))
        self.assertFalse(rg.entry_matches(e, [("a/x.yaml", "KSV-0014", False)]))
        self.assertFalse(rg.entry_matches(e, [("z/x.yaml", "KSV-0012", False)]))
        self.assertFalse(rg.entry_matches(e, []))

    def test_a_rendered_directory_finding_matches_a_path_inside_it(self):
        (e,) = self.entries(entry("KSV-0012", ["c/templates/*.yaml"]))
        self.assertTrue(rg.entry_matches(e, [("c", "KSV-0012", True)]))
        self.assertFalse(rg.entry_matches(e, [("c", "KSV-0012", False)]))

    def test_other_sections_are_read_from_a_plain_trivy_fs_run(self):
        (vuln, secret) = self.entries(
            entry("CVE-2026-1", ["svc/go.mod"], section="vulnerabilities"),
            entry("aws-access-key-id", ["svc/.env"], section="secrets"),
        )
        with mock.patch.object(rg, "trivy_fs_findings", return_value=[("svc/go.mod", "CVE-2026-1")]) as run:
            self.assertEqual(rg.stale_entries([vuln, secret], gate_view=[], scan=["."], trivy="trivy"), [secret])
        self.assertEqual({s for call in run.call_args_list for s in call.args[1]}, {"vuln", "secret"})


@unittest.skipUnless(HAVE_TRIVY, "trivy is not on PATH")
class ScannerRegistryCliTests(unittest.TestCase):
    """The scanner registry against a real Trivy run without the ignore file."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "guide"
        write(self.root, "01-core/01-a.md", LAB_CHAPTER)
        write(self.root, "examples/bad.yaml", fixture("violating-deployment.yaml"))
        write(self.root, "examples/Dockerfile", "FROM alpine:3.20\nRUN echo hi\n")
        self.ns_file = self.tmp / "ns.yaml"
        self.ns_file.write_text(ns_registry_text(ns_entry()), encoding="utf-8")
        self.scanner_file = self.tmp / "ignore.yaml"

    def run_gate(self, *entries):
        self.scanner_file.write_text(registry_text(*entries), encoding="utf-8")
        argv = [
            "--root", str(self.root), "--also", str(self.root / "examples"), "--scan", str(self.root / "examples"),
            "--namespace-registry", str(self.ns_file), "--scanner-registry", str(self.scanner_file),
        ]  # fmt: skip
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = rg.main(argv)
        self.output = out.getvalue()
        return rc

    def test_entries_that_still_match_a_finding_pass(self):
        self.assertEqual(self.run_gate(entry("KSV-0012", ["**/examples/bad.yaml"])), 0, self.output)

    def test_an_entry_for_a_finding_the_scanner_no_longer_reports_is_stale(self):
        self.assertEqual(self.run_gate(entry("KSV-9999", ["**/examples/bad.yaml"])), 1)
        self.assertIn("KSV-9999", self.output)
        self.assertIn("matches no finding", self.output)

    def test_an_entry_for_a_path_that_reports_nothing_is_stale(self):
        self.assertEqual(self.run_gate(entry("KSV-0012", ["**/examples/gone.yaml"])), 1)
        self.assertIn("matches no finding", self.output)

    def test_an_entry_for_a_hardened_file_is_stale(self):
        write(self.root, "examples/good.yaml", HARDENED)
        self.assertEqual(self.run_gate(entry("KSV-0012", ["**/examples/good.yaml"])), 1)

    def test_a_finding_in_a_chapter_block_counts(self):
        write(self.root, "01-core/02-bad.md", "# B\n\n" + fenced(fixture("violating-deployment.yaml")))
        self.assertEqual(self.run_gate(entry("KSV-0012", ["**/01-core/02-bad.md"])), 0, self.output)

    def test_a_finding_in_a_file_the_static_gate_does_not_read_counts(self):
        findings = rg.trivy_fs_findings([str(self.root / "examples")], ["misconfig"], "trivy")
        dockerfile_ids = sorted({i for target, i in findings if target.endswith("Dockerfile")})
        self.assertTrue(dockerfile_ids, findings)
        self.assertEqual(self.run_gate(entry(dockerfile_ids[0], ["**/examples/Dockerfile"])), 0, self.output)

    def test_an_expired_entry_fails_even_while_it_matches(self):
        self.assertEqual(
            self.run_gate(entry("KSV-0012", ["**/examples/bad.yaml"], expired_at=TODAY - timedelta(days=1))), 1
        )
        self.assertIn("expired", self.output)

    def test_an_entry_with_no_statement_fails(self):
        self.assertEqual(self.run_gate(entry("KSV-0012", ["**/examples/bad.yaml"], statement="")), 1)
        self.assertIn("statement", self.output)

    def test_trivy_is_run_with_an_empty_ignore_file_and_an_empty_config(self):
        seen = {}

        def fake_run(cmd, **kwargs):
            seen["cmd"], seen["cwd"] = cmd, kwargs.get("cwd")
            ignore = Path(cmd[cmd.index("--ignorefile") + 1])
            seen["ignore_text"] = ignore.read_text(encoding="utf-8")
            return mock.Mock(returncode=0, stdout=json.dumps({"Results": []}), stderr="")

        with mock.patch.object(rg.subprocess, "run", fake_run):
            rg.trivy_fs_findings([str(self.root)], ["misconfig"], "trivy")
        self.assertEqual(seen["ignore_text"].strip(), "")
        self.assertIn("--scanners", seen["cmd"])
        self.assertIn("--config", seen["cmd"])


class MakefileTests(unittest.TestCase):
    def test_the_makefile_exposes_the_registry_check(self):
        makefile = (Path(__file__).resolve().parents[3] / "Makefile").read_text(encoding="utf-8")
        self.assertIn("\ngates-registry:", makefile)
        recipe = makefile.split("\ngates-registry:")[1].split("\n\n")[0]
        self.assertIn("registry_gate.py", recipe)


if __name__ == "__main__":
    unittest.main()
