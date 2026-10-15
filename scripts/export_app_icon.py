#!/usr/bin/env python3
"""Render the icon master to the macOS asset ladder using ImageMagick."""

import json
from pathlib import Path
import subprocess
import shutil


def main():
    root = Path(__file__).resolve().parent.parent
    master = root / "mlx-mac/assets/app-icon.svg"
    magick = shutil.which("magick")
    if magick is None:
        raise RuntimeError("Install ImageMagick to render the app icon master.")
    assets = root / "mlx-mac/mlx-mac/Assets.xcassets"
    iconset = assets / "AppIcon.appiconset"
    sidebar = assets / "WorkbenchIcon.imageset"
    sidebar.mkdir(exist_ok=True)
    outputs = [(root / "mlx-mac/assets/app-icon-preview.png", 1024),
               (sidebar / "workbench.png", 128)]
    for entry in json.loads((iconset / "Contents.json").read_text())["images"]:
        size = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
        outputs.append((iconset / entry["filename"], size))
    for target, size in outputs:
        subprocess.run([magick, "-background", "none", str(master),
                        "-resize", f"{size}x{size}", "-strip", str(target)], check=True)
    (sidebar / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "workbench.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
