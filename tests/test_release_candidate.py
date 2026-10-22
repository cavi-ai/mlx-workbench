import importlib.util
from pathlib import Path
import tempfile
import unittest
import urllib.error
import urllib.request


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/release_candidate.py"
spec = importlib.util.spec_from_file_location("release_candidate", SCRIPT)
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class ReleaseCandidateTests(unittest.TestCase):
    def test_candidate_gate_requires_one_pass_without_skips_or_failures(self):
        passed = dict(result="Passed", totalTestCount=1, passedTests=1,
                      failedTests=0, skippedTests=0, expectedFailures=0)
        candidate.validate_summary(passed)
        for key, value in [("result", "Failed"), ("passedTests", 0),
                           ("totalTestCount", 0), ("skippedTests", 1),
                           ("failedTests", 1), ("expectedFailures", 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                candidate.validate_summary({**passed, key: value})
        with self.assertRaises(ValueError):
            candidate.validate_summary({})

    def test_download_server_serves_only_the_selected_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "candidate.dmg"
            dmg.write_bytes(b"disk-image")
            (root / "private.txt").write_text("private")
            with candidate.serve_artifact(dmg) as url:
                with urllib.request.urlopen(url, timeout=2) as response:
                    self.assertEqual(response.read(), b"disk-image")
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(url.replace("candidate.dmg", "private.txt"), timeout=2)
                self.assertEqual(caught.exception.code, 404)
                caught.exception.close()
