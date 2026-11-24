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
SWIFT_MAKE_TARGET = "build-swift"


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

    def _run_xcodebuild(self, build_dir: str, configuration: str = "Debug") -> subprocess.CompletedProcess[str]:
        cmd = [
            "xcodebuild",
            "-skipPackagePluginValidation",
            "-project",
            str(SWIFT_PROJECT),
            "-scheme",
            SWIFT_SCHEME,
            "-configuration",
            configuration,
            "-arch",
            "arm64",
            "-derivedDataPath",
            build_dir,
            "build",
        ]
        return subprocess.run(
            cmd,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=240,
        )

    def test_swift_app_builds_with_xcodebuild(self):
        with tempfile.TemporaryDirectory(prefix="mlx-mac-build-") as build_dir:
            result = self._run_xcodebuild(build_dir, configuration="Debug")
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertIn("** BUILD SUCCEEDED **", result.stdout + result.stderr)
            self.assertTrue((Path(build_dir) / "Build/Products/Debug/mlx-workbench.app").is_dir())

    def test_swift_build_target_obeys_derived_data_environment(self):
        with tempfile.TemporaryDirectory(prefix="mlx-mac-make-") as build_dir:
            env = os.environ.copy()
            env["MLX_SWIFT_DD"] = build_dir
            result = subprocess.run(
                ["make", SWIFT_MAKE_TARGET],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertTrue((Path(build_dir) / "Build/Products/Release/mlx-workbench.app").is_dir())


if __name__ == "__main__":
    unittest.main()
