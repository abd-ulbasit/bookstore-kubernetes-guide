#!/usr/bin/env python3
"""G5, the registry half: every exception is registered, and every entry is alive.

Design section 5.4 keeps all exceptions in two files. This gate checks each in
both directions, and exits 1 if anything is out of step.

Namespaces above `restricted` (`security/namespace-exceptions.yaml`):
  * every entry has a namespace, a level (baseline or privileged), a reason,
    an upstream citation, a chapter that exists, and an `expires` date that is
    still ahead and no more than 12 months out;
  * every `pod-security.kubernetes.io/{enforce,audit,warn}` label set to
    baseline or privileged, in a chapter or an example tree, belongs to a
    registered namespace at that level;
  * every registered namespace is still labelled that way somewhere.

Scanner findings (`.trivyignore.yaml`, see scanner_registry.py):
  * every entry has an id, paths, a statement and a sound `expired_at`;
  * every entry still matches a finding. Trivy is run without the ignore file
    and the entry's id must appear at one of its paths. Misconfigurations are
    read the way the static gate reads them (chapter blocks, example files,
    rendered charts and overlays) and then from `trivy fs`; the other sections
    come from `trivy fs`;
  * no Trivy ignore file other than the registry exists, so no finding is
    suppressed outside it. (An inline `trivy:ignore` comment in a manifest the
    static gate reads is a failure there.)

Labels are found by reading, not by pattern alone: Namespace manifests (also
inside other objects, such as a Crossplane Composition), `kubectl label`
commands, Terraform namespace labels, and charts and overlays rendered the way
the static gate renders them. A label above restricted that none of these can
attach to a namespace is reported, never ignored. The gate also aborts (exit
2) if it finds no `restricted` label anywhere, because the guide's own
namespaces are restricted and a reader that sees none has stopped reading.

Exit codes: 0 in step. 1 a problem was found. 2 the gate could not trust itself:
a registry file is unreadable, the root is missing, the label reader is blind,
or a tool it needs (trivy, helm, kubectl) is missing or fails.

Usage:
    registry_gate.py [--root full-guide] [--also PATH ...] [--scan PATH ...]
                     [--namespace-registry FILE] [--scanner-registry FILE]
                     [--report OUT.json] [--today YYYY-MM-DD]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import extract_blocks as eb
import gate_render as gr
import scanner_registry as sr
import static_gate as sg

ControlError = sg.ControlError

DEFAULT_NAMESPACE_REGISTRY = Path("security/namespace-exceptions.yaml")
LABEL_KEY = "pod-security.kubernetes.io"
MODES = ("enforce", "audit", "warn")
ABOVE_RESTRICTED = ("baseline", "privileged")
LEVELS = {"restricted": 0, "baseline": 1, "privileged": 2}
SKIP_DIRS = frozenset({".git", "node_modules", ".terraform"})
PRUNE_DIRS = frozenset({".claude", "site"})  # worktree copies and the built site
MAX_FILE_BYTES = 2_000_000
IGNORE_FILE_NAMES = (".trivyignore", ".trivyignore.yml", ".trivyignore.yaml")
SEVERITIES = "LOW,MEDIUM,HIGH,CRITICAL"
SCANNER_OF = {
    "misconfigurations": "misconfig",
    "vulnerabilities": "vuln",
    "secrets": "secret",
    "licenses": "license",
}
TRIVY_SKIP = ("**/.terraform", "**/node_modules", "**/.git", ".claude", "site")

_NAMESPACE_NAME = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?")
_HIT = re.compile(
    rf"{re.escape(LABEL_KEY)}/(?P<mode>enforce|audit|warn)[\"'\]]*\s*[:=]+\s*[\"']?(?P<level>baseline|privileged)\b"
)
_TF_LABEL = re.compile(
    rf"[\"']{re.escape(LABEL_KEY)}/(?P<mode>enforce|audit|warn)[\"']\s*=\s*[\"'](?P<level>\w+)[\"']"
)
_TF_NAME = re.compile(r"\bname\s*=\s*\"(?P<name>[^\"]+)\"")
_KUBECTL_LABEL = re.compile(r"\bkubectl\b.*?\blabel\b(?P<rest>.*)")
_NS_RESOURCES = ("ns", "namespace", "namespaces")
_PLAIN_LABEL = re.compile(rf"^{re.escape(LABEL_KEY)}/(?P<mode>enforce|audit|warn)=(?P<level>[\w-]+)$")


@dataclass(frozen=True)
class LabelUse:
    namespace: str
    mode: str  # enforce, audit or warn
    level: str  # restricted, baseline or privileged
    where: str


@dataclass
class TreeScan:
    uses: list[LabelUse]
    unattached: list[str]  # messages for labels no reader could attach to a namespace


@dataclass(frozen=True)
class NamespaceEntry:
    namespace: str
    level: str
    problems: tuple[str, ...] = ()


@dataclass
class NamespaceRegistry:
    entries: list[NamespaceEntry] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    path: Path = DEFAULT_NAMESPACE_REGISTRY


# --- reading labels ----------------------------------------------------------


def labels_in_documents(docs, where: str) -> list[LabelUse]:
    """Return the Pod Security labels of every Namespace in parsed YAML documents.

    A Namespace nested inside another object (a Crossplane Composition, a
    ManifestWork) counts. `-version` labels are not levels and are skipped.
    """
    uses: list[LabelUse] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            meta = node.get("metadata")
            if node.get("kind") == "Namespace" and isinstance(meta, dict):
                name, labels = meta.get("name"), meta.get("labels")
                if isinstance(name, str) and isinstance(labels, dict):
                    for mode in MODES:
                        level = labels.get(f"{LABEL_KEY}/{mode}")
                        if isinstance(level, str) and level.strip():
                            uses.append(LabelUse(name, mode, level.strip(), where))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(docs)
    return uses


def _tokens(line: str) -> list[str]:
    import shlex

    try:
        return shlex.split(line, comments=False, posix=True)
    except ValueError:
        return line.split()


def labels_in_shell(text: str, where: str) -> list[LabelUse]:
    """Return the labels `kubectl label` commands in text put on a namespace."""
    uses: list[LabelUse] = []
    for line in re.sub(r"\\\n", " ", text).splitlines():
        stripped = line.strip().removeprefix("$").strip()
        if stripped.startswith("#"):
            continue
        found = _KUBECTL_LABEL.search(stripped)
        if not found:
            continue
        words = _tokens(found.group("rest"))
        namespace = None
        positional = [w for w in words if not w.startswith("-") and "=" not in w]
        for index, word in enumerate(positional):
            if word.lower() in _NS_RESOURCES and index + 1 < len(positional):
                namespace = positional[index + 1]
                break
            if word.lower().startswith(("ns/", "namespace/", "namespaces/")):
                namespace = word.split("/", 1)[1]
                break
        if namespace is None:
            continue
        for word in words:
            label = _PLAIN_LABEL.match(word)
            if label:
                uses.append(LabelUse(namespace, label.group("mode"), label.group("level"), where))
    return uses


def labels_in_terraform(text: str, where: str) -> list[LabelUse]:
    """Return the Pod Security labels in Terraform text, each under the nearest `name =` above it."""
    uses: list[LabelUse] = []
    name = None
    for line in text.splitlines():
        found = _TF_NAME.search(line)
        if found and not line.lstrip().startswith("#"):
            name = found.group("name")
        label = _TF_LABEL.search(line)
        if label and name:
            uses.append(LabelUse(name, label.group("mode"), label.group("level"), where))
    return uses


def hits_above_restricted(text: str) -> Counter:
    """Count every literal label set to baseline or privileged, ignoring comment lines."""
    hits: Counter = Counter()
    for line in text.splitlines():
        if line.lstrip().startswith(("#", "//")):
            continue
        for found in _HIT.finditer(line):
            hits[(found.group("mode"), found.group("level"))] += 1
    return hits


def _read_markdown(text: str, where: str) -> tuple[list[LabelUse], Counter]:
    uses: list[LabelUse] = []
    hits: Counter = Counter()
    for language, line, previous, body in eb.fences(text):
        if previous == eb.OUTPUT_MARKER:
            continue  # captured output, not something a reader applies
        here = f"{where}:{line}"
        hits += hits_above_restricted(body)
        if language in eb.YAML_LANGS:
            uses += labels_in_documents(eb.load_documents(body) or [], here)
            continue
        if language in ("hcl", "terraform", "tf"):
            uses += labels_in_terraform(body, here)
            continue
        uses += labels_in_shell(body, here)
        for piece in eb.heredocs(body)[0]:
            uses += labels_in_documents(eb.load_documents(piece) or [], here)
    return uses, hits


def _read_file(path: Path, text: str, where: str) -> tuple[list[LabelUse], Counter]:
    suffix = path.suffix.lower()
    if suffix == ".md":
        return _read_markdown(text, where)
    hits = hits_above_restricted(text)
    if suffix in (".yaml", ".yml"):
        return labels_in_documents(eb.load_documents(text) or [], where), hits
    if suffix == ".tf":
        return labels_in_terraform(text, where), hits
    uses = labels_in_shell(text, where)
    for piece in eb.heredocs(text)[0]:
        uses += labels_in_documents(eb.load_documents(piece) or [], where)
    return uses, hits


def _text_files(root: Path):
    """Yield the files under root that can hold a label: not Part 18, not a chart's raw templates."""
    for path in gr.walk(root):
        parts = path.relative_to(root).parts
        if re.match(r"18-", parts[0]) and len(parts) > 1 or gr.is_chart_template(path):
            continue
        yield path


