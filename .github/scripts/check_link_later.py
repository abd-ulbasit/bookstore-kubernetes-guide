#!/usr/bin/env python3
"""Fail on a link-later marker whose chapter now exists.

A chapter that does not exist yet is named in plain text with
`<!-- link-later: 05.05 -->` beside it (docs/security-first-authoring.md,
section 3). Once the chapter lands, the reference must become a link and the
marker must go. This check finds the markers under the guide root and exits 1
for each one whose chapter file exists. A marker whose chapter is still
missing passes, and so does a guide with no markers.

Usage: check_link_later.py [GUIDE_ROOT]    (default: full-guide)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = re.compile(r"<!--\s*link-later:\s*([^>]*?)\s*-->", re.IGNORECASE)
CHAPTER = re.compile(r"\b(\d{2})\.(\d{2})\b")


def chapter_exists(root: Path, part: str, number: str) -> bool:
    """True if root has a chapter file NN-*/MM-*.md for the given numbers."""
    return any(root.glob(f"{part}-*/{number}-*.md"))


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else "full-guide")
    if not root.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 2
    stale = 0
    for path in sorted(root.rglob("*.md")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for marker in MARKER.finditer(line):
                for part, chapter in CHAPTER.findall(marker.group(1)):
                    if chapter_exists(root, part, chapter):
                        print(f"{path}:{number}: link-later {part}.{chapter} but the chapter exists; make it a link and delete the marker")
                        stale += 1
    if stale:
        print(f"{stale} link-later marker(s) point at a chapter that exists", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
