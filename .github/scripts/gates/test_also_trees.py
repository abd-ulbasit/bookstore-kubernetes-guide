#!/usr/bin/env python3
"""Tests for how the static gate reads example trees (`--also`).

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

Covers what `--also` counts as unparseable (only YAML that really fails to
parse) and the Helm chart and Kustomize overlay rendering that replaces raw
chart templates. Temporary directories only; the repository's chapters and
examples are never touched.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import textwrap
import unittest
from pathlib import Path

import extract_blocks as eb
import gate_render as gr
import static_gate as sg
from test_gates import FIXTURES, HARDENED, HAVE_TRIVY, StaticRunner, fixture, write

HAVE_HELM = shutil.which("helm") is not None
HAVE_KUBECTL = shutil.which("kubectl") is not None

CHART_YAML = "apiVersion: v2\nname: web\nversion: 0.1.0\n"
IMAGE = "registry.k8s.io/pause:3.10"
TEMPLATE = HARDENED.replace(f"image: {IMAGE}", "image: {{ .Values.image }}")
VIOLATING_TEMPLATE = fixture("violating-deployment.yaml").replace("replicas: 1", "replicas: {{ .Values.replicas }}")
ALERT = textwrap.dedent(
    """\
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: demo
    spec:
      groups:
        - name: g
          rules:
            - alert: Down
              expr: up == 0
              annotations:
                summary: "{{ $labels.job }} is down"
    """
)


def make_chart(root: Path, rel: str = "helm/web", template: str = TEMPLATE, **extra: str) -> Path:
    """Write a small chart; extra maps a file name under the chart to its text."""
    chart = root / rel
    write(chart, "Chart.yaml", CHART_YAML)
    write(chart, "values.yaml", f"image: {IMAGE}\nreplicas: 1\n")
    write(chart, "templates/deploy.yaml", template)
    for name, text in extra.items():
        write(chart, name.replace("__", "/"), text)
    return chart


def make_overlays(root: Path) -> None:
    """A base, a component and two overlays, as the examples lay them out."""
    write(root, "kustomize/base/kustomization.yaml", "resources:\n  - deploy.yaml\n")
    write(root, "kustomize/base/deploy.yaml", HARDENED)
    write(
        root, "kustomize/components/extra/kustomization.yaml",
        "apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nlabels:\n  - pairs:\n      tier: extra\n",
    )  # fmt: skip
    for name in ("dev", "prod"):
        write(
            root, f"kustomize/overlays/{name}/kustomization.yaml",
            f"resources:\n  - ../../base\ncomponents:\n  - ../../components/extra\nnamePrefix: {name}-\n",
        )  # fmt: skip


class TempTree(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.tree = self.tmp / "tree"
        self.tree.mkdir()

    def also(self, *paths, **kwargs):
        return sg._also_blocks([str(p) for p in paths] or [str(self.tree)], self.work, **kwargs)

    def labels(self, blocks):
        return sorted(b.chapter.replace(str(self.tree), "T") for b in blocks)


class ClassifyTemplateSyntaxTests(unittest.TestCase):
    def test_template_syntax_is_unparseable_by_default(self):
        self.assertEqual(eb.classify(ALERT, False)[0], eb.UNPARSEABLE)

    def test_braces_in_a_string_parse_when_template_syntax_is_not_the_test(self):
        klass, kinds = eb.classify(ALERT, False, reject_templates=False)
        self.assertEqual((klass, kinds), (eb.APPLYABLE, ["PrometheusRule"]))

    def test_yaml_that_really_fails_stays_unparseable_either_way(self):
        broken = "apiVersion: v1\nkind: Pod\nmetadata: [unclosed\n"
        self.assertEqual(eb.classify(broken, False, reject_templates=False)[0], eb.UNPARSEABLE)

    def test_an_unquoted_template_value_really_fails_to_parse(self):
        body = "apiVersion: v1\nkind: Pod\nmetadata:\n  name: x\nspec:\n  hostname: {{ .Values.h }}\n"
        self.assertEqual(eb.classify(body, False, reject_templates=False)[0], eb.UNPARSEABLE)

    def test_parse_error_names_the_line(self):
        self.assertIsNone(eb.parse_error(ALERT))
        message = eb.parse_error("kind: Pod\nmetadata: [unclosed\n")
        self.assertRegex(message, r"line \d+")


class YamlJudgmentTests(TempTree):
    def test_braces_inside_a_string_are_a_manifest(self):
        write(self.tree, "rules.yaml", ALERT)
        (block,) = self.also()
        self.assertEqual((block.klass, block.kinds), (eb.APPLYABLE, ["PrometheusRule"]))

    def test_yaml_that_really_fails_is_unparseable_and_says_why(self):
        write(self.tree, "ok.yaml", ALERT)
        write(self.tree, "broken.yaml", "apiVersion: v1\nkind: Pod\nmetadata: [unclosed\n")
        blocks = {Path(b.chapter).name: b for b in self.also()}
        self.assertEqual(blocks["ok.yaml"].klass, eb.APPLYABLE)
        self.assertEqual(blocks["broken.yaml"].klass, eb.UNPARSEABLE)
        self.assertRegex(blocks["broken.yaml"].note, r"^yaml-error: .*line \d+")

    def test_an_unrendered_template_outside_a_chart_is_still_unparseable(self):
        write(self.tree, "loose.yaml", "apiVersion: v1\nkind: Pod\nmetadata:\n  name: {{ .Values.n }}\n")
        (block,) = self.also()
        self.assertEqual(block.klass, eb.UNPARSEABLE)
        self.assertEqual(sg.verdict(block, set(), set())[0], sg.FAIL)


@unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
class ChartRenderingTests(TempTree):
    def test_raw_templates_are_skipped_and_the_rendered_chart_is_scanned(self):
        make_chart(self.tree)
        write(self.tree, "plain.yaml", ALERT)
        blocks = self.also()
        self.assertEqual(self.labels(blocks), ["T/helm/web [helm template]", "T/plain.yaml"])
        self.assertFalse(any("templates" in b.chapter for b in blocks))
        rendered = next(b for b in blocks if b.source == "helm")
        self.assertEqual((rendered.klass, rendered.kinds), (eb.APPLYABLE, ["Deployment"]))
        self.assertIn(f"image: {IMAGE}", Path(rendered.path).read_text(encoding="utf-8"))

    def test_each_values_file_is_rendered_over_the_defaults(self):
        make_chart(
            self.tree,
            **{"values-dev.yaml": "image: busybox:dev\n", "values-prod.yaml": "image: busybox:prod\n"},
        )  # fmt: skip
        blocks = self.also()
        self.assertEqual(
            self.labels(blocks),
            [
                "T/helm/web [helm template -f values-dev.yaml]",
                "T/helm/web [helm template -f values-prod.yaml]",
                "T/helm/web [helm template]",
            ],
        )
        text = {b.chapter.rsplit("[", 1)[1]: Path(b.path).read_text(encoding="utf-8") for b in blocks}
        self.assertIn("image: busybox:prod", text["helm template -f values-prod.yaml]"])
        self.assertIn(f"image: {IMAGE}", text["helm template]"])

    def test_chart_inputs_are_not_manifests(self):
        make_chart(self.tree, **{"values-x.yaml": "kind: web\nimage: busybox\n"})
        write(self.tree, "helm/web/values.yaml", f"kind: web\nimage: {IMAGE}\nreplicas: 1\n")
        self.assertFalse(any(b.chapter.endswith(("values.yaml", "values-x.yaml", "Chart.yaml")) for b in self.also()))

    def test_a_chart_that_cannot_render_is_a_visible_failure(self):
        make_chart(self.tree, template=TEMPLATE.replace("{{ .Values.image }}", '{{ required "image is required" .Values.nope }}'))
        (block,) = self.also()
        self.assertEqual(block.klass, eb.UNPARSEABLE)
        self.assertTrue(block.note.startswith("helm-template-failed:"), block.note)
        self.assertIn("image is required", block.note)
        self.assertEqual(sg.verdict(block, set(), set())[0], sg.FAIL)

    def test_a_chart_that_renders_nothing_is_a_visible_failure(self):
        make_chart(self.tree, template="{{- if .Values.off }}\nkind: Pod\n{{- end }}\n")
        (block,) = self.also()
        self.assertEqual(block.klass, eb.UNPARSEABLE)
        self.assertEqual(block.note, "helm-template-rendered-nothing")

    def test_a_path_holding_only_raw_templates_is_refused(self):
        chart = make_chart(self.tree)
        with self.assertRaises(sg.ControlError) as caught:
            self.also(chart / "templates")
        self.assertIn("raw Helm templates", str(caught.exception))

    def test_a_chart_directory_given_directly_is_rendered(self):
        chart = make_chart(self.tree)
        self.assertEqual(self.labels(self.also(chart)), ["T/helm/web [helm template]"])

    def test_a_missing_helm_aborts_instead_of_skipping_the_chart(self):
        make_chart(self.tree)
        with self.assertRaises(sg.ControlError) as caught:
            self.also(helm="no-such-helm-binary")
        self.assertIn("helm", str(caught.exception))

    def test_a_tree_without_a_chart_does_not_need_helm(self):
        write(self.tree, "rules.yaml", ALERT)
        self.assertEqual(len(self.also(helm="no-such-helm-binary")), 1)


@unittest.skipUnless(HAVE_KUBECTL, "kubectl is not on PATH")
class OverlayRenderingTests(TempTree):
    def test_each_overlay_is_rendered_but_not_bases_or_components(self):
        make_overlays(self.tree)
        blocks = self.also()
        self.assertEqual(
            self.labels([b for b in blocks if b.source == "kustomize"]),
            ["T/kustomize/overlays/dev [kustomize build]", "T/kustomize/overlays/prod [kustomize build]"],
        )
        dev = next(b for b in blocks if b.chapter.endswith("overlays/dev [kustomize build]"))
        self.assertIn("name: dev-gate-control-hardened", Path(dev.path).read_text(encoding="utf-8"))
        # The plain files are still scanned as they are.
        self.assertIn("T/kustomize/base/deploy.yaml", self.labels(blocks))

    def test_an_overlay_that_cannot_build_is_a_visible_failure(self):
        write(self.tree, "overlay/kustomization.yaml", "resources:\n  - missing.yaml\n")
        (block,) = self.also()
        self.assertEqual(block.klass, eb.UNPARSEABLE)
        self.assertTrue(block.note.startswith("kustomize-build-failed:"), block.note)

    def test_a_missing_kubectl_aborts_instead_of_skipping_the_overlay(self):
        make_overlays(self.tree)
        with self.assertRaises(sg.ControlError) as caught:
            self.also(kubectl="no-such-kubectl-binary")
        self.assertIn("kubectl", str(caught.exception))


class RenderHelperTests(TempTree):
    def test_chart_template_detection_follows_the_chart_root(self):
        chart = make_chart(self.tree)
        write(self.tree, "helm/other/templates/loose.yaml", "kind: Pod\n")  # no Chart.yaml above it
        self.assertTrue(gr.is_chart_template(chart / "templates" / "deploy.yaml"))
        self.assertFalse(gr.is_chart_template(chart / "values.yaml"))
        self.assertFalse(gr.is_chart_template(self.tree / "helm/other/templates/loose.yaml"))

    def test_nested_charts_are_not_listed_twice(self):
        chart = make_chart(self.tree)
        write(chart, "charts/sub/Chart.yaml", "apiVersion: v2\nname: sub\nversion: 0.1.0\n")
        self.assertEqual(gr.find_charts(self.tree), [chart])

    def test_values_files_are_the_dash_named_ones_in_order(self):
        chart = make_chart(self.tree, **{"values-b.yaml": "a: 1\n", "values-a.yml": "a: 1\n", "other.yaml": "a: 1\n"})
        self.assertEqual([p.name for p in gr.values_files(chart)], ["values-a.yml", "values-b.yaml"])


@unittest.skipUnless(HAVE_TRIVY, "trivy is not on PATH")
class RenderedTreeGateTests(StaticRunner, unittest.TestCase):
    def tree(self):
        tree = self.tmp / "examples"
        tree.mkdir(exist_ok=True)
        return tree

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_clean_chart_and_a_string_with_braces_leave_nothing_unparseable(self):
        make_chart(self.tree())
        write(self.tree(), "rules.yaml", ALERT)
        rc, report = self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(self.tree()))
        self.assertEqual(rc, 0, self.output)
        self.assertEqual([b["chapter"] for b in report["blocks"] if b["klass"] == "unparseable"], [])
        self.assertIn("helm template]", " ".join(b["chapter"] for b in report["blocks"]))

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_violating_chart_fails_as_a_rendered_chart_not_as_unparseable(self):
        make_chart(self.tree(), template=VIOLATING_TEMPLATE)
        rc, report = self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(self.tree()))
        self.assertEqual(rc, 1, self.output)
        (bad,) = [b for b in report["blocks"] if b["status"] == "fail"]
        self.assertTrue(bad["chapter"].endswith("[helm template]"))
        self.assertTrue(set(sg.CORE) <= set(bad["ids"]), bad["ids"])
        self.assertIn("helm template]", self.output)

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_chart_that_cannot_render_fails_the_run_and_says_why(self):
        make_chart(self.tree(), template="kind: Pod\n{{ required \"image is required\" .Values.nope }}\n")
        rc, report = self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(self.tree()))
        self.assertEqual(rc, 1, self.output)
        self.assertIn("helm-template-failed", self.output)
        self.assertIn("image is required", self.output)

    @unittest.skipUnless(HAVE_HELM, "helm is not on PATH")
    def test_a_tree_of_only_raw_templates_exits_two(self):
        chart = make_chart(self.tree())
        rc, _ = self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(chart / "templates"))
        self.assertEqual(rc, 2)
        self.assertIn("raw Helm templates", self.output)

    @unittest.skipUnless(HAVE_KUBECTL, "kubectl is not on PATH")
    def test_a_violating_overlay_fails_as_a_rendered_overlay(self):
        write(self.tree(), "base/kustomization.yaml", "resources:\n  - deploy.yaml\n")
        write(self.tree(), "base/deploy.yaml", fixture("violating-deployment.yaml"))
        write(self.tree(), "overlay/kustomization.yaml", "resources:\n  - ../base\nnamePrefix: x-\n")
        rc, report = self.run_gate(self.manifest([("a.md", HARDENED)]), "--also", str(self.tree()))
        self.assertEqual(rc, 1, self.output)
        failed = [b["chapter"] for b in report["blocks"] if b["status"] == "fail"]
        self.assertTrue(any(c.endswith("overlay [kustomize build]") for c in failed), failed)


class RenderersRequiredTests(unittest.TestCase):
    """With REQUIRE_TRIVY=1 (make gates-test) a missing Helm or kubectl is a failure, not a skip."""

    def test_the_renderers_are_installed_when_required(self):
        if os.environ.get("REQUIRE_TRIVY") == "1":
            self.assertTrue(HAVE_HELM, "helm is not on PATH, so the chart-rendering tests were skipped")
            self.assertTrue(HAVE_KUBECTL, "kubectl is not on PATH, so the overlay-rendering tests were skipped")

    def test_the_makefile_checks_for_them_before_the_unit_tests(self):
        makefile = (Path(__file__).resolve().parents[3] / "Makefile").read_text(encoding="utf-8")
        recipe = makefile.split("\ngates-test:")[1].split("\n\n")[0]
        self.assertIn("command -v $(HELM)", recipe)
        self.assertIn("command -v $(KUBECTL)", recipe)


class SourceTests(unittest.TestCase):
    def test_the_control_fixtures_are_still_where_the_gate_expects_them(self):
        for name in ("violating-deployment.yaml", "hardened-deployment.yaml"):
            self.assertTrue((FIXTURES / name).is_file())


if __name__ == "__main__":
    unittest.main()
