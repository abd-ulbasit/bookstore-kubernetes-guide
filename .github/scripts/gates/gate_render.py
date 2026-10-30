#!/usr/bin/env python3
"""Render the Helm charts and Kustomize overlays under an example tree.

A file under a chart's `templates/` is Go-template text, not YAML, until Helm
renders it, so a gate cannot judge it as it stands. The gates scan what the
chart renders to instead: the chart with its default values, and once more
with each `values-*.yaml` beside it. Likewise a Kustomize overlay is judged as
the manifest set `kubectl kustomize` builds from it, not as the patches that
describe it.

Which Kustomize directories count as overlays: those with a `kustomization`
file that no other kustomization in the tree pulls in as a resource, base or
component, and that are not themselves a `Component`. Bases and components
are covered through the overlays that use them.

A missing tool raises RenderUnavailable: skipping a chart because Helm is
absent would let it pass unread. A chart or overlay that fails to render is
returned with ok=False so the caller can report it as a failure.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import yaml

KUSTOMIZATION_FILES = ("kustomization.yaml", "kustomization.yml", "Kustomization")
SKIP_DIRS = frozenset({".git", "node_modules", ".terraform"})
TIMEOUT_SECONDS = 180
_VALUES = re.compile(r"values-.+\.ya?ml")


class RenderUnavailable(Exception):
    """A rendering tool is missing, so the tree cannot be read as it is."""


@dataclass(frozen=True)
class Rendered:
    origin: Path  # the chart or overlay directory
    tool: str  # "helm" or "kustomize"
    label: str  # what was run, for display: "helm template -f values-prod.yaml"
    ok: bool
    text: str  # the rendered manifests, or the error when ok is False

    @property
    def failure_note(self) -> str:
        return {"helm": "helm-template-failed", "kustomize": "kustomize-build-failed"}[self.tool]

    @property
    def empty_note(self) -> str:
        return {"helm": "helm-template-rendered-nothing", "kustomize": "kustomize-build-rendered-nothing"}[self.tool]


def walk(root: Path):
    """Yield every file under root, skipping VCS, dependency and Terraform cache directories."""
    for path in sorted(Path(root).rglob("*")):
        if path.is_file() and not SKIP_DIRS & set(path.relative_to(root).parts[:-1]):
            yield path


def is_chart_template(path: Path) -> bool:
    """True if path sits under the `templates/` directory of a Helm chart."""
    path = Path(path).absolute()
    for parent in path.parents:
        if (parent / "Chart.yaml").is_file():
            relative = path.relative_to(parent)
            if relative.parts and relative.parts[0] == "templates":
                return True
    return False


def is_chart_input(path: Path) -> bool:
    """True for a chart's own metadata and values files, which are inputs, not manifests."""
    path = Path(path)
    if path.name in ("Chart.yaml", "Chart.lock"):
        return True
    return bool(re.fullmatch(r"values(-.+)?\.ya?ml", path.name)) and (path.parent / "Chart.yaml").is_file()


def find_charts(root: Path) -> list[Path]:
    """Return the chart directories at or under root, leaving out charts nested in another chart."""
    root = Path(root)
    found = {p.parent for p in walk(root) if p.name == "Chart.yaml"}
    if (root / "Chart.yaml").is_file():
        found.add(root)
    return sorted(c for c in found if not any(o != c and o in c.parents for o in found))


def values_files(chart: Path) -> list[Path]:
    """Return the chart's `values-*.yaml` files, in name order."""
    return sorted(p for p in Path(chart).iterdir() if p.is_file() and _VALUES.fullmatch(p.name))


def _last_line(text: str) -> str:
    """Return the error lines of a tool's output on one line, or its last line."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    errors = [ln for ln in lines if ln.lower().startswith("error")]
    return " ".join(errors or lines[-1:] or ["no output"])[:300]


def _run(cmd: list[str], tool: str, what: str) -> tuple[bool, str]:
    if shutil.which(cmd[0]) is None:
        raise RenderUnavailable(
            f"{cmd[0]} not found, so {what} cannot be rendered; "
            "skipping it would let it pass unread (install it, or pass --helm / --kubectl)"
        )
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired:
        return False, f"timed out after {TIMEOUT_SECONDS}s"
    except OSError as exc:
        raise RenderUnavailable(f"cannot run {cmd[0]}: {exc}") from exc
    if proc.returncode != 0:
        return False, _last_line(proc.stderr or proc.stdout)
    return True, proc.stdout


def render_chart(chart: Path, values: Path | None = None, helm: str = "helm") -> Rendered:
    """Run `helm template` on chart, over its defaults and optionally one values file."""
    release = re.sub(r"[^a-z0-9-]+", "-", Path(chart).name.lower()).strip("-")[:50] or "release"
    cmd = [helm, "template", release, str(chart)] + (["-f", str(values)] if values else [])
    label = "helm template" + (f" -f {Path(values).name}" if values else "")
    ok, text = _run(cmd, "helm", f"the chart {chart}")
    return Rendered(Path(chart), "helm", label, ok, text)


def find_overlays(root: Path) -> list[Path]:
    """Return the Kustomize overlays at or under root: roots that are not components."""
    root = Path(root)
    dirs = {p.parent for p in walk(root) if p.name in KUSTOMIZATION_FILES and not is_chart_template(p)}
    pulled_in: set[Path] = set()
    components: set[Path] = set()
    for directory in dirs:
        for name in KUSTOMIZATION_FILES:
            file = directory / name
            if not file.is_file():
                continue
            try:
                data = yaml.safe_load(file.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, yaml.YAMLError):
                break  # unreadable: left a root, so the build reports it
            if not isinstance(data, dict):
                break
            if data.get("kind") == "Component":
                components.add(directory)
            for key in ("resources", "bases", "components"):
                for ref in data.get(key) or []:
                    if isinstance(ref, str) and (directory / ref).is_dir():
                        pulled_in.add((directory / ref).resolve())
            break
    return sorted(d for d in dirs if d not in components and d.resolve() not in pulled_in)


def render_overlay(overlay: Path, kubectl: str = "kubectl") -> Rendered:
    """Run `kubectl kustomize` on an overlay directory."""
    ok, text = _run([kubectl, "kustomize", str(overlay)], "kustomize", f"the overlay {overlay}")
    return Rendered(Path(overlay), "kustomize", "kustomize build", ok, text)
