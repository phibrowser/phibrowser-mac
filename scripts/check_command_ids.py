#!/usr/bin/env python3
"""Verify CommandWrapper's IDC_* raw values against Chromium's command ids.

Run once per Chromium major-version port: the numeric ids in
Sources/UserInterface/Preferences/Shortcuts/Shortcuts.swift are transcribed by
hand from chrome/app/chrome_command_ids.h, and upstream renumbers or removes
commands between majors. A stale value silently binds a shortcut or a menu tag
to the wrong command.

    scripts/check_command_ids.py path/to/chromium/src/chrome/app/chrome_command_ids.h
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_SOURCE = REPO_ROOT / "Sources/UserInterface/Preferences/Shortcuts/Shortcuts.swift"

HEADER_DEFINE = re.compile(r"^#define\s+(IDC_\w+)\s+(\d+)\b")
SWIFT_CASE = re.compile(r"^\s*case\s+(IDC_\w+)\s*=\s*(\d+)")


def parse(path: Path, pattern: re.Pattern[str]) -> dict[str, int]:
    return {
        m.group(1): int(m.group(2))
        for m in (pattern.match(line) for line in path.read_text().splitlines())
        if m
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "header",
        type=Path,
        help="path to chrome/app/chrome_command_ids.h in the Chromium fork checkout",
    )
    args = parser.parse_args()

    if not args.header.is_file():
        print(f"error: header not found: {args.header}", file=sys.stderr)
        return 2

    upstream = parse(args.header, HEADER_DEFINE)
    declared = parse(SWIFT_SOURCE, SWIFT_CASE)

    failures = []
    for name, value in declared.items():
        if name not in upstream:
            failures.append(f"{name} = {value}: no numeric #define in the header")
        elif upstream[name] != value:
            failures.append(f"{name} = {value}: header says {upstream[name]}")

    for failure in failures:
        print(f"MISMATCH: {failure}", file=sys.stderr)
    print(f"checked {len(declared)} ids against {args.header}, {len(failures)} mismatched")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
