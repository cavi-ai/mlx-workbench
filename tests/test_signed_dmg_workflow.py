"""Execute release-asset selection without network or signing credentials."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from mlx_workbench import __version__


ROOT = Path(__file__).resolve().parents[1]


class ExistingReleaseDiskImageTests(unittest.TestCase):
    def run_selection(self, digest, tag=None):
        workflow = (ROOT / ".github/workflows/signed-dmg.yml").read_text()
        step = workflow.split("      - name: Use an existing release disk image\n", 1)[1]
        block = step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
        script = "\n".join(line[10:] for line in block.splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "candidate.dmg"
            payload.write_bytes(b"candidate disk image")
            calls = root / "calls"
            output = root / "output"
            output.touch()
            gh = root / "gh"
            gh.write_text(
                "#!/usr/bin/env python3\n"
                "import os, shutil, sys\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['TEST_CALLS'], 'a') as log:\n"
                "    log.write(' '.join(args) + '\\n')\n"
                "if args[:2] == ['release', 'view']:\n"
                "    print(os.environ['TEST_DIGEST'])\n"
                "elif args[:2] == ['release', 'download']:\n"
                "    shutil.copyfile(os.environ['TEST_PAYLOAD'], args[args.index('--output') + 1])\n"
                "else:\n"
                "    sys.exit(1)\n"
            )
            gh.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", script], cwd=ROOT, capture_output=True, text=True,
                env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                     "TAG": tag or f"v{__version__}", "GITHUB_REPOSITORY": "cavi-ai/mlx-workbench",
                     "RUNNER_TEMP": str(root), "GITHUB_OUTPUT": str(output),
                     "TEST_CALLS": str(calls), "TEST_PAYLOAD": str(payload), "TEST_DIGEST": digest},
            )
            return result, output.read_text(), calls.read_text() if calls.exists() else ""

    def test_matching_download_is_selected_for_signature_verification(self):
        digest = "sha256:" + hashlib.sha256(b"candidate disk image").hexdigest()
        result, output, calls = self.run_selection(digest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(output, rf"dmg=.+/mlx-workbench-{__version__}[.]dmg\n")
        self.assertIn("release download", calls)

    def test_absent_asset_leaves_the_build_path_selected(self):
        result, output, calls = self.run_selection("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "")
        self.assertNotIn("release download", calls)

    def test_missing_or_mismatched_digest_cannot_select_a_candidate(self):
        for digest in ("missing", "sha256:" + "0" * 64):
            with self.subTest(digest=digest):
                result, output, _ = self.run_selection(digest)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")

    def test_wrong_release_tag_is_refused_before_fetching_assets(self):
        result, output, calls = self.run_selection("", tag="v99.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")
        self.assertEqual(calls, "")