def scan_labels(root: Path, work: Path, helm: str = "helm", kubectl: str = "kubectl") -> TreeScan:
    """Read every Pod Security label under root; render the charts and overlays there too."""
    root = Path(root)
    uses: list[LabelUse] = []
    unattached: list[str] = []
    for path in _text_files(root):
        try:
            if path.stat().st_size > MAX_FILE_BYTES:
                continue
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if LABEL_KEY not in text:
            continue
        where = path.as_posix()
        file_uses, hits = _read_file(path, text, where)
        uses += file_uses
        missing = hits - Counter((u.mode, u.level) for u in file_uses if u.level in ABOVE_RESTRICTED)
        if +missing:
            listed = ", ".join(f"{mode}={level}" for (mode, level), n in sorted(missing.items()) if n > 0)
            unattached.append(
                f"{where}: {sum(missing.values())} label(s) above restricted ({listed}) could not be attached "
                "to a namespace; write them in a Namespace manifest, a `kubectl label` command or a "
                "Terraform namespace so the registry can see them"
            )
    try:
        renders = []
        for chart in gr.find_charts(root):
            renders += [gr.render_chart(chart, v, helm) for v in (None, *gr.values_files(chart))]
        renders += [gr.render_overlay(o, kubectl) for o in gr.find_overlays(root)]
    except gr.RenderUnavailable as exc:
        raise ControlError(str(exc)) from exc
    for rendered in renders:
        where = f"{rendered.origin.as_posix()} [{rendered.label}]"
        if not rendered.ok:
            unattached.append(f"{where}: {rendered.failure_note}: {rendered.text}; its namespaces could not be read")
            continue
        uses += labels_in_documents(eb.load_documents(rendered.text) or [], where)
    return TreeScan(uses, unattached)


