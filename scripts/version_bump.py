#!/usr/bin/env python3
"""Bump the product version everywhere it is recorded.

Usage: python3 scripts/version_bump.py X.Y.Z

Updates, in one atomic pass (all content is validated before any file is
written):
  - mlx_workbench/__init__.py        (__version__ — the source of truth)
  - mlx-mac/mlx-mac.xcodeproj/project.pbxproj  (MARKETING_VERSION, all configs)
  - tests/test_release_docs.py       (VERSION / TAG constants)
  - CHANGELOG.md                     (promote [Unreleased] to [X.Y.Z] - <today>,
                                      refresh the compare/tag link refs)

stdlib-only; safe to re-run (fails if the version is already current).
"""

from datetime import date
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def fail(message):
    print(f"version-bump: {message}", file=sys.stderr)
    sys.exit(1)


def current_version():
    source = (ROOT / "mlx_workbench" / "__init__.py").read_text()
    match = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', source, re.M)
    if not match:
        fail("mlx_workbench.__version__ is missing")
    return match.group(1)


def sub(path, pattern, replacement, count=0):
    """Return path's text with the substitution applied; fail if no match."""
    text = path.read_text()
    new, n = re.subn(pattern, replacement, text, count=count, flags=re.M)
    if n == 0:
        fail(f"no match for {pattern!r} in {path.relative_to(ROOT)}")
    return new


def bumped_changelog(old, new):
    path = ROOT / "CHANGELOG.md"
    text = path.read_text()
    if f"## [{new}]" in text:
        fail(f"CHANGELOG.md already documents {new}")
    unreleased = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## )", text, re.M | re.S)
    if not unreleased:
        fail("CHANGELOG.md has no [Unreleased] section")
    body = unreleased.group(1).strip()
    if not body:
        fail("CHANGELOG.md [Unreleased] section is empty — nothing to release")
    base = "https://github.com/cavi-ai/mlx-workbench"
    old_ref = f"[Unreleased]: {base}/compare/v{old}...HEAD"
    if old_ref not in text:
        fail(f"CHANGELOG.md is missing the link ref {old_ref!r}")
    today = date.today().isoformat()
    text = text.replace(
        unreleased.group(0),
        f"## [Unreleased]\n\n## [{new}] - {today}\n{body}\n\n",
        1,
    )
    return text.replace(
        old_ref,
        f"[Unreleased]: {base}/compare/v{new}...HEAD\n[{new}]: {base}/releases/tag/v{new}",
    )


def main():
    if len(sys.argv) != 2 or not SEMVER.match(sys.argv[1]):
        fail("usage: version_bump.py X.Y.Z")
    old, new = current_version(), sys.argv[1]
    if new == old:
        fail(f"version is already {new}")

    # Compute and validate everything before writing anything.
    init_py = ROOT / "mlx_workbench" / "__init__.py"
    pbxproj = ROOT / "mlx-mac" / "mlx-mac.xcodeproj" / "project.pbxproj"
    docs_test = ROOT / "tests" / "test_release_docs.py"
    docs_text = sub(docs_test, r'^VERSION = "[^"]+"', f'VERSION = "{new}"', count=1)
    docs_text, n = re.subn(r'^TAG = "[^"]+"', f'TAG = "v{new}"', docs_text, count=1, flags=re.M)
    if n == 0:
        fail(f"no TAG constant in {docs_test.relative_to(ROOT)}")
    writes = {
        init_py: sub(init_py, r'^__version__\s*=\s*"[^"]+"', f'__version__ = "{new}"', count=1),
        pbxproj: sub(pbxproj, r"^(\s*)MARKETING_VERSION = [^;]+;", rf"\g<1>MARKETING_VERSION = {new};"),
        docs_test: docs_text,
        ROOT / "CHANGELOG.md": bumped_changelog(old, new),
    }

    for path, text in writes.items():
        path.write_text(text)

    print(f"bumped {old} -> {new}")
    print(f"next: make test && make docs-test && git commit && git tag v{new}")


if __name__ == "__main__":
    main()
