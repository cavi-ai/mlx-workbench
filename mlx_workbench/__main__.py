"""Open the native MLX Workbench application."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", help="path to a built native application")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    app = Path(args.app or os.environ.get("MLX_WORKBENCH_APP",
        str(root / ".run/swift-build/Build/Products/Release/mlx-workbench.app"))).expanduser()
    if not app.is_dir():
        print("Build the native application with make build-swift, or pass --app.", file=sys.stderr)
        return 2
    return subprocess.run(["/usr/bin/open", str(app)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
