#!/usr/bin/env python3
"""G7: the lab evidence check.

A lab chapter marks each block of captured output with
`<!-- gate: output -->` on the line above its fence. This gate confirms that
every line of every marked block appears verbatim in the lab's recorded
transcript, and that neither the transcript nor the blocks leak a public IP
address, a home directory, an email address or an AWS identifier.

Matching rules for one block:

* Lines must appear in the transcript in the order the block gives them.
* Consecutive block lines must be consecutive transcript lines. To leave
  lines out, put a line equal to `# ...` where they were; the next block
  line may then match anywhere later in the transcript.
* Blank lines and trailing whitespace do not matter.

Exit codes: 0 all output is in the transcript and nothing leaks, 1 a line is
missing or something leaks, 2 the gate had nothing to check (no marked
blocks, or a missing or empty transcript), which must not read as a pass.

Usage:
    evidence_gate.py --chapter CHAPTER.md --transcript TRANSCRIPT [--transcript ...]
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from pathlib import Path

import extract_blocks as eb

OUTPUT_MARKER = "<!-- gate: output -->"
ELISION = "# ..."

# Home directories that belong to a container image rather than a person.
_CONTAINER_USERS = frozenset(
    {"nonroot", "node", "app", "appuser", "user", "nobody", "www-data", "nginx", "postgres"}
)
_CGNAT = ipaddress.ip_network("100.64.0.0/10")  # shared space, used by tailnets

_IPV4 = re.compile(r"(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(?!\w|\.\d)")
_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
_MAC_HOME = re.compile(r"(?<![\w.])/Users/[^/\s:'\"]+")
_LINUX_HOME = re.compile(r"(?<![\w.])/home/([A-Za-z0-9._-]+)")
_WIN_HOME = re.compile(r"[A-Za-z]:\\Users\\[^\\\s]+")
_AWS_ARN = re.compile(r"arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:\d{12}:")
_AWS_KEY = re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")


def output_block_lines(md: str) -> list[tuple[int, str]]:
    """Return (line, body) for each fence right after the output marker."""
    return [
        (line, body.rstrip("\n"))
        for _, line, previous, body in eb.fences(md)
        if previous == OUTPUT_MARKER
    ]


def output_blocks(md: str) -> list[str]:
    """Return the body of each fence right after `<!-- gate: output -->`."""
    return [body for _, body in output_block_lines(md)]


def _lines(text: str) -> list[str]:
    """Non-blank lines without trailing whitespace; CRLF is normalised."""
    return [ln.rstrip() for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n") if ln.strip()]


def missing_lines(block: str, transcript: str) -> list[str]:
    """Return the block lines not found verbatim, in order, in the transcript.

    A line equal to `# ...` is an elision: it is never looked up, and it lets
    the next line match anywhere later. Without one, each line must directly
    follow the previous match, so lines cannot be dropped unannounced.
    """
    source = _lines(transcript)
    pos = 0
    anchored = False
    missing = []
    for line in _lines(block):
        if line.strip() == ELISION:
            anchored = False
            continue
        if anchored and pos < len(source) and source[pos] == line:
            pos += 1
            continue
        if not anchored:
            found = next((i for i in range(pos, len(source)) if source[i] == line), None)
            if found is not None:
                pos = found + 1
                anchored = True
                continue
        missing.append(line)
        anchored = False
    return missing


def leaks(text: str) -> list[str]:
    """Return what in text must not be committed, in order of appearance.

    Flags public and tailnet IPv4 addresses, `/Users/<name>` and
    `/home/<name>` paths (container users such as `nonroot` are fine), email
    addresses, and AWS account IDs in ARNs and access key IDs. Private,
    loopback and link-local addresses, which kind labs print constantly, are
    allowed.
    """
    found: list[tuple[int, str]] = []
    for m in _IPV4.finditer(text):
        try:
            ip = ipaddress.IPv4Address(m.group(1))
        except ValueError:
            continue
        if ip.is_global or ip in _CGNAT:
            found.append((m.start(), m.group(1)))
    for m in _LINUX_HOME.finditer(text):
        if m.group(1) not in _CONTAINER_USERS:
            found.append((m.start(), m.group(0)))
    for pattern in (_MAC_HOME, _WIN_HOME, _EMAIL, _AWS_ARN, _AWS_KEY):
        found.extend((m.start(), m.group(0)) for m in pattern.finditer(text))
    return list(dict.fromkeys(item for _, item in sorted(found)))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--chapter", required=True, type=Path)
    parser.add_argument("--transcript", required=True, action="append", type=Path)
    args = parser.parse_args(argv)

    try:
        chapter = args.chapter.read_text(encoding="utf-8")
        transcript = "\n".join(t.read_text(encoding="utf-8") for t in args.transcript)
    except OSError as exc:
        print(f"evidence gate aborted: {exc}", file=sys.stderr)
        return 2
    blocks = output_block_lines(chapter)
    if not blocks:
        print(f"evidence gate aborted: no `{OUTPUT_MARKER}` blocks in {args.chapter}", file=sys.stderr)
        return 2
    if not _lines(transcript):
        print("evidence gate aborted: the transcript is empty", file=sys.stderr)
        return 2

    problems = 0
    for line, body in blocks:
        for text in missing_lines(body, transcript):
            problems += 1
            print(f"{args.chapter}:{line}: not in the transcript, in order: {text}")
    for source, text in (("transcript", transcript), ("chapter output", "\n".join(b for _, b in blocks))):
        for item in leaks(text):
            problems += 1
            print(f"leak in {source}: {item}")
    if problems:
        print(f"evidence gate: {problems} problem(s). Add `# ...` where lines were left out.")
        return 1
    print(f"evidence gate: {len(blocks)} output block(s) found verbatim in the transcript; no leaks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
