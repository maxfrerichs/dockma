#!/usr/bin/env python3
"""Prints the CHANGELOG.md section of one version, as GitHub release notes.

Usage: python3 -I scripts/release-notes.py <version> [CHANGELOG.md]

A version's section starts at its `## <version> – <date>` heading (an en
dash) and ends at the next `## ` heading. Exits non-zero when the section is
missing or empty, so a release can't go out without notes.
"""

import re
import sys


def section(changelog: str, version: str) -> str:
    heading = re.compile(rf"^## {re.escape(version)} – \d{{4}}-\d{{2}}-\d{{2}}\s*$")
    lines = changelog.splitlines()
    for start, line in enumerate(lines):
        if heading.match(line):
            break
    else:
        raise SystemExit(f"CHANGELOG.md has no '## {version} – <date>' heading")
    body = []
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        body.append(line)
    text = "\n".join(body).strip()
    if not text:
        raise SystemExit(f"CHANGELOG.md section {version} is empty")
    return text


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__.strip().splitlines()[2])
    path = sys.argv[2] if len(sys.argv) == 3 else "CHANGELOG.md"
    with open(path, encoding="utf-8") as f:
        print(section(f.read(), sys.argv[1]))


if __name__ == "__main__":
    main()
