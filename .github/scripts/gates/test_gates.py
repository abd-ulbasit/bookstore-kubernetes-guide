#!/usr/bin/env python3
"""Unit tests for the security-first gate scripts.

Run from the repository root:

    python -m unittest discover -s .github/scripts/gates

Each gate section below is grouped by the script it covers. The tests use
temporary directories only and never touch the repository's chapters.
"""

from __future__ import annotations

import json
import tempfile
import textwrap
import unittest
from pathlib import Path

import extract_blocks as eb

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


if __name__ == "__main__":
    unittest.main()