# --- the namespace registry ---------------------------------------------------


def load_namespace_registry(
    path: Path, today: date, guide_root: Path, missing_ok: bool = False
) -> NamespaceRegistry:
    """Read the namespace registry; judge each entry as of today."""
    registry = NamespaceRegistry(path=Path(path))
    data = sr.read_yaml(path, missing_ok)
    if data is None:
        return registry
    if not isinstance(data, dict) or set(data) - {"exceptions"}:
        registry.problems.append("the file must hold one key, `exceptions`, a list of entries")
        return registry
    items = data.get("exceptions")
    if items is None:
        return registry
    if not isinstance(items, list):
        registry.problems.append("`exceptions` must be a list of entries")
        return registry
    seen: set[str] = set()
    for number, item in enumerate(items, 1):
        if not isinstance(item, dict):
            registry.problems.append(f"entry {number} is not a mapping")
            continue
        problems: list[str] = []
        namespace = item.get("namespace")
        namespace = namespace.strip() if isinstance(namespace, str) else ""
        if not _NAMESPACE_NAME.fullmatch(namespace) or len(namespace) > 63:
            problems.append(f"namespace {namespace!r} is not a Kubernetes namespace name")
        level = item.get("level")
        if level == "restricted":
            problems.append("level restricted is the guide's baseline, not an exception")
        elif level not in ABOVE_RESTRICTED:
            problems.append(f"level {level!r} must be baseline or privileged")
        for key, advice in (
            ("reason", "say why the namespace needs more than restricted"),
            ("upstream", "cite the upstream document that demands it (or the Pod Security Standards page for a lab)"),
        ):
            value = item.get(key)
            if not (isinstance(value, str) and value.strip()):
                problems.append(f"{key} is missing: {advice}")
        chapter = item.get("chapter")
        if not (isinstance(chapter, str) and chapter.strip()):
            problems.append("chapter is missing: name the chapter that explains the exception")
        elif not (Path(guide_root) / chapter.strip()).is_file():
            problems.append(f"chapter {chapter!r} is not a file under {Path(guide_root).as_posix()}")
        reason = sr.date_problem(item.get("expires"), today, "expires")
        if reason:
            problems.append(reason)
        if namespace in seen:
            registry.problems.append(f"namespace {namespace} is registered twice")
        seen.add(namespace)
        registry.entries.append(NamespaceEntry(namespace, str(level), tuple(problems)))
    return registry


