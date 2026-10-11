import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/native_ui_vm.py"
spec = importlib.util.spec_from_file_location("native_ui_vm", SCRIPT)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class NativeUIVMTests(unittest.TestCase):
    def test_snapshot_keeps_working_source_without_private_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, output = root / "repo", root / "output"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / ".gitignore").write_text(".build/\n.env\n")
            (repo / "view.swift").write_text("original")
            subprocess.run(["git", "-C", str(repo), "add", ".gitignore", "view.swift"], check=True)
            (repo / "view.swift").write_text("current")
            (repo / "new.swift").write_text("new source")
            (repo / ".env").write_text("private configuration")
            (repo / ".build").mkdir()
            (repo / ".build/private.md").write_text("private notes")
            records = vm.snapshot(repo, output)
            paths = {record["path"] for record in records}
            self.assertEqual(paths, {".gitignore", "view.swift", "new.swift"})
            self.assertEqual((output / "view.swift").read_text(), "current")
            self.assertFalse((output / ".git").exists())
            self.assertEqual(len(next(r for r in records if r["path"] == "view.swift")["sha256"]), 64)

    def test_snapshot_refuses_links_outside_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (root / "private").write_text("private")
            (repo / "external").symlink_to(root / "private")
            with self.assertRaisesRegex(RuntimeError, "leaves the checkout"):
                vm.snapshot(repo, root / "output")
            (repo / "external").unlink()
            external_repo = root / "external-repo"
            subprocess.run(["git", "init", "-q", str(external_repo)], check=True)
            (external_repo / "private").write_text("private external source")
            (repo / "external").symlink_to(external_repo, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "leaves the checkout"):
                vm.snapshot(repo, root / "directory-output")

    def test_guest_refuses_host_before_accessing_paths_or_gui(self):
        with patch.object(vm.subprocess, "check_output", return_value="Mac14,6\n") as probe:
            with self.assertRaisesRegex(RuntimeError, "refused outside"):
                vm.guest("/nonexistent-input", "/nonexistent-output")
        probe.assert_called_once_with(["sysctl", "-n", "hw.model"], text=True)

    def test_zero_tests_and_skipped_ui_tests_cannot_pass(self):
        zero = {"result": "Passed", "totalTestCount": 0, "passedTests": 0, "failedTests": 0}
        with self.assertRaises(RuntimeError):
            vm.validate_test_summary(zero)
        skipped = {"result": "Passed", "totalTestCount": 6, "passedTests": 5, "failedTests": 0, "skippedTests": 1}
        with self.assertRaises(RuntimeError):
            vm.validate_test_summary(skipped, expected_ui_tests=6)
        vm.validate_test_summary(dict(skipped, passedTests=6, skippedTests=0), expected_ui_tests=6)


if __name__ == "__main__":
    unittest.main()
