"""Exercise archive/export commands with offline tool substitutes."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
IDENTITY = "A" * 40


class DeveloperIDArchiveTests(unittest.TestCase):
    def run_archive(self, identity):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            log = root / "calls.jsonl"
            script = (
                "#!" + sys.executable + "\n"
                "import json, os, pathlib, plistlib, sys\n"
                "name = pathlib.Path(sys.argv[0]).name\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['TEST_CALLS'], 'a') as stream:\n"
                "    stream.write(json.dumps({'tool': name, 'args': args}) + '\\n')\n"
                "if name == 'plutil':\n"
                "    path = pathlib.Path(args[-1])\n"
                "    data = {} if args[0] == '-create' else plistlib.loads(path.read_bytes())\n"
                "    if args[0] == '-insert': data[args[1]] = args[3]\n"
                "    path.write_bytes(plistlib.dumps(data))\n"
            )
            for name in ("xcodebuild", "plutil", "xcrun"):
                path = tools / name
                path.write_text(script)
                path.chmod(0o755)
            build = root / "build with spaces"
            result = subprocess.run(
                ["make", "-f", str(ROOT / "Makefile"), "-o", "prepare-runtime-bundle",
                 "build-swift-devid", "DEVELOPER_TEAM=TEAM123456",
                 "DEVELOPER_ID_IDENTITY=" + identity, "DMG_CHANNEL=release",
                 "MLX_DIST_DD=" + str(build), "NOTARY_ATTEMPTS=1",
                 "ASC_KEY_PATH=/notary/key.p8", "ASC_KEY_ID=EXAMPLEKEY",
                 "ASC_ISSUER_ID=EXAMPLEISSUER"],
                cwd=ROOT, capture_output=True, text=True,
                env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                     "TEST_CALLS": str(log)}, timeout=20,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            options = build / "ExportOptions.plist"
            return result, calls, plistlib.loads(options.read_bytes()) if options.exists() else None

    def test_archive_and_export_use_the_selected_distribution_identity(self):
        result, calls, options = self.run_archive(IDENTITY)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive, export, notarized = [c["args"] for c in calls if c["tool"] == "xcodebuild"]
        self.assertEqual(archive[0], "archive")
        self.assertIn("CODE_SIGN_STYLE=Manual", archive)
        self.assertIn("CODE_SIGN_IDENTITY=" + IDENTITY, archive)
        self.assertIn("ENABLE_HARDENED_RUNTIME=YES", archive)
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", archive)
        self.assertNotIn("-authenticationKeyPath", archive)
        self.assertIn("build with spaces", archive[archive.index("-derivedDataPath") + 1])
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["signingCertificate"], IDENTITY)
        self.assertEqual(options["teamID"], "TEAM123456")
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["destination"], "upload")
        for command in (archive, export, notarized):
            self.assertNotIn("-allowProvisioningUpdates", command)
        for command in (export, notarized):
            self.assertEqual(command[command.index("-authenticationKeyPath") + 1], "/notary/key.p8")
        self.assertEqual(export[0], "-exportArchive")
        self.assertEqual(notarized[0], "-exportNotarizedApp")
        self.assertIn(["stapler", "validate"], [c["args"][:2] for c in calls if c["tool"] == "xcrun"])

    def test_missing_or_invalid_identity_stops_before_signing(self):
        for identity in ("", "A" * 39, "Developer ID Application"):
            with self.subTest(identity=identity):
                result, calls, _ = self.run_archive(identity)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("DEVELOPER_ID_IDENTITY", result.stdout + result.stderr)
                self.assertEqual(calls, [])
