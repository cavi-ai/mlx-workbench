import importlib.util
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/native_ui_vm.py"
spec = importlib.util.spec_from_file_location("native_ui_vm", SCRIPT)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class TartResolutionTests(unittest.TestCase):
    def test_explicit_executable_takes_precedence(self):
        self.assertEqual(vm.resolve_tart(Path("unused"), "/tools/tart"), "/tools/tart")

    def test_shared_application_is_used_without_a_path_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "Tart.app/Contents/MacOS/tart"
            shared.parent.mkdir(parents=True)
            shared.write_text("#!/bin/sh\nexit 0\n")
            shared.chmod(0o755)
            with patch.object(vm.shutil, "which", return_value=None), \
                    patch.object(vm, "SHARED_TART", shared):
                self.assertEqual(vm.resolve_tart(root), str(shared))

    def test_path_installation_takes_precedence_over_shared_application(self):
        with patch.object(vm.shutil, "which", return_value="/tools/tart"):
            self.assertEqual(vm.resolve_tart(Path("unused")), "/tools/tart")

    def test_legacy_bundle_remains_available_when_shared_install_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundled = root / ".build/native-ui-tools/tart.app/Contents/MacOS/tart"
            bundled.parent.mkdir(parents=True)
            bundled.write_text("#!/bin/sh\nexit 0\n")
            bundled.chmod(0o755)
            with patch.object(vm.shutil, "which", return_value=None), \
                    patch.object(vm, "SHARED_TART", root / "missing"):
                self.assertEqual(vm.resolve_tart(root), str(bundled))

    def test_missing_installation_reports_the_setup_guide(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(vm.shutil, "which", return_value=None), \
                    patch.object(vm, "SHARED_TART", root / "missing"):
                with self.assertRaisesRegex(RuntimeError, "Tart is required"):
                    vm.resolve_tart(root)


class NativeUIVMTests(unittest.TestCase):
    def artifact(self, root, number, size=10):
        run = root / f"ui-{number:012x}"
        run.mkdir(parents=True)
        (run / ".retention.json").write_text(json.dumps({"run_id": run.name}))
        (run / "result").write_bytes(b"x" * size)
        return run

    def test_retention_bounds_count_and_bytes_and_preserves_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            runs = [self.artifact(root, n) for n in range(1, 5)]
            for n, run in enumerate(runs):
                vm.os.utime(run / ".retention.json", (n + 1, n + 1))
            vm.prune_artifacts(root, keep=2, max_bytes=10**6)
            self.assertEqual([r.exists() for r in runs], [False, False, True, True])
            vm.prune_artifacts(root, keep=2, max_bytes=1)
            self.assertFalse(runs[2].exists())
            self.assertTrue(runs[3].exists())

    def test_retention_protects_active_pinned_unknown_and_linked_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            active, pinned, unknown, linked = [self.artifact(root, n) for n in range(1, 5)]
            (pinned / ".keep").touch()
            (unknown / ".retention.json").unlink()
            outside = root / "outside"
            outside.write_text("preserve")
            (linked / ".retention.json").unlink()
            (linked / ".retention.json").symlink_to(outside)
            (root / "ui-000000000005").symlink_to(pinned, target_is_directory=True)
            with (active / ".lock").open("w") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX)
                vm.prune_artifacts(root, keep=0, max_bytes=0)
            self.assertTrue(all(r.exists() for r in [active, pinned, unknown, linked]))
            self.assertEqual(outside.read_text(), "preserve")

    def test_run_workspace_removes_inputs_even_on_failure_and_preserves_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with self.assertRaisesRegex(RuntimeError, "fixture failure"):
                with vm.artifact_workspace(root) as run:
                    (run / "input").mkdir()
                    (run / "input/source").write_text("temporary")
                    (run / "output").mkdir()
                    (run / "output/source-manifest.json").write_text("evidence")
                    vm.prune_artifacts(root, keep=0, max_bytes=0)
                    self.assertTrue(run.exists())
                    raise RuntimeError("fixture failure")
            self.assertFalse((run / "input").exists())
            self.assertEqual((run / "output/source-manifest.json").read_text(), "evidence")

    def test_unresolved_vm_teardown_keeps_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with vm.artifact_workspace(root) as run:
                (run / "input").mkdir()
                (run / "input/source").write_text("shared input")
                (run / ".vm-active").touch()
            self.artifact(root, 1)
            vm.prune_artifacts(root, keep=0, max_bytes=0)
            self.assertEqual((run / "input/source").read_text(), "shared input")

    def test_shared_evidence_lease_prevents_pruning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            evidence = self.artifact(root, 1)
            self.artifact(root, 2)
            with (evidence / ".lock").open("w") as lease:
                fcntl.flock(lease, fcntl.LOCK_SH)
                vm.prune_artifacts(root, keep=0, max_bytes=0)
            self.assertTrue(evidence.exists())

    def test_host_leases_evidence_before_creating_and_pruning_a_run(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            root = repo / ".build/native-ui/runs"
            evidence = self.artifact(root, 1)
            (evidence / "output").mkdir()
            vm.os.utime(evidence / ".retention.json", (1, 1))
            for number in range(2, 9):
                self.artifact(root, number)
            args = SimpleNamespace(tart="fixture-tart", vm_home=str(repo / "vms"), base_vm="fixture",
                                   unit_evidence=str(evidence / "output"))
            def run(*arguments):
                self.assertTrue(evidence.exists())
                self.assertTrue(arguments[-1].exists())
            with patch.object(vm, "__file__", str(repo / "scripts/native_ui_vm.py")), \
                    patch.object(vm.subprocess, "check_output", return_value="fixture\n"), \
                    patch.object(vm, "host_run", side_effect=run) as execute:
                vm.host(args)
            execute.assert_called_once()
            self.assertTrue(evidence.exists())

    def test_retention_rejects_redirected_storage_and_preserves_external_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            external = root / "external"
            external.mkdir()
            (external / "data").write_text("preserve")
            runs = root / "runs"
            runs.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "symbolic links"):
                vm.prune_artifacts(runs)
            runs.unlink()
            old = self.artifact(runs, 1)
            (old / "external").symlink_to(external, target_is_directory=True)
            self.artifact(runs, 2)
            vm.os.utime(old / ".retention.json", (1, 1))
            vm.prune_artifacts(runs, keep=1)
            self.assertFalse(old.exists())
            self.assertEqual((external / "data").read_text(), "preserve")

    def test_prune_only_does_not_start_a_vm(self):
        with patch.object(vm.sys, "argv", ["native_ui_vm.py", "--prune-only"]), \
                patch.object(vm, "prune_artifacts", return_value={"busy": False}), patch.object(vm, "host") as launch:
            vm.main()
        launch.assert_not_called()

    def test_concurrent_pruners_do_not_recreate_a_deleted_run_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.artifact(root, 1)
            with (root / ".prune.lock").open("w") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX)
                self.assertTrue(vm.prune_artifacts(root)["busy"])
                self.assertFalse((root / "ui-000000000001/.lock").exists())

    def test_cleanup_preview_reports_the_same_files_as_cleanup_without_removing_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            runs = [self.artifact(root, n, size=n * 100) for n in range(1, 5)]
            for number, run in enumerate(runs, 1):
                vm.os.utime(run / ".retention.json", (number, number))
            (runs[0] / ".keep").touch()
            preview = vm.prune_artifacts(root, keep=1, dry_run=True)
            states = {r["run_id"]: r["state"] for r in preview["runs"]}
            self.assertEqual(states, {runs[0].name: "pinned", runs[1].name: "would_remove",
                                     runs[2].name: "would_remove", runs[3].name: "retained"})
            for number, run in enumerate(runs, 1):
                self.assertEqual((run / "result").read_bytes(), b"x" * (number * 100))
            cleanup = vm.prune_artifacts(root, keep=1)
            removed = {r["run_id"] for r in cleanup["runs"] if r["state"] == "removed"}
            self.assertEqual(removed, {runs[1].name, runs[2].name})
            self.assertEqual(cleanup["removed_file_bytes"], preview["removable_file_bytes"])
            self.assertTrue(runs[0].exists())
            self.assertTrue(runs[3].exists())

    def test_report_explains_protected_and_unmanaged_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            active, unresolved, pinned, unknown = [self.artifact(root, n) for n in range(1, 5)]
            (unresolved / ".vm-active").touch()
            (pinned / ".keep").symlink_to(root / "missing-pin-target")
            (unknown / ".retention.json").unlink()
            with (active / ".lock").open("w") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX)
                report = vm.prune_artifacts(root, dry_run=True)
            states = {r["run_id"]: r["state"] for r in report["runs"]}
            self.assertEqual(states, {active.name: "active", unresolved.name: "vm_active",
                                     pinned.name: "pinned", unknown.name: "unmanaged"})
            self.assertEqual(report["removable_file_bytes"], 0)

    def test_dry_run_requires_cleanup_and_never_starts_a_vm(self):
        with patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture", "--dry-run"]), \
                patch.object(vm, "host") as launch:
            with self.assertRaises(SystemExit):
                vm.main()
            launch.assert_not_called()
        with patch.object(vm.sys, "argv", ["native_ui_vm.py", "--prune-only", "--dry-run"]), \
                patch.object(vm, "prune_artifacts", return_value={"busy": False}) as prune, \
                patch.object(vm, "host") as launch:
            vm.main()
            self.assertTrue(prune.call_args.kwargs["dry_run"])
            launch.assert_not_called()

    def test_cleanup_cli_previews_applies_and_respects_another_process_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            script = repo / "scripts/native_ui_vm.py"
            script.parent.mkdir()
            shutil.copyfile(SCRIPT, script)
            root = repo / ".build/native-ui/runs"
            runs = [self.artifact(root, n) for n in range(1, 9)]
            for number, run in enumerate(runs, 1):
                vm.os.utime(run / ".retention.json", (number, number))
            command = [sys.executable, str(script), "--prune-only"]
            with (root / ".prune.lock").open("w") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX)
                busy = subprocess.run(command, capture_output=True, text=True, timeout=10)
                self.assertEqual(busy.returncode, 3, busy.stderr)
                self.assertTrue(json.loads(busy.stdout)["busy"])
                self.assertTrue(all(run.exists() for run in runs))
            preview = json.loads(subprocess.check_output([*command, "--dry-run"], text=True, timeout=10))
            self.assertTrue(all(run.exists() for run in runs))
            expected = {r["run_id"] for r in preview["runs"] if r["state"] == "would_remove"}
            self.assertEqual(expected, {r.name for r in runs[:3]})
            cleanup = json.loads(subprocess.check_output(command, text=True, timeout=10))
            self.assertEqual({r["run_id"] for r in cleanup["runs"] if r["state"] == "removed"}, expected)
            self.assertEqual(cleanup["removed_file_bytes"], preview["removable_file_bytes"])
            self.assertEqual([run.exists() for run in runs], [False] * 3 + [True] * 5)
            repeat = json.loads(subprocess.check_output(command, text=True, timeout=10))
            self.assertEqual(repeat["removed_file_bytes"], 0)

    def test_release_installation_requires_the_explicit_installation_route(self):
        selection = "mlx-workbenchUITests/SetupAssistantUITests/testPackagedRuntimeInstallsFromCleanSetup"
        routes = [[], ["--runtime-bundle", "bundle", "--ui-test", selection],
                  ["--runtime-bundle", "bundle", "--runtime-install-uv", "/tools/uv", "--ui-test", selection,
                   "--baseline-app", "baseline.app"]]
        for route in routes:
            with self.subTest(route=route), patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture",
                    "--runtime-install-dmg", "/packages/workbench.dmg", *route]), patch.object(vm, "host") as launch:
                with self.assertRaises(SystemExit):
                    vm.main()
                launch.assert_not_called()

    def test_release_installation_accepts_an_existing_disk_image_for_the_installation_case(self):
        with patch.object(vm.sys, "argv", ["native_ui_vm.py", "--base-vm", "fixture", "--runtime-bundle", "bundle",
                "--runtime-install-uv", "/tools/uv", "--runtime-install-dmg", "/packages/workbench.dmg",
                "--ui-test", "mlx-workbenchUITests/SetupAssistantUITests/testPackagedRuntimeInstallsFromCleanSetup"]), \
                patch.object(vm, "host") as launch:
            try:
                vm.main()
            except SystemExit as error:
                self.fail(f"The explicit Release installation route was rejected: {error}")
        self.assertEqual(launch.call_args.args[0].runtime_install_dmg, "/packages/workbench.dmg")

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
        for desktop in ("1024x768", "1440x1000", "2048x1280"):
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
