"""Record the vendored mlx-agent pin on the Unreleased Engine line of CHANGELOG.md."""

import json
from pathlib import Path
import re
import sys

ENGINE_LINE = re.compile(r"^- Engine: `mlx-agent` moves to \S+ at `[0-9a-f]+`", re.MULTILINE)
CHANGED = re.compile(r"^### Changed\n\n?", re.MULTILINE)


def record(changelog: str, version: str, commit: str) -> str:
    start = changelog.index("## [Unreleased]")
    end = changelog.find("\n## [", start)
    end = len(changelog) if end < 0 else end + 1
    section = changelog[start:end]
    entry = f"- Engine: `mlx-agent` moves to {version} at `{commit}`"
    if ENGINE_LINE.search(section):
        section = ENGINE_LINE.sub(entry, section, count=1)
    elif changed := CHANGED.search(section):
        section = f"{section[:changed.end()]}{entry}.\n{section[changed.end():]}"
    else:
        section = f"{section.rstrip(chr(10))}\n\n### Changed\n\n{entry}.\n\n"
    return changelog[:start] + section + changelog[end:]


def main(changelog_path: str, manifest_path: str, commit: str) -> None:
    version = json.loads(Path(manifest_path).read_text())["version"]
    path = Path(changelog_path)
    path.write_text(record(path.read_text(), version, commit))


if __name__ == "__main__":
    main(*sys.argv[1:])
