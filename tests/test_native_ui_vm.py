import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/native_ui_vm.py"
spec = importlib.util.spec_from_file_location("native_ui_vm", SCRIPT)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class NativeUIVMTests(unittest.TestCase):
    def test_runtime_installation_requires_its_explicit_bundle_and_test(self):
        for extra in ([], ["--runtime-bundle", "bundle", "--ui-test", "another-test"]):
            with self.subTest(extra=extra), patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture", "--runtime-install-uv", "/tools/uv", *extra]), \
                    patch.object(vm, "host") as launch:
                with self.assertRaises(SystemExit):
                    vm.main()
                launch.assert_not_called()

    def test_runtime_installation_option_reaches_the_runner_for_the_selected_test(self):
        selection = "mlx-workbenchUITests/SetupAssistantUITests/testPackagedRuntimeInstallsFromCleanSetup"
        with patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture", "--runtime-install-uv", "/tools/uv", "--runtime-bundle", "bundle", "--ui-test", selection]), \
                patch.object(vm, "host") as launch:
            vm.main()
        self.assertEqual(launch.call_args.args[0].runtime_install_uv, "/tools/uv")

    def test_focused_run_preserves_multiple_requested_cases(self):
        cases = ["mlx-workbenchUITests/WorkbenchReviewUITests/testLibraryClassifierTaskAndMissingModelHistory",
                 "mlx-workbenchUITests/WorkbenchReviewUITests/testLibraryMusicTaskLifecycle"]
        with patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture",
                                         "--ui-test", cases[0], "--ui-test", cases[1]]), \
                patch.object(vm, "host") as launch:
            vm.main()
        self.assertEqual(launch.call_args.args[0].ui_test, cases)

    def test_desktop_size_is_selected_before_guest_launch(self):
        for desktop in ("1024x768", "1440x1000"):
            with self.subTest(desktop=desktop), \
                    patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture", "--desktop-size", desktop]), \
                    patch.object(vm, "host") as launch:
                try:
                    vm.main()
                except SystemExit as error:
                    self.fail(f"The requested desktop was rejected: {error}")
                self.assertEqual(launch.call_args.args[0].desktop_size, desktop)

    def test_exited_vm_fails_before_guest_probe_or_wait(self):
        process = Mock()
        process.poll.return_value = 1
        with patch.object(vm.subprocess, "run") as probe, patch.object(vm.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "VM exited before"):
                vm.wait_for_guest("tart", "test-vm", process, {})
        probe.assert_not_called()
        sleep.assert_not_called()

    def test_live_vm_readiness_wait_is_bounded(self):
        process = Mock()
        process.poll.return_value = None
        with patch.object(vm.time, "monotonic", side_effect=[0, 0, 301]), \
                patch.object(vm.time, "sleep"), \
                patch.object(vm.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as probe:
            with self.assertRaisesRegex(RuntimeError, "within 300 seconds"):
                vm.wait_for_guest("tart", "test-vm", process, {})
        probe.assert_called_once()
        self.assertEqual(probe.call_args.kwargs["timeout"], 5)

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

    def test_display_setup_failure_prevents_gui_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source-manifest.json").write_text('{"preflight_only": true}')
            failure = subprocess.CalledProcessError(1, ["/usr/bin/swift"])
            with patch.object(vm.os, "getuid", return_value=501), \
                    patch.object(vm.subprocess, "check_output", side_effect=["VirtualMac2,1", "501", "Aqua", failure]), \
                    patch.object(vm, "checked") as launch:
                with self.assertRaises(subprocess.CalledProcessError):
                    vm.guest(root, root / "output")
            launch.assert_not_called()
            self.assertFalse((root / "output/gui-preflight.json").exists())

    def test_preflight_records_display_mode_before_gui_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source-manifest.json").write_text('{"preflight_only": true}')
            display = '{"before":{"width":1024,"height":768},"after":{"width":1440,"height":1000}}'
            with patch.object(vm.os, "getuid", return_value=501), \
                    patch.object(vm.subprocess, "check_output", side_effect=["VirtualMac2,1", "501", "Aqua", display, "{}"]), \
                    patch.object(vm, "checked") as launch:
                vm.guest(root, root / "output")
            self.assertEqual((root / "output/display-preflight.json").read_text(), display)
            self.assertTrue((root / "output/gui-preflight.json").is_file())
            self.assertEqual(launch.call_args_list[0].args[0], ["/usr/bin/open", "-a", "Calculator"])

    def test_compact_desktop_is_applied_to_both_preflight_probes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source-manifest.json").write_text('{"preflight_only":true,"desktop_size":"1024x768"}')
            with patch.object(vm.os, "getuid", return_value=501), \
                    patch.object(vm.subprocess, "check_output", side_effect=["VirtualMac2,1", "501", "Aqua", "{}", "{}"]) as probe, \
                    patch.object(vm, "checked"):
                vm.guest(root, root / "output")
            for call in probe.call_args_list[3:]:
                self.assertEqual(call.kwargs["env"]["MLX_WORKBENCH_UI_DESKTOP_WIDTH"], "1024")
                self.assertEqual(call.kwargs["env"]["MLX_WORKBENCH_UI_DESKTOP_HEIGHT"], "768")

    def test_zero_tests_and_skipped_ui_tests_cannot_pass(self):
        zero = {"result": "Passed", "totalTestCount": 0, "passedTests": 0, "failedTests": 0}
        with self.assertRaises(RuntimeError):
            vm.validate_test_summary(zero)
        skipped = {"result": "Passed", "totalTestCount": 6, "passedTests": 5, "failedTests": 0, "skippedTests": 1}
        with self.assertRaises(RuntimeError):
            vm.validate_test_summary(skipped, expected_ui_tests=6)
        vm.validate_test_summary(dict(skipped, passedTests=6, skippedTests=0), expected_ui_tests=6)

    def test_runtime_input_list_is_written_outside_the_read_only_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, output = root / "input", root / "output"
            inputs.mkdir()
            output.mkdir()
            (inputs / "source-manifest.json").write_text(json.dumps({
                "run_id": "fixture", "files": [], "runtime_bundle": True,
            }))
            with patch.object(vm.os, "getuid", return_value=501), \
                    patch.object(vm.os, "chdir"), \
                    patch.object(vm.subprocess, "check_output", side_effect=["VirtualMac2,1", "501", "Aqua", "{}", "{}"]), \
                    patch.object(vm, "checked"), \
                    patch.object(vm.subprocess, "run", side_effect=RuntimeError("build boundary")) as build:
                with self.assertRaisesRegex(RuntimeError, "build boundary"):
                    vm.guest(inputs, output)
            listing = output / "runtime-inputs.xcfilelist"
            self.assertEqual(listing.read_text(), str(inputs / "runtime-bundle") + "\n")
            self.assertFalse((inputs / listing.name).exists())
            self.assertIn("MLX_WORKBENCH_RUNTIME_INPUTS=" + str(listing), build.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
