#!/usr/bin/env python3
"""Turn gate reports into a per-chapter summary and the job's verdict.

The whole guide is held to the security gates. Parts 00 to 15 and the example
trees all pass them, so a chapter that fails any gate fails the job. Two files
tune that rule, and each lists one path per line, relative to full-guide/, for
example `01-core-workloads/01-pods.md`. A directory (or an example tree) names
everything under it. `#` starts a comment.

* The enforced file names what the gates must have read. An entry that no
  report mentions fails the job (it was renamed, or never checked), so a Part
  cannot drop out of the gates without anyone noticing. A chapter with no
  manifest, such as the appendix, stays off this list, because no report would
  ever mention it.
* The report-only file names the outlines whose labs have not run yet, Parts
  16 and 17. A failure there is listed in the summary and does not fail the
  job. Every other chapter that fails a gate fails the job, listed or not.
* A gate that exited 2 could not trust itself, so it always fails the job.
  So does a gate that exited 1 while no report row explains the failure.

Reports are the JSON files `static_gate.py` and `admission_gate.py` write
with `--report`. A gate is named `NAME:KIND:REPORT:EXIT`, where KIND is
`static` or `admission` and EXIT is the gate's own exit code.

Exit codes: 0 no chapter outside the report-only list failed, 1 such a
chapter failed, an enforced entry was never read, or a gate failed without a
reason in its report, 2 the inputs cannot be trusted (a missing report, a
listed path that does not exist).
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

GUIDE_ROOT = "full-guide"

STATIC_FAILING = frozenset({"fail", "stale-marker"})
ADMISSION_FAILING = frozenset({"violation", "error", "unparseable"})


class InputError(Exception):
    """The reports or the enforced list cannot be trusted."""


@dataclass
class Gate:
    name: str
    kind: str
    exit_code: int
    rows: list[dict]


@dataclass
class Outcome:
    failing: dict[str, dict[str, list[str]]] = field(default_factory=dict)
    seen: set[str] = field(default_factory=set)
    unexplained: list[str] = field(default_factory=list)
    aborted: list[str] = field(default_factory=list)


def normalise(chapter: str) -> str:
    """Name a row's chapter relative to full-guide/, example trees included."""
    prefix = GUIDE_ROOT + "/"
    return chapter[len(prefix):] if chapter.startswith(prefix) else chapter


def covers(entry: str, chapter: str) -> bool:
    """True if an enforced entry names the chapter or a directory above it."""
    entry = entry.rstrip("/")
    return chapter == entry or chapter.startswith((entry + "/", entry + " "))


def row_fails(kind: str, row: dict) -> bool:
    if not row.get("in_scope", True):
        return False
    failing = STATIC_FAILING if kind == "static" else ADMISSION_FAILING
    unread_pod_template = bool(row.get("pod_template")) and not row.get("allowed")
    return row.get("status") in failing or unread_pod_template


def parse_gate(spec: str) -> Gate:
    parts = spec.split(":", 3)
    if len(parts) != 4 or parts[1] not in ("static", "admission") or not parts[3].isdigit():
        raise InputError(f"--gate wants NAME:static|admission:REPORT:EXIT, got {spec!r}")
    name, kind, report, code = parts
    path = Path(report)
    if not path.is_file():
        raise InputError(f"{name}: report {report} does not exist, so the gate left nothing to read")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        rows = data["blocks"]
    except (ValueError, KeyError, TypeError) as exc:
        raise InputError(f"{name}: report {report} is not a gate report ({exc})") from exc
    return Gate(name, kind, int(code), rows)


def read_entries(path: Path, root: Path, what: str) -> list[str]:
    """Read a list file of paths under root; a missing file or path means the inputs cannot be trusted."""
    if not path.is_file():
        raise InputError(f"the {what} list {path} does not exist")
    entries = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if not (root / line).exists():
            raise InputError(f"{path}:{number}: {line} is not under {root}/, so it can never be checked")
        entries.append(line)
    return entries