def found_namespaces(scan: TreeScan) -> dict[str, tuple[str, list[str]]]:
    """Map each namespace labelled above restricted to its most permissive level and where."""
    found: dict[str, tuple[str, list[str]]] = {}
    for use in scan.uses:
        if use.level not in ABOVE_RESTRICTED:
            continue
        level, wheres = found.get(use.namespace, ("baseline", []))
        found[use.namespace] = (use.level if LEVELS[use.level] > LEVELS[level] else level, wheres + [use.where])
    return found


def namespace_problems(scan: TreeScan, registry: NamespaceRegistry) -> list[str]:
    """Compare the labels found with the registry, both ways; return what is out of step."""
    problems = [f"{registry.path}: {p}" for p in registry.problems]
    for entry in registry.entries:
        problems += [f"{registry.path}: namespace {entry.namespace}: {p}" for p in entry.problems]
    found = found_namespaces(scan)
    registered = {e.namespace: e for e in reversed(registry.entries)}
    for namespace, (level, wheres) in sorted(found.items()):
        entry = registered.get(namespace)
        more = f" (and {len(wheres) - 1} more)" if len(wheres) > 1 else ""
        if entry is None:
            problems.append(
                f"namespace {namespace} is labelled {level} in {wheres[0]}{more} but is not registered in "
                f"{registry.path}; add an entry with its reason, upstream citation, chapter and expiry"
            )
        elif entry.level != level:
            problems.append(
                f"namespace {namespace} is registered as {entry.level} but {wheres[0]}{more} labels it {level}"
            )
    for entry in registry.entries:
        if entry.namespace not in found:
            problems.append(
                f"namespace {entry.namespace} is registered as {entry.level} but is no longer labelled above "
                f"restricted anywhere in the guide; remove the entry from {registry.path}"
            )
    return problems + scan.unattached


# --- the scanner registry -----------------------------------------------------


