#!/usr/bin/env python3
"""Generates the website's repo-derived inputs under site/.

Usage: python3 -I scripts/site-prepare.py <repo-root>

Writes site/data/facts.json (pinned versions from vm/Dockerfile),
site/content/reference/*.md (one page per command in the docc reference) and
site/static/install.sh (a copy of the repo's install.sh, served by the site).
Fails loudly when an expected input is missing, so the site can't go blank.
"""
import json
import re
import shutil
import sys
from pathlib import Path

FACT_KEYS = {
    "KERNEL_VERSION": "kernel",
    "DOCKER_VERSION": "docker",
    "ALPINE": "alpine",
    "GOLANG": "golang",
}
DOCC = "Sources/DockmaCLI/DockmaCLI.docc/dockma.md"


def write_facts(root: Path) -> None:
    """Writes site/data/facts.json from the ARG lines of vm/Dockerfile."""
    facts = {}
    for line in (root / "vm/Dockerfile").read_text().splitlines():
        match = re.match(r"ARG\s+([A-Z0-9_]+)=(\S+)", line)
        if match and match[1] in FACT_KEYS:
            facts.setdefault(FACT_KEYS[match[1]], match[2])
    missing = sorted(set(FACT_KEYS.values()) - facts.keys())
    if missing:
        sys.exit(f"vm/Dockerfile has no ARG for: {', '.join(missing)}")
    facts["kernelSeries"] = ".".join(facts["kernel"].split(".")[:2])
    (root / "site/data/facts.json").write_text(json.dumps(facts, indent=2) + "\n")


def write_reference(root: Path) -> None:
    """Splits the docc reference into one Hugo page per `## dockma.<command>` section."""
    out = root / "site/content/reference"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    text = (root / DOCC).read_text()
    sections = re.split(r"^## dockma\.(\S+)\s*$", text, flags=re.MULTILINE)
    # sections = [preamble, name1, body1, name2, body2, ...]
    commands = list(zip(sections[1::2], sections[2::2]))
    if not commands:
        sys.exit(f"no `## dockma.<command>` sections found in {DOCC}")
    for weight, (name, body) in enumerate(commands, start=1):
        summary = next((l for l in body.splitlines() if l.strip()), "")
        front = (
            "---\n"
            f"title: {json.dumps('dockma ' + name)}\n"
            f"summary: {json.dumps(summary)}\n"
            f"weight: {weight}\n"
            "---\n\n"
        )
        (out / f"{name}.md").write_text(front + body.strip() + "\n")
    (out / "_index.md").write_text(
        "---\n"
        'title: "Command reference"\n'
        'summary: "Every dockma command and flag: start, stop, shell, config, logs and more."\n'
        "---\n"
    )


def copy_installer(root: Path) -> None:
    """Copies install.sh into site/static/, so the site serves it at /install.sh."""
    shutil.copyfile(root / "install.sh", root / "site/static/install.sh")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(sys.argv[1]).resolve()
    write_facts(root)
    write_reference(root)
    copy_installer(root)


if __name__ == "__main__":
    main()
