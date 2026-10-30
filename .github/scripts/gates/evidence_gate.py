#!/usr/bin/env python3
"""G7: the lab evidence check.

A lab chapter marks each block of captured output with
`<!-- gate: output -->` on the line above its fence. This gate confirms that
every line of every marked block appears verbatim in the lab's recorded
transcript, and that neither the transcript nor the blocks leak a public IP
address (v4 or v6), a home directory, an email address, a shell prompt that
names a user and host, or a cloud identifier (an AWS account ID or ARN, an
ECR registry or EC2 public host name, a GCP project in a registry path).

Matching rules for one block:

* Lines must appear in the transcript in the order the block gives them.
* Consecutive block lines must be consecutive transcript lines. To leave
  lines out, put a line equal to `# ...` where they were; the next block
  line may then match anywhere later in the transcript. A run of consecutive
  lines may match at any place in the transcript, not only its first one:
  kubectl prints the same table header again and again.
* Blank lines and trailing whitespace do not matter.
* A block needs at least one line that is not `# ...`.

Any HTML comment that starts `<!-- gate:` (any case, any spacing) outside a
code fence must be exactly `<!-- gate: output -->` or
`<!-- gate: insecure-on-purpose -->`. A misspelt marker would otherwise bind
nothing and leave fabricated output unchecked.

Exit codes: 0 all output is in the transcript and nothing leaks, 1 a line is
missing, a block is empty, a marker is misspelt or something leaks, 2 the
gate had nothing to check (no marked blocks, or a missing or empty
transcript), which must not read as a pass.

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

OUTPUT_MARKER = eb.OUTPUT_MARKER
KNOWN_GATE_COMMENTS = frozenset({OUTPUT_MARKER, eb.MARKER})
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
_GATE_COMMENT = re.compile(r"<!--\s*gate\s*:", re.IGNORECASE)
_IPV6 = re.compile(r"(?<![\w:.])[0-9A-Fa-f:]{3,}(?![\w:])")
_ECR = re.compile(r"\b\d{12}\.dkr\.ecr(?:-fips)?\.[a-z0-9-]+\.amazonaws\.com(?:\.cn)?\b")
_EC2_HOST = re.compile(r"\bec2-(?:\d{1,3}-){3}\d{1,3}\.[a-z0-9.-]*amazonaws\.com(?:\.cn)?\b")
_GCR = re.compile(r"(?<![\w.-])(?:[a-z]+\.)?gcr\.io/(?P<project>[a-z][a-z0-9.:-]{3,}[a-z0-9])/")
_PKG_DEV = re.compile(r"(?<![\w.-])[a-z0-9-]+-docker\.pkg\.dev/(?P<project>[a-z][a-z0-9-]{3,}[a-z0-9])/")
_PROMPT = re.compile(
    r"(?<![\w.@-])(?P<user>[A-Za-z_][A-Za-z0-9._-]*)@[A-Za-z0-9][A-Za-z0-9._-]*:[^\s$#]*[$#](?=\s|$)"
)
_BRACKET_PROMPT = re.compile(r"\[(?P<user>[A-Za-z_][A-Za-z0-9._-]*)@[A-Za-z0-9][A-Za-z0-9._-]*\s[^\]]*\][$#]")

# Registry projects owned by Google or the Kubernetes project: public images, not a reader's own project.
_PUBLIC_REGISTRY_PROJECTS = frozenset(
    {
        "google-containers", "google_containers", "distroless", "kaniko-project", "cloud-builders",
        "google-samples", "gke-release", "k8s-artifacts-prod", "cloud-marketplace", "tekton-releases",
        "knative-releases", "flame-public", "ml-pipeline", "cadvisor", "k8s-minikube",
        "istio-release", "istio-testing", "kubebuilder", "cloudsql-docker", "gcp-runtimes",
    }
)  # fmt: skip
_PUBLIC_REGISTRY_PREFIXES = ("k8s-staging-", "k8s-infra-", "google-")
_PROMPT_USERS = _CONTAINER_USERS | {"root"}


def bad_gate_comments(md: str) -> list[tuple[int, str]]:
    """Return (line, text) for each gate comment outside a fence that is not a known marker."""
    ranges = eb.fence_line_ranges(md)
    found = []
    for number, line in enumerate(md.split("\n"), 1):
        if any(first <= number <= last for first, last in ranges):
            continue
        if _GATE_COMMENT.search(line) and line.strip() not in KNOWN_GATE_COMMENTS:
            found.append((number, line.strip()))
    return found


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


def _find_run(source: list[str], run: list[str], start: int) -> int | None:
    """Return the first index at or after start where run appears consecutively."""
    for i in range(start, len(source) - len(run) + 1):
        if source[i : i + len(run)] == run:
            return i
    return None


def _report_run(source: list[str], run: list[str], pos: int, missing: list[str]) -> int:
    """Walk a run that has no consecutive match, collecting the lines that are missing."""
    anchored = False
    for line in run:
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
    return pos


def missing_lines(block: str, transcript: str) -> list[str]:
    """Return the block lines not found verbatim, in order, in the transcript.

    A line equal to `# ...` is an elision: it is never looked up, and it lets
    the next line match anywhere later. Without one, each line must directly
    follow the previous match, so lines cannot be dropped unannounced.

    The block splits at its elisions into runs of consecutive lines. Each run
    is matched at the first place it appears whole, so a first line that
    also occurs earlier in the transcript (a repeated table header) cannot
    claim the match and make the rest of the run look invented.
    """
    source = _lines(transcript)
    runs: list[list[str]] = [[]]
    for line in _lines(block):
        if line.strip() == ELISION:
            runs.append([])
        else:
            runs[-1].append(line)
    pos = 0
    missing: list[str] = []
    for run in runs:
        if not run:
            continue
        at = _find_run(source, run, pos)
        if at is not None:
            pos = at + len(run)
        else:
            pos = _report_run(source, run, pos, missing)
    return missing


def _ipv4(text: str):
    """Parse a dotted quad, leading zeros included (008.008.008.008 is 8.8.8.8)."""
    octets = [int(part) for part in text.split(".")]
    if any(o > 255 for o in octets):
        raise ValueError(text)
    return ipaddress.IPv4Address(".".join(str(o) for o in octets))


def _public_ipv6(token: str):
    for candidate in (token, token[:-1] if token.endswith(":") else ""):
        if candidate.count(":") < 2:
            continue
        try:
            ip = ipaddress.IPv6Address(candidate)
        except ValueError:
            continue
        return candidate if ip.is_global else None
    return None


def _public_project(project: str) -> bool:
    return project in _PUBLIC_REGISTRY_PROJECTS or project.startswith(_PUBLIC_REGISTRY_PREFIXES)


def leaks(text: str) -> list[str]:
    """Return what in text must not be committed, in order of appearance.

    Flags public and tailnet IPv4 addresses (leading zeros included), public
    IPv6 addresses, `/Users/<name>` and `/home/<name>` paths (container users
    such as `nonroot` are fine), email addresses, shell prompts that name a
    user and host (`root` and container users are fine), AWS account IDs in
    ARNs, ECR registry hosts and EC2 public host names, access key IDs, and a
    project in a gcr.io or pkg.dev path (Google's own public projects are
    fine). Private, loopback and link-local addresses, which kind labs print
    constantly, are allowed.
    """
    found: list[tuple[int, str]] = []
    for m in _IPV4.finditer(text):
        try:
            ip = _ipv4(m.group(1))
        except ValueError:
            continue
        if ip.is_global or ip in _CGNAT:
            found.append((m.start(), m.group(1)))
    for m in _IPV6.finditer(text):
        public = _public_ipv6(m.group(0))
        if public:
            found.append((m.start(), public))
    for pattern in (_GCR, _PKG_DEV):
        for m in pattern.finditer(text):
            if not _public_project(m.group("project")):
                found.append((m.start(), m.group(0).rstrip("/")))
    for pattern in (_PROMPT, _BRACKET_PROMPT):
        for m in pattern.finditer(text):
            if m.group("user") not in _PROMPT_USERS:
                found.append((m.start(), m.group(0)))
    for m in _LINUX_HOME.finditer(text):
        if m.group(1) not in _CONTAINER_USERS:
            found.append((m.start(), m.group(0)))
    for pattern in (_MAC_HOME, _WIN_HOME, _EMAIL, _AWS_ARN, _AWS_KEY, _ECR, _EC2_HOST):
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
    for number, text in bad_gate_comments(chapter):
        problems += 1
        print(f"{args.chapter}:{number}: not a gate marker the tools read; spell it exactly: {text}")
    for line, body in blocks:
        if not [ln for ln in _lines(body) if ln.strip() != ELISION]:
            problems += 1
            print(f"{args.chapter}:{line}: output block has no output lines, only blanks or `# ...`")
            continue
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