def trivy_fs_findings(paths, scanners, trivy: str = "trivy") -> list[tuple[str, str]]:
    """Run `trivy fs` without any ignore file; return (path, id) for every finding.

    An explicit empty ignore file and an empty config file keep a stray
    `.trivyignore` or `trivy.yaml` from hiding a finding. Each path is named
    as the caller wrote it, with Trivy's own relative target joined on.
    """
    findings: list[tuple[str, str]] = []
    with tempfile.TemporaryDirectory(prefix="registry-gate-") as tmp:
        empty = Path(tmp) / "empty.yaml"
        empty.write_text("", encoding="utf-8")
        for path in paths:
            cmd = [
                trivy, "fs", "--quiet", "--format", "json", "--scanners", ",".join(scanners),
                "--severity", SEVERITIES, "--ignorefile", str(empty), "--config", str(empty),
                *[f"--skip-dirs={d}" for d in TRIVY_SKIP], str(path),
            ]  # fmt: skip
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
            except OSError as exc:
                raise ControlError(f"cannot run trivy: {exc}") from exc
            if proc.returncode != 0:
                raise ControlError(f"trivy exited {proc.returncode}: {proc.stderr.strip()[:500]}")
            try:
                report = json.loads(proc.stdout)
            except json.JSONDecodeError as exc:
                raise ControlError(f"trivy printed no JSON: {exc}") from exc
            for result in report.get("Results") or []:
                target = sr.norm_path(f"{path}/{result['Target']}")
                for item in result.get("Misconfigurations") or []:
                    if item.get("Status") == "FAIL":
                        findings.append((target, item["ID"]))
                findings += [(target, v["VulnerabilityID"]) for v in result.get("Vulnerabilities") or []]
                findings += [(target, s["RuleID"]) for s in result.get("Secrets") or []]
                findings += [(target, lic["Name"]) for lic in result.get("Licenses") or []]
    return findings


def gate_view(root: Path, also: list[str], work: Path, helm: str, kubectl: str, trivy: str):
    """Return (path, id, rendered) for every misconfiguration the static gate sees without the registry."""
    (work / "render").mkdir(parents=True, exist_ok=True)
    blocks = eb.extract(root, work / "blocks")
    blocks += sg._also_blocks(also, work / "render", helm, kubectl)
    scans = sg.scan_files([Path(b.path) for b in blocks], trivy)
    guide_root = Path(root).as_posix()
    view = []
    for block in blocks:
        scan = sg.effective_scan(block, scans[Path(block.path)])
        target = sg.registry_target(block, guide_root)
        view += [(target, i, block.source in sg.RENDERED_SOURCES) for i in scan.failed]
    return view


def entry_matches(entry: sr.Entry, findings) -> bool:
    """True if one finding, (path, id, rendered), has the entry's id at one of its paths."""
    wanted = sr.normalise_id(entry.id)
    return any(
        sr.normalise_id(found_id) == wanted and any(sr.path_matches(p, target, within) for p in entry.paths)
        for target, found_id, within in findings
    )


def stale_entries(entries, gate_view, scan, trivy: str = "trivy") -> list[sr.Entry]:
    """Return the entries that no finding, read without the ignore file, still matches.

    `gate_view` is a list of (path, id, rendered), or a function that returns
    one; it is called only if a misconfiguration entry needs it. The remaining
    entries are tried against `trivy fs` over each `scan` path.
    """
    stale: list[sr.Entry] = []
    view: list | None = None
    fs_cache: dict[str, list] = {}
    for entry in entries:
        if not entry.id or not entry.paths:
            continue  # unsound; reported as such
        if entry.section == sr.MISCONFIGURATIONS:
            if view is None:
                view = gate_view() if callable(gate_view) else gate_view
            if entry_matches(entry, view):
                continue
        scanner = SCANNER_OF[entry.section]
        if scanner not in fs_cache:
            fs_cache[scanner] = [(t, i, False) for t, i in trivy_fs_findings(scan, [scanner], trivy)]
        if not entry_matches(entry, fs_cache[scanner]):
            stale.append(entry)
    return stale


