#!/usr/bin/env python3
"""Checks the code links in docs: every relative link must name an existing
file, and a link whose text is a symbol in backticks (`Type.member`) must
point at a file that declares the last part of it.

Usage: scripts/check-doc-refs.py docs/architecture.md ...
       scripts/check-doc-refs.py --self-test
"""
import os
import re
import sys

LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
SYMBOL = re.compile(r"`([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)`")
# One pattern per language; a declaration anywhere in the file counts.
DECLARATIONS = [
    # Swift and Go, Go methods included: func (w *portWatcher) relist
    r"\b(?:func|var|let|case|class|struct|enum|protocol|actor|typealias|type|const)\s+(?:\([^)]*\)\s*)?{name}\b",
    r"^\s*{name}\s*\(\)",  # shell function
    r"^[A-Za-z_][^\n;]*\b{name}\s*\(",  # C function definition
    r"\bAS\s+{name}\b",  # Dockerfile stage
    r"^\s*{name}:",  # YAML key, such as a workflow job
]


def declares(source, name):
    """Whether `source` declares `name` in any of the known languages."""
    return any(re.search(p.format(name=re.escape(name)), source, re.MULTILINE) for p in DECLARATIONS)


def problems(doc_path, read=lambda p: open(p, encoding="utf-8").read(), exists=os.path.isfile):
    """The broken links in the doc at `doc_path`, as messages."""
    found = []
    base = os.path.dirname(doc_path)
    for text, target in LINK.findall(read(doc_path)):
        if re.match(r"[a-z]+:", target) or target.startswith("#"):
            continue  # a URL or an anchor on this page
        path = os.path.normpath(os.path.join(base, target.split("#")[0]))
        if not exists(path):
            found.append(f"{doc_path}: [{text}]({target}): no file {path}")
            continue
        symbol = SYMBOL.fullmatch(text)
        # A file's own name (`init`, `release.yml`) is no symbol.
        if not symbol or symbol.group(1) == os.path.basename(path):
            continue
        name = symbol.group(1).split(".")[-1]
        if not declares(read(path), name):
            found.append(f"{doc_path}: [{text}]({target}): {path} declares no {name}")
    return found


def self_test():
    assert declares("    private func boot() throws {", "boot")
    assert declares("    nonisolated static let shutdownGrace: Duration = .seconds(25)", "shutdownGrace")
    assert declares("func (w *portWatcher) relist(ctx context.Context) error {", "relist")
    assert declares("cmdline_path() {\n", "cmdline_path")
    assert declares("static int dn_apply(char op, const char *path)", "dn_apply")
    assert declares("FROM kernel-src AS kernel\n", "kernel")
    assert declares("  publish:\n", "publish")
    assert not declares("    private func bootVM() throws {", "boot")
    assert not declares("        try boot()", "boot")
    files = {
        "docs/a.md": "[`Daemon.boot`](../D.swift) [`Daemon.gone`](../D.swift) [x](../missing) "
                     "[`D.swift`](../D.swift) [y](https://example.com) [z](#top)",
        "D.swift": "final class Daemon {\n    private func boot() {}\n}\n",
    }
    found = problems("docs/a.md", read=files.__getitem__, exists=files.__contains__)
    assert len(found) == 2 and "declares no gone" in found[0] and "no file missing" in found[1], found
    print("self-test passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    if not sys.argv[1:]:
        sys.exit(__doc__)
    errors = [p for doc in sys.argv[1:] for p in problems(doc)]
    print("\n".join(errors) or f"{len(sys.argv) - 1} doc(s): all code links resolve")
    sys.exit(1 if errors else 0)
