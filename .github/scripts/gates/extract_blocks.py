#!/usr/bin/env python3
"""G1: extract the Kubernetes manifests that chapter prose tells a reader to apply.

Every fenced ```yaml (or ```yml) block that holds a manifest, in a chapter
under the guide root, becomes one `Block`. A manifest is a column-zero
`kind:` line, or a parsed document that is a mapping with `apiVersion` and
`kind`, so flow-style, JSON and quoted-key manifests count too. Manifests a
reader applies from other fences are extracted as well: the body of each
shell heredoc (`kubectl apply -f - <<EOF`) and a fence that is a manifest as
a whole (a ```json fence). Each body is written to its own file so the later
gates can scan, dry-run and report on it, and the list of blocks goes to
`manifest.json` next to those files.

Classes
-------
applyable    parses, has no marker. Must satisfy the baseline.
insecure     preceded by `<!-- gate: insecure-on-purpose -->`. Must still fail.
unparseable  Helm template syntax, YAML that does not parse, or a placeholder
             such as `kind: <Kind>`. Nothing can judge it, so no gate may
             count it as a pass.

A block that holds no manifest is a fragment and is not gated. A fence of
another language (shell, text, json) that still shows a column-zero `kind:`
outside every extracted heredoc is a manifest nobody gated, so it becomes an
`unparseable` block and fails. Fences that show Markdown, and fences under
`<!-- gate: output -->` (captured output), are exempt from that rule.
Chapters under `examples/` and Part 18 are skipped: examples have their own
checks and Part 18 is unpublished scratch work.

Exit codes: 0 blocks were extracted, 2 the root is missing or no chapter
holds a manifest, which means the extractor stopped seeing the guide's
manifests and must not read as a pass.

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
OUTPUT_MARKER = "<!-- gate: output -->"
BANNER_PREFIX = "# INSECURE ON PURPOSE:"

APPLYABLE = "applyable"
INSECURE = "insecure"
UNPARSEABLE = "unparseable"

YAML_LANGS = {"yaml", "yml"}
MARKDOWN_LANGS = {"markdown", "md"}  # a fence that shows Markdown is documentation

# Where a block body came from.
YAML_FENCE, HEREDOC, WHOLE_FENCE, UNEXTRACTED = "yaml", "heredoc", "fence", "unextracted"

_FENCE = re.compile(r"^(?P<indent>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_TOP_KIND = re.compile(r"^kind:[ \t]*(?P<kind>[^\s#][^\s#]*)", re.MULTILINE)
_HEREDOC = re.compile(
    r"<<(?!<)(?P<dash>-?)[ \t]*"
    r"(?:\\?(?P<bare>[A-Za-z_][A-Za-z0-9_]*)|'(?P<sq>[^'\n]+)'|\"(?P<dq>[^\"\n]+)\")"
)
_TEMPLATE = re.compile(r"\{\{|\{%")
_KIND_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")  # `<Kind>` is a skeleton, not a kind
_EXCLUDED_PART = re.compile(r"^18-")


@dataclass(frozen=True)
class Block:
    chapter: str  # path under the root, for example "01-core-workloads/01-pods.md"
    index: int  # 1-based position among the chapter's blocks of the same source
    line: int  # 1-based line of the opening fence
    klass: str  # applyable, insecure or unparseable
    kinds: list[str]  # the `kind` of each document, in order
    path: str  # where the block body was written
    source: str = YAML_FENCE  # yaml fence, heredoc, whole fence or unextracted
    note: str = ""  # why an unparseable block is one, when it is not template syntax

    @classmethod
    def from_dict(cls, data: dict) -> "Block":
        return cls(**data)


def top_level_kinds(body: str) -> list[str]:
    """Return each column-zero `kind:` value, so nested `kind:` keys are ignored."""
    return [m.group("kind").strip("'\"") for m in _TOP_KIND.finditer(body)]


def load_documents(body: str):
    """Parse every YAML document in body; return None if it does not parse."""
    try:
        return list(yaml.safe_load_all(body))
    except (yaml.YAMLError, ValueError, RecursionError):
        return None


def is_parsed_manifest(body: str) -> bool:
    """True if a parsed document is a mapping with a string `kind` and an `apiVersion`."""
    return any(
        isinstance(doc, dict) and isinstance(doc.get("kind"), str) and "apiVersion" in doc
        for doc in load_documents(body) or []
    )


def is_manifest(body: str) -> bool:
    """True if body holds a manifest, however it is written.

    A column-zero `kind:` counts even when the document cannot be parsed, so
    a broken block is reported as unparseable instead of skipped.
    """
    return bool(top_level_kinds(body)) or is_parsed_manifest(body)


def classify(body: str, marked: bool) -> tuple[str, list[str]]:
    """Return (class, kinds) for one block body.

    Template syntax and YAML errors come first: a block that cannot be parsed
    cannot be judged, marked or not.
    """
    if _TEMPLATE.search(body):
        return UNPARSEABLE, top_level_kinds(body)
    docs = load_documents(body)
    if docs is None:
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


def _previous_line(lines: list[str], fence_at: int) -> str:
    """Return the nearest non-blank line above the fence, stripped, or ''."""
    for j in range(fence_at - 1, -1, -1):
        if lines[j].strip():
            return lines[j].strip()
    return ""


def _fence_spans(lines: list[str]):
    """Yield (opening index, closing index, opening match) for every fence.

    The closing index is len(lines) for a fence that is never closed.
    """
    i = 0
    while i < len(lines):
        opening = _FENCE.match(lines[i])
        if not opening:
            i += 1
            continue
        char = opening.group("fence")[0]
        length = len(opening.group("fence"))
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
        yield i, j, opening
        i = j + 1


def fences(text: str):
    """Yield (language, line, previous, body) for every fenced block.

    `line` is the 1-based line of the opening fence and `previous` the
    nearest non-blank line above it, where the gate markers live. Every fence
    kind is tracked, so a yaml fence nested inside a longer fence of another
    language is never mistaken for a chapter manifest.
    """
    lines = text.split("\n")
    for start, end, opening in _fence_spans(lines):
        body = "\n".join(_dedent(lines[start + 1 : end], opening.group("indent"))) + "\n"
        yield _info_language(opening.group("info")), start + 1, _previous_line(lines, start), body


def fence_line_ranges(text: str) -> list[tuple[int, int]]:
    """Return the 1-based (first, last) line of each fence, fence lines included."""
    lines = text.split("\n")
    return [(start + 1, min(end + 1, len(lines))) for start, end, _ in _fence_spans(lines)]


def heredocs(body: str) -> tuple[list[str], str]:
    """Split a shell fence into its heredoc bodies and everything else.

    Handles `<<EOF`, `<<-EOF` (leading tabs stripped), and quoted or escaped
    delimiters. A heredoc that is never closed runs to the end of the fence.
    """
    lines = body.split("\n")
    bodies: list[str] = []
    rest: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        rest.append(line)
        i += 1
        for m in _HEREDOC.finditer(line):
            delimiter = m.group("bare") or m.group("sq") or m.group("dq")
            strip_tabs = m.group("dash") == "-"
            collected: list[str] = []
            while i < len(lines):
                current = lines[i].lstrip("\t") if strip_tabs else lines[i]
                i += 1
                if current.strip() == delimiter:
                    break
                collected.append(current)
            bodies.append("\n".join(collected) + "\n")
    return bodies, "\n".join(rest)


def yaml_fences(text: str):
    """Yield (index, line, marked, body) for every yaml fence in a Markdown file."""
    index = 0
    for language, line, previous, body in fences(text):
        if language in YAML_LANGS:
            index += 1
            yield index, line, previous == MARKER, body


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

    def emit(chapter, name, index, line, source, body, klass, kinds, note=""):
        (out / name).write_text(body, encoding="utf-8")
        blocks.append(Block(chapter, index, line, klass, kinds, str(out / name), source, note))

    for path in chapter_files(root):
        chapter = path.relative_to(root).as_posix()
        stem = chapter.replace("/", "__")
        text = path.read_text(encoding="utf-8")
        yaml_n = heredoc_n = fence_n = lost_n = 0
        for language, line, previous, body in fences(text):
            marked = previous == MARKER
            if language in YAML_LANGS:
                yaml_n += 1
                if is_manifest(body):
                    klass, kinds = classify(body, marked)
                    emit(chapter, f"{stem}__b{yaml_n:02d}.yaml", yaml_n, line, YAML_FENCE, body, klass, kinds)
                continue
            if language in MARKDOWN_LANGS:
                continue
            bodies, rest = heredocs(body)
            for piece in bodies:
                if is_manifest(piece):
                    heredoc_n += 1
                    klass, kinds = classify(piece, marked)
                    name = f"{stem}__h{heredoc_n:02d}.yaml"
                    emit(chapter, name, heredoc_n, line, HEREDOC, piece, klass, kinds)
            captured = previous == OUTPUT_MARKER  # shown output, not something to apply
            if not bodies and not captured and is_parsed_manifest(body):
                fence_n += 1
                klass, kinds = classify(body, marked)
                emit(chapter, f"{stem}__f{fence_n:02d}.yaml", fence_n, line, WHOLE_FENCE, body, klass, kinds)
            elif not captured and top_level_kinds(rest):
                lost_n += 1
                emit(
                    chapter, f"{stem}__u{lost_n:02d}.txt", lost_n, line, UNEXTRACTED, body,
                    UNPARSEABLE, top_level_kinds(rest), "unextracted-manifest",
                )  # fmt: skip
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
    if not blocks:
        print(
            f"error: no chapter under {args.root} holds a manifest, so there is nothing to "
            "check (did the fence format change?)",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
