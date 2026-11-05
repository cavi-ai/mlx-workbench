"""Fail a pull request that changes how the engine pin moves or moves it outside the pin bot.

Usage: pin_guard.py BASE HEAD BRANCH, in a checkout that holds both commits.
"""

import re
import subprocess
import sys

BOT_BRANCH = "bot/pin-engine-"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
BOT_FILES = ("vendor/mlx-agent",)
MECHANISM = (".gitmodules", ".github/workflows/pin-engine.yml", "scripts/pin_guard.py")
JOBS = {".github/workflows/pr.yml": ("pin-guard", "merge-engine-pin")}


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    return result.stdout if result.returncode == 0 else None


def show(rev, path):
    return git("show", f"{rev}:{path}")


def job(text, name):
    """The lines of one top-level workflow job, or None when it is absent."""
    lines = (text or "").splitlines()
    if f"  {name}:" not in lines:
        return None
    start = lines.index(f"  {name}:")
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^ {0,2}\S", lines[i])),
               len(lines))
    return lines[start:end]


def violations(base, head, branch):
    found = []
    for path in MECHANISM:
        before = show(base, path)
        if before is not None and before != show(head, path):
            found.append((path, "changes how the engine pin moves"))
    for path, names in JOBS.items():
        for name in names:
            before = job(show(base, path), name)
            if before is not None and before != job(show(head, path), name):
                found.append((path, f"changes the {name} job"))
    files, moved = [], []
    for line in (git("diff", "--raw", "--no-renames", base, head) or "").splitlines():
        meta, path = line.split("\t", 1)
        files.append(path)
        if "160000" in meta.split()[:2]:
            moved.append(path)
    authors = (git("log", "--format=%ae%n%ce", f"{base}..{head}") or "").split()
    bot = (branch.startswith(BOT_BRANCH) and authors and set(authors) == {BOT_EMAIL}
           and all(path in BOT_FILES for path in files))
    if moved and not bot:
        found += [(path, "moves a pin; pins move only through the pin-engine workflow")
                  for path in moved]
    return found


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    base = (git("merge-base", argv[0], argv[1]) or "").strip()
    if not base:
        print(f"::error::No merge base for {argv[0]} and {argv[1]}")
        return 1
    found = violations(base, argv[1], argv[2])
    for path, message in found:
        print(f"::error file={path}::{path} {message}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