def collect(gates: list[Gate]) -> Outcome:
    out = Outcome()
    for gate in gates:
        attributed = False
        for row in gate.rows:
            chapter = normalise(row["chapter"])
            out.seen.add(chapter)
            if row_fails(gate.kind, row):
                attributed = True
                where = f"line {row['line']}" if row.get("line") else "whole file"
                detail = ", ".join(row.get("ids") or []) or row.get("status", "")
                out.failing.setdefault(chapter, {}).setdefault(gate.name, []).append(f"{where}: {detail}")
        if gate.exit_code == 2:
            out.aborted.append(gate.name)
        elif gate.exit_code == 1 and not attributed:
            out.unexplained.append(gate.name)
        elif gate.exit_code not in (0, 1, 2):
            out.aborted.append(gate.name)
    return out


def verdict(
    outcome: Outcome, enforced: list[str], report_only: list[str]
) -> tuple[int, list[str], list[str], list[str]]:
    """Return the exit code, the blocking failures, the unchecked entries and the notes.

    A failing chapter blocks unless a report-only entry covers it.
    """
    broken = [c for c in outcome.failing if not any(covers(r, c) for r in report_only)]
    unchecked = [e for e in enforced if not any(covers(e, c) for c in outcome.seen)]
    notes = [f"gate {n} aborted (exit 2): it could not trust itself" for n in outcome.aborted]
    notes += [f"gate {n} failed but its report names no failing block" for n in outcome.unexplained]
    code = 1 if broken or unchecked or notes else 0
    return code, sorted(broken), unchecked, notes


def render(
    outcome: Outcome,
    enforced: list[str],
    report_only_entries: list[str],
    code: int,
    broken: list[str],
    unchecked: list[str],
    notes: list[str],
) -> str:
    lines = ["## Security gates, per chapter", ""]
    report_only = sorted(c for c in outcome.failing if c not in broken)
    lines.append(
        f"{len(outcome.seen)} chapters and example trees were read; "
        f"{len(outcome.failing)} fail at least one gate; "
        f"{len(enforced)} entries must be read; "
        f"{len(report_only_entries)} are report only."
    )
    lines.append("")
    lines += ["### Must be read", "", "| Entry | Result |", "|---|---|"]
    for entry in enforced:
        bad = [c for c in broken if covers(entry, c)]
        if entry in unchecked:
            result = "NOT CHECKED (no report mentions it)"
        elif bad:
            result = "FAIL: " + ", ".join(sorted(bad))
        else:
            result = "pass"
        lines.append(f"| `{entry}` | {result} |")
    if not enforced:
        lines.append("| (none) | |")
    lines.append("")
    for title, chapters in (("Failing", broken), ("Failing, report only (outline, lab not run)", report_only)):
        lines += [f"### {title}", ""]
        if not chapters:
            lines += ["None.", ""]
            continue
        for chapter in chapters:
            lines.append(f"- `{chapter}`")
            for gate, items in sorted(outcome.failing[chapter].items()):
                shown = "; ".join(items[:3]) + (f" (+{len(items) - 3} more)" if len(items) > 3 else "")
                lines.append(f"  - {gate}: {shown}")
        lines.append("")
    if notes:
        lines += ["### Gate problems", ""] + [f"- {n}" for n in notes] + [""]
    lines.append("Verdict: " + ("PASS" if code == 0 else "FAIL"))
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--gate", action="append", default=[], metavar="NAME:KIND:REPORT:EXIT")
    parser.add_argument("--enforced", required=True, type=Path)
    parser.add_argument("--report-only", type=Path, help="outlines whose failures are listed and do not fail the job")
    parser.add_argument("--root", default=Path(GUIDE_ROOT), type=Path)
    parser.add_argument("--out", type=Path, help="write the Markdown summary here as well")
    args = parser.parse_args(argv)
    try:
        if not args.gate:
            raise InputError("no --gate given, so there is nothing to summarise")
        gates = [parse_gate(spec) for spec in args.gate]
        enforced = read_entries(args.enforced, args.root, "enforced")
        report_only = read_entries(args.report_only, args.root, "report-only") if args.report_only else []
    except InputError as exc:
        print(f"chapter summary aborted: {exc}", file=sys.stderr)
        return 2
    outcome = collect(gates)
    code, broken, unchecked, notes = verdict(outcome, enforced, report_only)
    text = render(outcome, enforced, report_only, code, broken, unchecked, notes)
    print(text)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    return code


if __name__ == "__main__":
    sys.exit(main())
