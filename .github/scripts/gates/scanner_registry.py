#!/usr/bin/env python3
"""The scanner half of the exceptions registry: `.trivyignore.yaml`.

Design section 5.4 keeps every exception in one registry. A scanner finding
that the guide accepts is an entry in Trivy's `.trivyignore.yaml`, grouped by
section (`misconfigurations`, `vulnerabilities`, `secrets`, `licenses`):

    misconfigurations:
      - id: KSV-0017
        paths:
          - full-guide/examples/bookstore-platform/node-agent/**
        statement: why this finding is accepted, with an upstream citation
        expired_at: 2027-06-30

This module reads that file and judges each entry. The static gate uses it to
drop accepted findings; the registry gate uses it to prove every entry is
sound and still matches something. Trivy's own support for the file is
experimental and, in v0.76.1, never loads it unasked, so neither gate leaves
the enforcement to Trivy.

An entry is honoured only when it is sound: an id, at least one path, a
non-empty statement, and an `expired_at` date that is still in the future and
no more than 12 months out. An unsound entry grants nothing.
"""

from __future__ import annotations

import calendar
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from functools import lru_cache
from pathlib import Path

import yaml

SECTIONS = ("vulnerabilities", "misconfigurations", "secrets", "licenses")
MISCONFIGURATIONS = "misconfigurations"
MAX_MONTHS = 12
DEFAULT_PATH = Path(".trivyignore.yaml")


class RegistryError(Exception):
    """The registry file cannot be read at all; the caller must stop."""


def add_months(day: date, months: int) -> date:
    """Return day moved by whole calendar months, clamped to the month's last day."""
    index = day.year * 12 + (day.month - 1) + months
    year, month = divmod(index, 12)
    month += 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def as_date(value) -> date | None:
    """Return value as a date if it is one, or an ISO date string; else None."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        try:
            return date.fromisoformat(value.strip())
        except ValueError:
            return None
    return None


def date_problem(value, today: date, field_name: str = "expired_at") -> str | None:
    """Return why value is not an acceptable expiry date, or None if it is.

    The date must still be ahead of today (an entry ends on the day itself,
    as Trivy reads it) and no more than 12 months away.
    """
    if value is None or value == "":
        return f"{field_name} is missing: give the date the exception ends, such as 2027-06-30"
    when = as_date(value)
    if when is None:
        return f"{field_name} {value!r} is not a date (write it as YYYY-MM-DD)"
    if when <= today:
        return f"the entry expired on {when}: renew it with a new reason or remove it"
    limit = add_months(today, MAX_MONTHS)
    if when > limit:
        return f"{field_name} {when} is more than {MAX_MONTHS} months out (the latest allowed today is {limit})"
    return None


def normalise_id(value: str) -> str:
    """Return a check id without the `AVD-` prefix Trivy accepts in front of it."""
    text = str(value).strip()
    return text[4:] if text.upper().startswith("AVD-") else text


def norm_path(path: str) -> str:
    text = re.sub(r"/{2,}", "/", str(path).strip().replace("\\", "/"))
    while text.startswith("./"):
        text = text[2:]
    return text.rstrip("/") if len(text) > 1 else text


@lru_cache(maxsize=512)
def _glob(pattern: str) -> re.Pattern:
    """Translate a glob: `*` and `?` stay in one path segment, `**` crosses them."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out))


def path_matches(pattern: str, target: str, within: bool = False) -> bool:
    """True if the glob pattern covers target.

    A pattern covers the path it matches and everything below a directory it
    matches. With `within` the target is a rendered directory (a Helm chart or
    a Kustomize overlay) whose findings cannot be traced to one file, so a
    pattern that names a path inside the directory covers it too.
    """
    pat, tgt = norm_path(pattern), norm_path(target)
    rx = _glob(pat)
    if rx.fullmatch(tgt):
        return True
    parts = tgt.split("/")
    if any(rx.fullmatch("/".join(parts[:k])) for k in range(len(parts) - 1, 0, -1)):
        return True
    if within and tgt:
        segments = pat.split("/")
        return any(_glob("/".join(segments[:k])).fullmatch(tgt) for k in range(len(segments) - 1, 0, -1))
    return False


@dataclass(frozen=True)
class Entry:
    section: str
    id: str
    paths: tuple[str, ...]
    statement: str
    expired_at: date | None
    problems: tuple[str, ...] = ()

    @property
    def honoured(self) -> bool:
        return not self.problems


@dataclass
class Registry:
    entries: list[Entry] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)  # file-level: structure, unknown sections
    path: Path = DEFAULT_PATH

    def covered(self, ids, target: str, within: bool = False, section: str = MISCONFIGURATIONS) -> set[str]:
        """Return the ids that an honoured entry excepts for target."""
        out: set[str] = set()
        for entry in self.entries:
            if not entry.honoured or entry.section != section:
                continue
            if not any(path_matches(p, target, within) for p in entry.paths):
                continue
            out |= {i for i in ids if normalise_id(i) == normalise_id(entry.id)}
        return out


def read_yaml(path: Path, missing_ok: bool = False):
    """Return the parsed YAML of path; None for an empty file or a tolerated absence."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        if missing_ok:
            return None
        raise RegistryError(f"{path}: no such file") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise RegistryError(f"{path}: cannot read it: {exc}") from exc
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        reason = str(exc).splitlines()[0] if str(exc) else "invalid YAML"
        raise RegistryError(f"{path}: not valid YAML: {reason}") from exc


def _entry(section: str, item: dict, today: date) -> Entry:
    problems: list[str] = []
    ident = item.get("id")
    ident = ident.strip() if isinstance(ident, str) else ""
    if not ident:
        problems.append("id is missing")
    paths = item.get("paths")
    if not (isinstance(paths, list) and paths and all(isinstance(p, str) and p.strip() for p in paths)):
        problems.append("paths is missing or empty: name the files the exception covers")
        paths = []
    statement = item.get("statement")
    statement = statement.strip() if isinstance(statement, str) else ""
    if not statement:
        problems.append("statement is missing: say why the finding is accepted")
    when = item.get("expired_at")
    reason = date_problem(when, today)
    if reason:
        problems.append(reason)
    if "purls" in item:
        problems.append("purls are not supported here: name the files with paths")
    return Entry(section, ident, tuple(p.strip() for p in paths), statement, as_date(when), tuple(problems))


def load(path: Path, today: date, missing_ok: bool = False) -> Registry:
    """Read the registry at path; judge each entry as of today.

    A file that cannot be read or parsed raises RegistryError. A file with the
    wrong shape, or an unsound entry, is reported in `problems` instead, so a
    caller can list everything wrong at once.
    """
    registry = Registry(path=Path(path))
    data = read_yaml(path, missing_ok)
    if data is None:
        return registry
    if not isinstance(data, dict):
        registry.problems.append("the file must be a mapping of sections (misconfigurations, vulnerabilities, ...)")
        return registry
    for key, items in data.items():
        if key not in SECTIONS:
            registry.problems.append(f"unknown section {key!r}; the sections are {', '.join(SECTIONS)}")
            continue
        if items is None:
            continue
        if not isinstance(items, list):
            registry.problems.append(f"{key} must be a list of entries")
            continue
        for number, item in enumerate(items, 1):
            if not isinstance(item, dict):
                registry.problems.append(f"{key} entry {number} is not a mapping")
                continue
            registry.entries.append(_entry(key, item, today))
    return registry
