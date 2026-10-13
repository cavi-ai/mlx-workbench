#!/usr/bin/env python3
"""Install the optional pinned Strata engine and HTTP frontend; never download weights."""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "vendor/mlx-agent/src"))
from mlx_agent.strata_runtime import ENGINE_REVISION, HTTP_REVISION, INSTALL_MARKER, installed_runtime, runtime_root, source_digest


def checkout(url, revision, destination, reference=None):
    if destination.is_symlink():
        raise ValueError("Runtime directories must not be symbolic links")
    if not destination.exists():
        argv = ["git", "clone", "--no-checkout"]
        if reference is not None:
            argv += ["--reference-if-able", str(reference)]
        subprocess.run([*argv, url, str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", revision], check=True)
    head = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if head != revision:
        raise ValueError("An incompatible source checkout exists at " + str(destination))
    subprocess.run(["git", "-C", str(destination), "diff", "--exit-code", "HEAD", "--"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=runtime_root())
    parser.add_argument("--reference", type=Path, help="optional existing clones containing strata-mlx and strata-http")
    args = parser.parse_args()
    if not shutil.which("uv"):
        parser.error("uv is required to install Strata's frozen dependency lock")
    root = args.root.expanduser().absolute()
    if root.is_symlink():
        parser.error("The installation directory must not be a symbolic link")
    if (root / INSTALL_MARKER).exists():
        print(json.dumps(installed_runtime(root), indent=2))
        return
    root.mkdir(parents=True, exist_ok=True)
    for name, url, revision, reference_name in (
        ("engine", "https://github.com/yibie/strata-mlx.git", ENGINE_REVISION, "strata-mlx"),
        ("http", "https://github.com/Niko1221/Strata.git", HTTP_REVISION, "strata-http"),
    ):
        reference = args.reference / reference_name if args.reference else None
        checkout(url, revision, root / name, reference)
    subprocess.run(["uv", "sync", "--directory", str(root / "engine"), "--frozen", "--no-dev", "--python", "3.12"], check=True)
    python = root / "engine/.venv/bin/python"
    subprocess.run([str(python), "-c", "import mlx.core, mlx_lm.models.qwen4_exp, gguf, regex, jinja2"], check=True)
    marker = {"engine_revision": ENGINE_REVISION, "http_revision": HTTP_REVISION, "source_sha256": source_digest(root)}
    temporary = root / (INSTALL_MARKER + ".tmp")
    temporary.write_text(json.dumps(marker, indent=2) + "\n", encoding="utf-8")
    temporary.replace(root / INSTALL_MARKER)
    print(json.dumps(installed_runtime(root), indent=2))


if __name__ == "__main__":
    main()
