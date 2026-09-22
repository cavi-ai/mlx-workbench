"""App icon + DMG packaging contract tests. Skips gracefully off macOS."""

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "mlx-mac" / "mlx-mac" / "Assets.xcassets" / "AppIcon.appiconset"
MAKEFILE = (ROOT / "Makefile").read_text(encoding="utf-8")

REQUIRED_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def png_width(path):
    # PNG IHDR: width is bytes 16-20 big-endian.
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(data[16:20], "big")


class AppIconTests(unittest.TestCase):
    def test_appiconset_carries_every_macos_size(self):
        for filename, size in REQUIRED_SIZES.items():
            with self.subTest(icon=filename):
                path = ICONSET / filename
                self.assertTrue(path.is_file(), f"missing {filename}")
                self.assertEqual(png_width(path), size, filename)

    def test_contents_json_references_all_files(self):
        contents = (ICONSET / "Contents.json").read_text(encoding="utf-8")
        for filename in REQUIRED_SIZES:
            self.assertIn(filename, contents)
        # No dangling references to files that do not exist.
        for match in re.findall(r'"filename"\s*:\s*"([^"]+)"', contents):
            self.assertTrue((ICONSET / match).is_file(), match)

    def test_icon_source_is_checked_in(self):
        svg = (ROOT / "mlx-mac" / "assets" / "app-icon.svg").read_text(encoding="utf-8")
        # The master is the squircle style: 824pt rounded rect on a 1024 canvas.
        self.assertIn('rx="185"', svg)
        self.assertIn("1024", svg)


class DmgTargetTests(unittest.TestCase):
    def test_makefile_has_dmg_target_wired_to_release_build(self):
        for phrase in (
            "dmg: build-swift",
            "hdiutil create",
            "-format UDZO",
            "DMG_VOLUME",
            "CODESIGN_IDENTITY",
        ):
            self.assertIn(phrase, MAKEFILE)

    def test_dmg_target_is_declared_phony(self):
        lines = MAKEFILE.splitlines()
        phony = ""
        for index, line in enumerate(lines):
            if line.startswith(".PHONY:"):
                phony = line
                while phony.rstrip().endswith("\\"):
                    phony = phony.rstrip()[:-1]
                    index += 1
                    phony += " " + lines[index]
                break
        self.assertRegex(phony, r"\bdmg\b")

    def test_dmg_output_is_gitignored(self):
        entries = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
        self.assertIn("/.release/", entries)


if __name__ == "__main__":
    unittest.main()