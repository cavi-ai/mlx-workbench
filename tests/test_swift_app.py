import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_PROJECT = ROOT / "mlx-mac" / "mlx-mac.xcodeproj"
SWIFT_SCHEME = "mlx-workbench"


@unittest.skipUnless(platform.system() == "Darwin", "Swift app hardening is only relevant on macOS.")
@unittest.skipUnless(shutil.which("xcodebuild") is not None, "xcodebuild not installed.")
class SwiftAppHardeningTests(unittest.TestCase):
    """Hardening tests for the macOS Swift workbench app.

    These are opt-in and only run when MLX_SWIFT_HARDENING=1 so local runs remain
    quick while CI can opt into stricter coverage.
    """

    def setUp(self):
        if os.environ.get("MLX_SWIFT_HARDENING") != "1":
            self.skipTest("Set MLX_SWIFT_HARDENING=1 to run Swift hardening tests.")
        if not SWIFT_PROJECT.is_dir():
            self.skipTest(f"Swift project missing: {SWIFT_PROJECT}")

    def test_swift_app_builds_with_xcodebuild(self):
        with tempfile.TemporaryDirectory(prefix="mlx-mac-build-") as build_dir:
            cmd = [
                "xcodebuild",
                "-project",
                str(SWIFT_PROJECT),
                "-scheme",
                SWIFT_SCHEME,
                "-configuration",
                "Debug",
                "-arch",
                "arm64",
                "-derivedDataPath",
                build_dir,
                "build",
            ]
            result = subprocess.run(
                cmd,
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=240,
            )
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertIn("** BUILD SUCCEEDED **", result.stdout + result.stderr)

    def test_swift_project_has_required_sources(self):
        source_dir = ROOT / "mlx-mac"
        self.assertTrue((source_dir / "App.swift").exists(), "App.swift missing from swift app source.")
        self.assertTrue((source_dir / "Info.plist").exists(), "App Info.plist missing.")
        self.assertTrue((source_dir / "mlx-mac.xcodeproj").exists(), "Xcode project missing.")


if __name__ == "__main__":
    unittest.main()
