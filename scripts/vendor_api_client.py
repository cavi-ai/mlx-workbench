#!/usr/bin/env python3
"""Regenerate the bundled CAVI HTTP client from its published npm archive."""
import base64
import hashlib
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "0.22.0"
INTEGRITY = "GCp8qg2me4koz2wWF0iqJIr53Q2WzaacHy8IUO5LNFWqXryQpwmH1HJE5YMZNglbGPp32gOvllSe2r2Zv47j6w=="
RESOURCE = Path(__file__).resolve().parents[1] / "mlx-mac/mlx-mac/Resources"


def main():
    with tempfile.TemporaryDirectory(prefix="workbench-api-client-") as temporary:
        root = Path(temporary)
        archive = root / "package.tgz"
        urllib.request.urlretrieve(
            f"https://registry.npmjs.org/@cavi-ai/api-client/-/api-client-{VERSION}.tgz", archive)
        if base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() != INTEGRITY:
            raise ValueError("CAVI API client archive integrity mismatch")
        with tarfile.open(archive) as source:
            source.extractall(root, filter="data")
        subprocess.run([
            "npm", "exec", "--yes", "--package=esbuild@0.25.12", "--", "esbuild",
            str(root / "package/dist/core/http/client.js"), "--bundle", "--format=iife",
            "--global-name=CaviAPI", "--target=safari16", "--minify", "--legal-comments=none",
            f"--outfile={RESOURCE / 'cavi-api-client.js'}",
        ], check=True)
        (RESOURCE / "cavi-api-client-LICENSE.txt").write_bytes((root / "package/LICENSE").read_bytes())


if __name__ == "__main__":
    main()