def stray_ignore_files(scan_paths, registry_path: Path) -> list[str]:
    """Return a message for every Trivy ignore file other than the registry."""
    own = Path(registry_path).resolve()
    problems = []
    for root in scan_paths:
        for here, dirs, files in os.walk(root):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS | PRUNE_DIRS)
            for name in files:
                path = Path(here) / name
                if name in IGNORE_FILE_NAMES and path.resolve() != own:
                    problems.append(
                        f"{path.as_posix()}: a Trivy ignore file outside the registry; move the exception "
                        f"into {registry_path} with its statement and expiry"
                    )
    return problems


def scanner_problems(registry: sr.Registry, view, scan, trivy: str) -> list[str]:
    problems = [f"{registry.path}: {p}" for p in registry.problems]
    for entry in registry.entries:
        problems += [f"{registry.path}: {entry.section} {entry.id or '(no id)'}: {p}" for p in entry.problems]
    for entry in stale_entries(registry.entries, view, scan, trivy):
        problems.append(
            f"{registry.path}: {entry.section} {entry.id} at {', '.join(entry.paths)} matches no finding "
            "without the ignore file; remove the entry or correct its paths"
        )
    return problems


# --- the command line ---------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default="full-guide", type=Path, help="the guide: chapters and examples/")
    parser.add_argument("--also", action="extend", nargs="+", default=[], metavar="PATH", help="example trees the static gate reads")
    parser.add_argument("--scan", action="extend", nargs="+", default=[], metavar="PATH", help="trees `trivy fs` reads (default .)")
    parser.add_argument("--namespace-registry", type=Path, metavar="FILE")
    parser.add_argument("--scanner-registry", type=Path, metavar="FILE")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--today", help="YYYY-MM-DD, to repeat a run as of another day")
    parser.add_argument("--helm", default="helm")
    parser.add_argument("--kubectl", default="kubectl")
    parser.add_argument("--trivy", default="trivy")
    args = parser.parse_args(argv)
    try:
        today = date.fromisoformat(args.today) if args.today else date.today()
        return run(args, today)
    except (ControlError, sr.RegistryError, ValueError) as exc:
        print(f"registry gate aborted: {exc}", file=sys.stderr)
        return 2


def run(args: argparse.Namespace, today: date) -> int:
    if not args.root.is_dir():
        raise ControlError(f"--root {args.root} is not a directory")
    namespace_path = args.namespace_registry or DEFAULT_NAMESPACE_REGISTRY
    scanner_path = args.scanner_registry or sr.DEFAULT_PATH
    namespaces = load_namespace_registry(
        namespace_path, today, args.root, missing_ok=args.namespace_registry is None
    )
    scanner = sr.load(scanner_path, today, missing_ok=args.scanner_registry is None)
    scan_paths = args.scan or ["."]

    with tempfile.TemporaryDirectory(prefix="registry-gate-") as tmp:
        work = Path(tmp)
        scan = scan_labels(args.root, work / "labels", args.helm, args.kubectl)
        if not any(u.level == "restricted" for u in scan.uses):
            raise ControlError(
                f"found no `restricted` namespace label under {args.root}; the guide's own namespaces are "
                "restricted, so the label reader has stopped seeing them and a pass would mean nothing"
            )
        problems = namespace_problems(scan, namespaces)
        problems += scanner_problems(
            scanner,
            lambda: gate_view(args.root, args.also, work / "view", args.helm, args.kubectl, args.trivy),
            scan_paths,
            args.trivy,
        )
        problems += stray_ignore_files(scan_paths, scanner_path)

    for problem in problems:
        print(f"registry: {problem}")
    above = found_namespaces(scan)
    print(
        f"registry gate: {len(namespaces.entries)} namespace exception(s) against {len(above)} namespace(s) "
        f"labelled above restricted, {len(scanner.entries)} scanner exception(s); "
        + (f"{len(problems)} problem(s)" if problems else "in step")
    )
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(
                {
                    "problems": problems,
                    "namespaces": [
                        {"namespace": n, "level": level, "where": sorted(set(wheres))}
                        for n, (level, wheres) in sorted(above.items())
                    ],
                    "scanner_entries": len(scanner.entries),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
