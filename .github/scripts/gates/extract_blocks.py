#!/usr/bin/env python3
"""G1: extract the Kubernetes manifests that chapter prose tells a reader to apply.

Every fenced ```yaml (or ```yml) block that holds a top-level `kind:` in a
chapter under the guide root becomes one `Block`. The body is written to its
own file so the later gates can scan, dry-run and report on it, and the list
of blocks goes to `manifest.json` next to those files.

Classes
-------
applyable    parses, has no marker. Must satisfy the baseline.
insecure     preceded by `<!-- gate: insecure-on-purpose -->`. Must still fail.
unparseable  Helm template syntax, YAML that does not parse, or a placeholder
             such as `kind: <Kind>`. Nothing can judge it, so no gate may
             count it as a pass.

A block with no top-level `kind:` is a fragment and is not gated. Chapters
under `examples/` and Part 18 are skipped: examples have their own checks and
Part 18 is unpublished scratch work.

Usage:
    extract_blocks.py --root full-guide --out DIR
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path

import yaml

MARKER = "<!-- gate: insecure-on-purpose -->"
BANNER_PREFIX = "# INSECURE ON PURPOSE:"

APPLYABLE = "applyable"
INSECURE = "insecure"
UNPARSEABLE = "unparseable"

YAML_LANGS = {"yaml", "yml"}

_FENCE = re.compile(r"^(?P<indent>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_TOP_KIND = re.compile(r"^kind:[ \t]*(?P<kind>[^\s#][^\s#]*)", re.MULTILINE)
_TEMPLATE = re.compile(r"\{\{|\{%")
_KIND_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")  # `<Kind>` is a skeleton, not a kind
_EXCLUDED_PART = re.compile(r"^18-")


@dataclass(frozen=True)
class Block:
    chapter: str  # path under the root, for example "01-core-workloads/01-pods.md"
    index: int  # 1-based position among all yaml fences in the chapter
    line: int  # 1-based line of the opening fence
    klass: str  # applyable, insecure or unparseable
    kinds: list[str]  # the `kind` of each document, in order
    path: str  # where the block body was written

    @classmethod
    def from_dict(cls, data: dict) -> "Block":
        return cls(**data)


def top_level_kinds(body: str) -> list[str]:
    """Return each column-zero `kind:` value, so nested `kind:` keys are ignored."""
    return [m.group("kind").strip("'\"") for m in _TOP_KIND.finditer(body)]


def classify(body: str, marked: bool) -> tuple[str, list[str]]:
    """Return (class, kinds) for one block body.

    Template syntax and YAML errors come first: a block that cannot be parsed
    cannot be judged, marked or not.
    """
    if _TEMPLATE.search(body):
        return UNPARSEABLE, top_level_kinds(body)
    try:
        docs = list(yaml.safe_load_all(body))
    except yaml.YAMLError:
        return UNPARSEABLE, top_level_kinds(body)
    kinds = [
        str(doc["kind"])
        for doc in docs
        if isinstance(doc, dict) and isinstance(doc.get("kind"), str)
    ]
    if any(not _KIND_NAME.match(kind) for kind in kinds):
        return UNPARSEABLE, kinds
    return (INSECURE if marked else APPLYABLE), kinds


def _info_language(info: str) -> str:
    words = info.strip().split()
    return words[0].strip("{}.").lower() if words else ""


def _dedent(lines: list[str], indent: str) -> list[str]:
    """Remove the fence's own indentation from each body line, no more."""
    width = len(indent.expandtabs(4))
    out = []
    for line in lines:
        expanded = line.expandtabs(4)
        strip = min(width, len(expanded) - len(expanded.lstrip(" ")))
        out.append(expanded[strip:])
    return out


def _marked(lines: list[str], fence_at: int) -> bool:
    """True if the nearest non-blank line above the fence is exactly the marker."""
    for j in range(fence_at - 1, -1, -1):
        if lines[j].strip():
            return lines[j].strip() == MARKER
    return False


def yaml_fences(text: str):
    """Yield (index, line, marked, body) for every yaml fence in a Markdown file.

    Every fence kind is tracked, so a yaml fence nested inside a longer fence
    of another language is never mistaken for a chapter manifest.
    """
    lines = text.split("\n")
    index = 0
    i = 0
    while i < len(lines):
        opening = _FENCE.match(lines[i])
        if not opening:
            i += 1
            continue
        char = opening.group("fence")[0]
        length = len(opening.group("fence"))
        language = _info_language(opening.group("info"))
        start = i
        j = i + 1
        while j < len(lines):
            closing = _FENCE.match(lines[j])
            if (
                closing
                and closing.group("fence")[0] == char
                and len(closing.group("fence")) >= length
                and not closing.group("info").strip()
            ):
                break
            j += 1
        if language in YAML_LANGS:
            index += 1
            body = "\n".join(_dedent(lines[start + 1 : j], opening.group("indent"))) + "\n"
            yield index, start + 1, _marked(lines, start), body
        i = j + 1


def chapter_files(root: Path):
    """Yield the Markdown chapters to gate, skipping examples/ and Part 18."""
    for path in sorted(root.rglob("*.md")):
        parts = path.relative_to(root).parts
        if "examples" in parts[:-1] or _EXCLUDED_PART.match(parts[0]):
            continue
        yield path


def extract(root: Path, out: Path) -> list[Block]:
    """Write one file per gated block plus manifest.json; return the blocks."""
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    blocks: list[Block] = []
    for path in chapter_files(root):
        chapter = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        for index, line, marked, body in yaml_fences(text):
            if not top_level_kinds(body):
                continue
            klass, kinds = classify(body, marked)
            name = f"{chapter.replace('/', '__')}__b{index:02d}.yaml"
            (out / name).write_text(body, encoding="utf-8")
            blocks.append(Block(chapter, index, line, klass, kinds, str(out / name)))
    manifest = [asdict(b) for b in blocks]
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return blocks


def load_manifest(path: Path) -> list[Block]:
    return [Block.from_dict(d) for d in json.loads(Path(path).read_text(encoding="utf-8"))]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", required=True, type=Path, help="guide root, e.g. full-guide")
    parser.add_argument("--out", required=True, type=Path, help="directory for block files")
    args = parser.parse_args(argv)
    if not args.root.is_dir():
        print(f"error: {args.root} is not a directory", file=sys.stderr)
        return 2
    blocks = extract(args.root, args.out)
    counts = Counter(b.klass for b in blocks)
    chapters = len({b.chapter for b in blocks})
    summary = ", ".join(f"{counts[k]} {k}" for k in (APPLYABLE, INSECURE, UNPARSEABLE))
    print(f"{len(blocks)} blocks in {chapters} chapters: {summary}")
    print(f"manifest: {args.out / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
