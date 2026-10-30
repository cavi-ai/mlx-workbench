#!/usr/bin/env python3
"""Run native UI tests on a disposable macOS VM, never on the host desktop."""

import argparse
from contextlib import ExitStack, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

RUNTIME_INSTALL_TEST = "mlx-workbenchUITests/SetupAssistantUITests/testPackagedRuntimeInstallsFromCleanSetup"
ARTIFACT_KEEP_RUNS = 5
ARTIFACT_MAX_BYTES = 2 * 1024**3
SHARED_TART = Path("/Applications/Tart.app/Contents/MacOS/tart")


def resolve_tart(repo, explicit=None):
    if executable := explicit or shutil.which("tart"):
        return executable
    for candidate in (SHARED_TART, Path(repo) / ".build/native-ui-tools/tart.app/Contents/MacOS/tart"):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise RuntimeError("Tart is required. See mlx-mac/README.md#isolated-native-ui-tests.")


def artifact_root(path):
    path = Path(path)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise RuntimeError("Artifact storage must not use symbolic links.")
    path.mkdir(parents=True, exist_ok=True)
    return path


def artifact_bytes(path):
    return sum((Path(directory) / name).lstat().st_size
               for directory, _, names in os.walk(path, followlinks=False) for name in names)


def protected_artifact_state(run):
    if os.path.lexists(run / ".vm-active"):
        return "vm_active"
    if os.path.lexists(run / ".keep"):
        return "pinned"
    return None


def prune_artifacts(root, keep=ARTIFACT_KEEP_RUNS, max_bytes=ARTIFACT_MAX_BYTES, dry_run=False):
    """Prune only registered, unlocked runs; pins and unresolved VM leases survive."""
    root = artifact_root(root)
    report = {"schema": 1, "dry_run": dry_run, "busy": False,
              "keep_runs": keep, "max_file_bytes": max_bytes, "runs": [],
              "removable_file_bytes": 0, "removed_file_bytes": 0}
    descriptor = os.open(root / ".prune.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            report["busy"] = True
            return report
        report["runs"] = _prune_artifacts(root, keep, max_bytes, dry_run)
    report["removable_file_bytes"] = sum(r["file_bytes"] for r in report["runs"]
                                          if r["state"] in {"would_remove", "removed"})
    report["removed_file_bytes"] = sum(r["file_bytes"] for r in report["runs"] if r["state"] == "removed")
    return report


def _prune_artifacts(root, keep, max_bytes, dry_run):
    candidates = []
    entries = []
    def record(run, state, size=None):
        entries.append({"run_id": run.name, "state": state, "file_bytes": size})
    for run in root.iterdir():
        if not re.fullmatch(r"ui-[0-9a-f]{12}", run.name):
            continue
        if run.is_symlink() or not run.is_dir():
            record(run, "unmanaged")
            continue
        marker = run / ".retention.json"
        try:
            if marker.is_symlink() or not marker.is_file():
                record(run, "unmanaged")
                continue
            if json.loads(marker.read_text()).get("run_id") != run.name:
                record(run, "unmanaged")
                continue
            candidates.append((marker.stat().st_mtime, run))
        except (OSError, ValueError, AttributeError):
            record(run, "unmanaged")
            continue
    # Lock candidates before counting: active or pinned runs do not consume the
    # bounded completed-run allowance and can never be removed by another run.
    with ExitStack() as locks:
        available = []
        for _, run in sorted(candidates, reverse=True):
            try:
                descriptor = os.open(run / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                lease = locks.enter_context(os.fdopen(descriptor, "w"))
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if state := protected_artifact_state(run):
                    record(run, state, artifact_bytes(run))
                    continue
                available.append((run, artifact_bytes(run)))
            except BlockingIOError:
                record(run, "active")
            except OSError:
                record(run, "unavailable")
                continue
        retained_bytes = 0
        retained_count = 0
        for run, size in available:
            if state := protected_artifact_state(run):
                record(run, state, size)
                continue
            # Always retain the newest run even when that run alone exceeds the budget.
            if retained_count == 0 or (retained_count < keep and retained_bytes + size <= max_bytes):
                retained_count += 1
                retained_bytes += size
                record(run, "retained", size)
                continue
            if dry_run:
                record(run, "would_remove", size)
            else:
                shutil.rmtree(run)
                record(run, "removed", size)
    return entries


@contextmanager
def artifact_workspace(root):
    root = artifact_root(root)
    run = root / f"ui-{uuid.uuid4().hex[:12]}"
    run.mkdir()
    try:
        with (run / ".lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            (run / ".retention.json").write_text(json.dumps({"run_id": run.name}) + "\n")
            prune_artifacts(root)
            try:
                yield run
            finally:
                # If VM teardown failed, its shared inputs must remain available.
                if not os.path.lexists(run / ".vm-active"):
                    inputs = run / "input"
                    if inputs.is_symlink():
                        inputs.unlink()
                    elif inputs.exists():
                        shutil.rmtree(inputs)
    finally:
        prune_artifacts(root)


def checked(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def runtime_app_identity(app, metadata, commit):
    from runtime_bundle import verify_bundle
    checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    payload = app / "Contents/Resources/Runtime"
    verify_bundle(payload)
    if (payload / "manifest.json").read_bytes() != metadata:
        raise RuntimeError("The application contains a different runtime payload.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.cavi.mlxworkbench" or info.get("MLXWorkbenchCommit") != commit[:12]:
        raise RuntimeError("The application does not match the requested source revision.")
    if info.get("CFBundleShortVersionString") != json.loads(metadata)["workbench_version"]:
        raise RuntimeError("The application version does not match its runtime payload.")
    return {"binary_sha256": hashlib.sha256((app / "Contents/MacOS/mlx-workbench").read_bytes()).hexdigest(),
            "runtime_manifest_sha256": hashlib.sha256(metadata).hexdigest(), "commit": info["MLXWorkbenchCommit"],
            "version": info["CFBundleShortVersionString"]}


def install_runtime_dmg(input_dir, manifest):
    image = input_dir / "runtime-install.dmg"
    if hashlib.sha256(image.read_bytes()).hexdigest() != manifest["runtime_install_dmg_sha256"]:
        raise RuntimeError("The disk image does not match its recorded digest.")
    app = Path("/Applications/MLX Workbench.app")
    if app.exists() or app.is_symlink():
        raise RuntimeError("Release acceptance requires a base VM without an existing MLX Workbench app.")
    metadata = (input_dir / "runtime-bundle/manifest.json").read_bytes()
    with tempfile.TemporaryDirectory(prefix="workbench-dmg-") as directory:
        mount = Path(directory)
        checked(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(image)])
        try:
            original = runtime_app_identity(mount / "MLX Workbench.app", metadata, manifest["head"])
            checked(["/usr/bin/ditto", str(mount / "MLX Workbench.app"), str(app)])
        finally:
            checked(["/usr/bin/hdiutil", "detach", str(mount)])
    if runtime_app_identity(app, metadata, manifest["head"]) != original:
        raise RuntimeError("The installed app differs from the disk image.")
    return app, original


def validate_test_summary(summary, expected_ui_tests=None):
    if summary.get("result") != "Passed" or summary.get("failedTests", 0) or summary.get("totalTestCount", 0) == 0:
        raise RuntimeError("The result bundle does not contain a successful executed test suite.")
    if expected_ui_tests is not None and (summary.get("passedTests") != expected_ui_tests or summary.get("skippedTests", 0)):
        raise RuntimeError(f"The result bundle did not pass all {expected_ui_tests} required UI tests.")


def reuse_unit_evidence(files, directory):
    directory = Path(directory)
    manifest = json.loads((directory / "source-manifest.json").read_text())
    summary = json.loads((directory / "unit-summary.json").read_text())
    if manifest.get("unit_test") or manifest.get("preflight_only"):
        raise RuntimeError("Focused diagnostics cannot substitute for the complete native unit suite.")
    validate_test_summary(summary)
    # The unit scheme does not compile the separate UI test target. Its
    # sources and this runner can differ; all unit inputs must still match.
    def source(records):
        return {r["path"]: r for r in records if r["path"] not in {"scripts/native_ui_vm.py", "tests/test_native_ui_vm.py"}
                and not r["path"].startswith("mlx-mac/mlx-macUITests/")}
    if source(files) != source(manifest["files"]):
        raise RuntimeError("Native unit evidence does not match the current source snapshot.")
    return {"path": str(directory.resolve()), "summary": summary}


def tracked_files(repo):
    """Include current source and initialized submodules, without Git metadata or caches."""
    output = subprocess.check_output(
        ["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    )
    for raw in output.split(b"\0"):
        if not raw:
            continue
        path = repo / os.fsdecode(raw)
        if path.is_symlink():
            yield path
        elif path.is_dir():
            if (path / ".git").exists():
                yield from tracked_files(path)
        elif path.exists() or path.is_symlink():
            yield path


def snapshot(repo, destination):
    records = []
    for source in sorted(set(tracked_files(repo))):
        relative = source.relative_to(repo)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            resolved = source.resolve(strict=True)
            if not resolved.is_relative_to(repo):
                raise RuntimeError(f"Source link leaves the checkout: {relative}")
            target.symlink_to(os.readlink(source))
            records.append({"path": str(relative), "link": os.readlink(source)})
        else:
            shutil.copy2(source, target)
            records.append({"path": str(relative), "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    return records


def guest(input_dir, output_dir):
    # This check precedes filesystem changes, appearance changes and xcodebuild.
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
    if not model.startswith("VirtualMac"):
        raise RuntimeError("Native UI execution is refused outside a macOS VM.")
    console = subprocess.check_output(["stat", "-f", "%u", "/dev/console"], text=True).strip()
    if os.getuid() == 0 or console != str(os.getuid()):
        raise RuntimeError("Log in to the VM desktop as the test user before running UI tests.")
    manager = subprocess.check_output(["/bin/launchctl", "managername"], text=True).strip()
    print(f"Guest GUI preflight: model={model}, uid={os.getuid()}, console={console}, manager={manager}", flush=True)
    if manager != "Aqua":
        raise RuntimeError("The guest command is outside the test user's Aqua session; no tests were started.")
    input_dir, output_dir = Path(input_dir), Path(output_dir)
    manifest = json.loads((input_dir / "source-manifest.json").read_text())
    output_dir.mkdir(parents=True, exist_ok=True)
    desktop = manifest.get("desktop_size", "1440x1000")
    if desktop not in ("1024x768", "1440x1000", "2048x1280"):
        raise RuntimeError("Unsupported test desktop; no GUI operation was started.")
    width, height = desktop.split("x")
    desktop_environment = dict(os.environ, MLX_WORKBENCH_UI_DESKTOP_WIDTH=width, MLX_WORKBENCH_UI_DESKTOP_HEIGHT=height)
    # macOS can retain a scaled desktop mode independently of Tart's virtual
    # display size. Select the intended logical mode before launching windows.
    display = subprocess.check_output(["/usr/bin/swift", "-e", """
import CoreGraphics
import Foundation
let display = CGMainDisplayID()
let environment = ProcessInfo.processInfo.environment
guard let width = environment["MLX_WORKBENCH_UI_DESKTOP_WIDTH"].flatMap(Int.init),
      let height = environment["MLX_WORKBENCH_UI_DESKTOP_HEIGHT"].flatMap(Int.init) else {
    fatalError("The requested desktop dimensions are missing.")
}
guard let before = CGDisplayCopyDisplayMode(display),
      let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode],
      let target = modes.first(where: { $0.width == width && $0.height == height }) else {
    fatalError("The guest display does not offer the requested desktop mode.")
}
var configuration: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&configuration) == .success,
      let configuration else {
    fatalError("The guest display configuration could not begin.")
}
guard CGConfigureDisplayWithDisplayMode(configuration, display, target, nil) == .success else {
    CGCancelDisplayConfiguration(configuration)
    fatalError("The guest desktop mode could not be configured.")
}
guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success,
      let after = CGDisplayCopyDisplayMode(display),
      after.width == width && after.height == height else {
    fatalError("The guest display did not enter the required desktop mode.")
}
let evidence = ["before": ["width": before.width, "height": before.height],
                "after": ["width": after.width, "height": after.height]]
let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
"""], text=True, timeout=60, env=desktop_environment)
    (output_dir / "display-preflight.json").write_text(display)
    checked(["/usr/bin/open", "-a", "Calculator"], timeout=10)
    probe = subprocess.check_output(["/usr/bin/osascript", "-l", "JavaScript", "-e", """
ObjC.import('AppKit');
const screen = $.NSScreen.mainScreen.frame.size;
const environment = $.NSProcessInfo.processInfo.environment;
const width = Number(ObjC.unwrap(environment.objectForKey('MLX_WORKBENCH_UI_DESKTOP_WIDTH')));
const height = Number(ObjC.unwrap(environment.objectForKey('MLX_WORKBENCH_UI_DESKTOP_HEIGHT')));
if (screen.width !== width || screen.height !== height) {
    throw new Error('The guest desktop did not retain its requested mode. No tests were started.');
}
const app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
const bundle = ObjC.unwrap(app.bundleIdentifier);
if (bundle !== 'com.apple.calculator') {
    throw new Error('Guest Launch Services did not activate Calculator. No tests were started.');
}
JSON.stringify({bundle_id: bundle, pid: app.processIdentifier, width: screen.width, height: screen.height});
"""], text=True, timeout=30, env=desktop_environment)
    (output_dir / "gui-preflight.json").write_text(probe)
    checked(["/usr/sbin/screencapture", "-x", str(output_dir / "guest-preflight.png")], timeout=10)
    if manifest.get("preflight_only"):
        return
    source = input_dir / "source"
    for record in manifest["files"]:
        path = source / record["path"]
        if "sha256" in record and hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            raise RuntimeError(f"Source snapshot changed: {record['path']}")
        if "link" in record and os.readlink(path) != record["link"]:
            raise RuntimeError(f"Source snapshot link changed: {record['path']}")
    checkout = Path.home() / "native-ui" / manifest["run_id"]
    checked(["ditto", str(source), str(checkout)])
    install_uv = None
    if manifest.get("runtime_install_uv_sha256"):
        install_uv = Path.home() / ".local/bin/uv"
        if install_uv.exists() or install_uv.is_symlink():
            raise RuntimeError("Runtime acceptance requires a base VM without an existing user-local uv installation.")
        install_uv.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(input_dir / "runtime-install-uv", install_uv)
        install_uv.chmod(0o755)
        if hashlib.sha256(install_uv.read_bytes()).hexdigest() != manifest["runtime_install_uv_sha256"]:
            raise RuntimeError("The staged uv executable does not match its recorded digest.")
        tool = subprocess.run([str(install_uv), "--version"], capture_output=True, text=True, timeout=15)
        (output_dir / "runtime-install-tool.json").write_text(json.dumps({
            "sha256": manifest["runtime_install_uv_sha256"], "status": tool.returncode,
            "stdout": tool.stdout, "stderr": tool.stderr,
        }, indent=2) + "\n")
        tool.check_returncode()
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    os.chdir(checkout)
    dd = checkout / ".build/native-ui"
    common = ["xcodebuild", "-project", "mlx-mac/mlx-mac.xcodeproj", "-configuration", "Debug",
              "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(dd)]
    if manifest.get("runtime_bundle"):
        payload = input_dir / "runtime-bundle"
        inputs = output_dir / "runtime-inputs.xcfilelist"
        inputs.write_text(str(payload) + "\n")
        common += ["MLX_WORKBENCH_RUNTIME_BUNDLE_ROOT=" + str(payload),
                   "MLX_WORKBENCH_RUNTIME_INPUTS=" + str(inputs)]

    def run(name, command, expected_ui_tests=None):
        print(f"Running {name} inside {model}", flush=True)
        with (output_dir / f"{name}.log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        bundle = output_dir / f"{name}.xcresult"
        if bundle.exists():
            summary = json.loads(subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]
            ))
            (output_dir / f"{name}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            with (output_dir / f"{name}-export.log").open("w") as log:
                subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                                "--output-path", str(output_dir / f"{name}-images")], stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"{name} failed (exit {result.returncode}); see {name}.log. No retry was started.")
        if name == "unit" or expected_ui_tests is not None:
            if not bundle.exists():
                raise RuntimeError(f"{name} did not produce its required result bundle.")
            validate_test_summary(summary, expected_ui_tests)

    unit_selection = [f"-only-testing:{manifest['unit_test']}"] if manifest.get("unit_test") else []
    if manifest.get("ui_test") and not manifest.get("with_unit_tests"):
        print("Focused UI diagnosis: the complete unit gate is not selected", flush=True)
    elif manifest.get("unit_evidence"):
        (output_dir / "unit-evidence.json").write_text(json.dumps(manifest["unit_evidence"], indent=2) + "\n")
        print("Reusing passed complete native unit evidence after source-hash comparison", flush=True)
    else:
        run("unit", common + ["-scheme", "mlx-workbench", "-resultBundlePath", str(output_dir / "unit.xcresult")]
            + unit_selection + ["test"], expected_ui_tests=1 if unit_selection else None)
    if unit_selection:
        return
    ui_common = common
    if manifest.get("runtime_install_uv_sha256"):
        ui_common = common + ["OTHER_SWIFT_FLAGS=$(inherited) -DMLX_WORKBENCH_DISTRIBUTION"]
    run("ui-build", ui_common + ["-scheme", "mlx-workbench-real-data-e2e", "build-for-testing"])
    products = dd / "Build/Products"
    installed_app = None
    installed_identity = None
    if manifest.get("runtime_install_uv_sha256"):
        from runtime_bundle import verify_bundle
        app = products / "Debug/mlx-workbench.app"
        checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        payload = app / "Contents/Resources/Runtime"
        verify_bundle(payload)
        metadata = (payload / "manifest.json").read_bytes()
        if metadata != (input_dir / "runtime-bundle/manifest.json").read_bytes():
            raise RuntimeError("The built application contains a different runtime payload.")
        (output_dir / "runtime-install-build.json").write_text(json.dumps({
            "distribution": True, "binary_sha256": hashlib.sha256((app / "Contents/MacOS/mlx-workbench").read_bytes()).hexdigest(),
            "runtime_manifest_sha256": hashlib.sha256(metadata).hexdigest(),
            "uv_sha256": manifest["runtime_install_uv_sha256"],
        }, indent=2) + "\n")
        if manifest.get("runtime_install_dmg_sha256"):
            installed_app, installed_identity = install_runtime_dmg(input_dir, manifest)
            (output_dir / "runtime-install-artifact.json").write_text(json.dumps({
                **installed_identity, "dmg_sha256": manifest["runtime_install_dmg_sha256"],
                "app_path": str(installed_app), "signature_verified": True,
            }, indent=2) + "\n")
    runfiles = list(products.glob("mlx-workbench-real-data-e2e_*.xctestrun"))
    if len(runfiles) != 1:
        raise RuntimeError("Expected exactly one native UI test runner.")
    template = plistlib.loads(runfiles[0].read_bytes())
    if manifest.get("runtime_bundle"):
        for configuration in template["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                target.setdefault("EnvironmentVariables", {})["MLX_WORKBENCH_RUNTIME_PAYLOAD"] = str(input_dir / "runtime-bundle")
                if manifest.get("runtime_install_uv_sha256"):
                    target["EnvironmentVariables"]["MLX_WORKBENCH_RUNTIME_INSTALL_UV"] = str(install_uv)
                    target["EnvironmentVariables"]["MLX_WORKBENCH_RUNTIME_INSTALL_UV_SHA256"] = manifest["runtime_install_uv_sha256"]
                    if installed_app:
                        target["UITargetAppPath"] = str(installed_app)
                        target["EnvironmentVariables"]["MLX_WORKBENCH_RUNTIME_INSTALL_APP"] = str(installed_app)
                        target["EnvironmentVariables"]["MLX_WORKBENCH_RUNTIME_INSTALL_APP_SHA256"] = installed_identity["binary_sha256"]
    if manifest.get("ui_test"):
        requested = manifest["ui_test"]
        selected_tests = list(dict.fromkeys(requested if isinstance(requested, list) else [requested]))
        for stage in (["before", "after"] if (input_dir / "baseline.app").exists() else ["after"]):
            data = plistlib.loads(plistlib.dumps(template))
            for configuration in data["TestConfigurations"]:
                for target in configuration["TestTargets"]:
                    target.setdefault("EnvironmentVariables", {})["MLX_WORKBENCH_CAPTURE_STAGE"] = stage
                    if stage == "before":
                        baseline = str(input_dir / "baseline.app")
                        target["UITargetAppPath"] = baseline
                        target["DependentProductPaths"] = [baseline if p == "__TESTROOT__/Debug/mlx-workbench.app" else p
                                                          for p in target.get("DependentProductPaths", [])]
            runfile = products / f"ui-focused-{stage}.xctestrun"
            runfile.write_bytes(plistlib.dumps(data))
            name = f"ui-focused-{stage}"
            run(name, ["xcodebuild", "-xctestrun", str(runfile),
                       "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(output_dir / f"{name}.xcresult"),
                       *[f"-only-testing:{test}" for test in selected_tests], "test-without-building"],
                expected_ui_tests=len(selected_tests))
            if manifest.get("runtime_install_uv_sha256") and (checkout / ".venv").exists():
                raise RuntimeError("The packaged install unexpectedly created an environment in the build checkout.")
            if installed_app:
                if runtime_app_identity(installed_app, metadata, manifest["head"]) != installed_identity:
                    raise RuntimeError("The Release app changed during runtime installation.")
                (output_dir / "runtime-install-artifact-after.json").write_text(json.dumps({
                    **installed_identity, "signature_verified": True, "unchanged": True,
                }, indent=2) + "\n")
        return
    stages = ["after"]
    if (input_dir / "baseline.app").exists():
        stages.insert(0, "before")
    for appearance in ["Light", "Dark"]:
        for stage in stages:
            data = plistlib.loads(plistlib.dumps(template))
            for configuration in data["TestConfigurations"]:
                for target in configuration["TestTargets"]:
                    target.setdefault("EnvironmentVariables", {})["MLX_WORKBENCH_CAPTURE_APPEARANCE"] = appearance
                    if stage == "before":
                        baseline = str(input_dir / "baseline.app")
                        target["UITargetAppPath"] = baseline
                        target["DependentProductPaths"] = [baseline if p == "__TESTROOT__/Debug/mlx-workbench.app" else p
                                                           for p in target.get("DependentProductPaths", [])]
            name = f"{stage}-{appearance}"
            runfile = products / f"{name}.xctestrun"
            runfile.write_bytes(plistlib.dumps(data))
            selection = "mlx-workbenchUITests/WorkbenchReviewUITests"
            if stage == "before" or appearance == "Light":
                selection += "/testRouteCaptures"
            run(name, ["xcodebuild", "-xctestrun", str(runfile), "-destination", "platform=macOS,arch=arm64",
                       "-resultBundlePath", str(output_dir / f"{name}.xcresult"), f"-only-testing:{selection}",
                       "test-without-building"], expected_ui_tests=1 if stage == "before" or appearance == "Light" else 25)


def wait_for_guest(tart, vm, running, env, timeout=300):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if running.poll() is not None:
            raise RuntimeError("VM exited before its guest agent became ready; see vm.log.")
        try:
            ready = subprocess.run([tart, "exec", vm, "/usr/bin/true"], env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=5)
            if ready.returncode == 0:
                return
        except subprocess.TimeoutExpired:
            pass
        time.sleep(2)
    raise RuntimeError(f"VM guest agent did not become ready within {timeout} seconds; see vm.log.")


def host(args):
    repo = Path(__file__).resolve().parent.parent
    tart = resolve_tart(repo, args.tart)
    env = dict(os.environ, TART_HOME=str(Path(args.vm_home).resolve()))
    local_vms = subprocess.check_output([tart, "list", "--source", "local", "--quiet"], env=env, text=True).splitlines()
    if args.base_vm not in local_vms:
        raise RuntimeError("The prepared local base VM is unavailable; image provisioning must be explicit.")
    with ExitStack() as leases:
        # Hold referenced unit evidence across pruning and the entire consuming run.
        if args.unit_evidence:
            evidence_run = Path(args.unit_evidence).resolve(strict=True).parent
            if evidence_run.parent == repo / ".build/native-ui/runs":
                descriptor = os.open(evidence_run / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                evidence_lease = leases.enter_context(os.fdopen(descriptor, "w"))
                fcntl.flock(evidence_lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
        with artifact_workspace(repo / ".build/native-ui/runs") as run_dir:
            host_run(args, repo, tart, env, run_dir)


def host_run(args, repo, tart, env, run_dir):
    run_id = run_dir.name
    input_dir, output_dir = run_dir / "input", run_dir / "output"
    files = snapshot(repo, input_dir / "source")
    manifest = {"run_id": run_id, "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                "files": files, "base_vm": args.base_vm, "unit_test": args.unit_test, "ui_test": args.ui_test,
                "with_unit_tests": args.with_unit_tests, "preflight_only": args.preflight_only,
                "desktop_size": args.desktop_size,
                "network": "shared" if args.runtime_install_uv else "host-only"}
    if args.unit_evidence:
        if args.unit_test or args.preflight_only:
            raise RuntimeError("Unit evidence reuse is only available for the complete UI review.")
        manifest["unit_evidence"] = reuse_unit_evidence(files, args.unit_evidence)
    if args.baseline_app:
        baseline = Path(args.baseline_app).resolve()
        checked(["ditto", str(baseline), str(input_dir / "baseline.app")])
        binary = baseline / "Contents/MacOS/mlx-workbench"
        manifest["baseline_binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    if args.runtime_bundle:
        from runtime_bundle import resolve_bundle, verify_bundle
        payload = resolve_bundle(Path(args.runtime_bundle))
        shutil.copytree(payload, input_dir / "runtime-bundle")
        verify_bundle(input_dir / "runtime-bundle")
        manifest["runtime_bundle"] = True
    if args.runtime_install_uv:
        uv = Path(args.runtime_install_uv).resolve(strict=True)
        if not uv.is_file() or not os.access(uv, os.X_OK) or uv.stat().st_size > 128 * 1024 * 1024:
            raise RuntimeError("Supply an existing executable uv binary for isolated runtime acceptance.")
        copied = input_dir / "runtime-install-uv"
        shutil.copy2(uv, copied)
        manifest["runtime_install_uv_sha256"] = hashlib.sha256(copied.read_bytes()).hexdigest()
    if args.runtime_install_dmg:
        disk_image = Path(args.runtime_install_dmg).resolve(strict=True)
        if not disk_image.is_file() or disk_image.suffix != ".dmg" or disk_image.stat().st_size > 512 * 1024 * 1024:
            raise RuntimeError("Supply an existing DMG no larger than 512 MiB for Release installation acceptance.")
        copied = input_dir / "runtime-install.dmg"
        shutil.copyfile(disk_image, copied)
        manifest["runtime_install_dmg_sha256"] = hashlib.sha256(copied.read_bytes()).hexdigest()
    (input_dir / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    output_dir.mkdir(parents=True)
    shutil.copyfile(input_dir / "source-manifest.json", output_dir / "source-manifest.json")
    vm = run_id
    running = None
    cloned = False
    def tart_run(*command, **kwargs):
        return checked([tart, *command], env=env, **kwargs)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        tart_run("clone", args.base_vm, vm)
        cloned = True
        (run_dir / ".vm-active").touch()
        tart_run("set", vm, "--cpu", "4", "--memory", "8192", "--display", args.desktop_size, "--no-display-refit")
        log = (run_dir / "vm.log").open("w")
        network = [] if args.runtime_install_uv else ["--net-host"]
        running = subprocess.Popen([tart, "run", "--no-graphics", "--no-audio", "--no-clipboard", "--no-usb-accessories",
                                    *network, "--dir", f"review-input:{input_dir}:ro",
                                    "--dir", f"review-output:{output_dir}", vm], env=env, stdout=log, stderr=subprocess.STDOUT)
        wait_for_guest(tart, vm, running, env)
        print(f"Artifacts: {output_dir}", flush=True)
        tart_run("exec", vm, "/usr/bin/python3", "/Volumes/My Shared Files/review-input/source/scripts/native_ui_vm.py",
                 "--guest", "/Volumes/My Shared Files/review-input", "/Volumes/My Shared Files/review-output")
    finally:
        if running is not None and running.poll() is None:
            subprocess.run([tart, "stop", vm], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                running.wait(timeout=20)
            except subprocess.TimeoutExpired:
                running.terminate()
                running.wait(timeout=10)
        if cloned:
            subprocess.run([tart, "delete", vm], env=env, check=True)
            (run_dir / ".vm-active").unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-vm", help="Prepared local Tart VM with Xcode, an active desktop and the guest agent")
    parser.add_argument("--tart", help="Path to the Tart executable")
    parser.add_argument("--vm-home", default=str(Path(__file__).resolve().parent.parent / ".build/native-ui-vms"))
    parser.add_argument("--baseline-app", help="Optional preserved app for matching before captures")
    parser.add_argument("--runtime-bundle", help="Verified source payload to include before normal app code signing")
    parser.add_argument("--runtime-install-uv", help="Existing uv binary for opt-in packaged installation; downloads Python and runtime packages only inside the VM")
    parser.add_argument("--runtime-install-dmg", help="Existing DMG built from this revision; copy its app into the VM and run the packaged installation test against that artifact")
    parser.add_argument("--desktop-size", choices=("1024x768", "1440x1000", "2048x1280"), default="1440x1000",
                        help="Configure the guest desktop before launching the UI test runner")
    parser.add_argument("--unit-test", help="Run only this XCTest identifier for failure diagnosis; no full-suite or UI acceptance")
    parser.add_argument("--ui-test", action="append", help="Run an exact UI test for scoped failure diagnosis; repeat for multiple cases. No complete UI-suite acceptance")
    parser.add_argument("--with-unit-tests", action="store_true", help="Run the complete native unit gate before the selected UI test")
    parser.add_argument("--preflight-only", action="store_true", help="Check the guest GUI session without building or running tests")
    parser.add_argument("--unit-evidence", help="Reuse a complete passed native unit run only when its source inputs match")
    parser.add_argument("--prune-only", action="store_true", help="Prune managed test artifacts without starting a VM")
    parser.add_argument("--dry-run", action="store_true", help="With --prune-only, report eligible artifact removals without deleting evidence")
    parser.add_argument("--guest", nargs=2, metavar=("INPUT", "OUTPUT"), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.dry_run and not args.prune_only:
        parser.error("--dry-run requires --prune-only")
    if args.runtime_install_dmg and (not args.runtime_install_uv or args.baseline_app):
        parser.error("--runtime-install-dmg requires the explicit runtime installation route without --baseline-app")
    if args.runtime_install_uv and (not args.runtime_bundle or args.ui_test != [RUNTIME_INSTALL_TEST] or args.unit_test or args.preflight_only):
        parser.error("--runtime-install-uv requires --runtime-bundle and the packaged-runtime installation UI test")
    if args.with_unit_tests and (not args.ui_test or args.unit_test or args.preflight_only):
        parser.error("--with-unit-tests requires --ui-test without --unit-test or --preflight-only")
    if args.ui_test and args.unit_test:
        parser.error("Select either --ui-test or --unit-test")
    if args.prune_only:
        if args.guest or args.base_vm or args.ui_test or args.unit_test:
            parser.error("--prune-only cannot be combined with a test run")
        report = prune_artifacts(Path(__file__).resolve().parent.parent / ".build/native-ui/runs", dry_run=args.dry_run)
        print(json.dumps(report, indent=2))
        if report["busy"]:
            parser.exit(3, "Another artifact cleanup is active; no cleanup was performed.\n")
    elif args.guest:
        guest(*args.guest)
    elif not args.base_vm:
        parser.error("--base-vm is required; host-desktop testing is not supported")
    else:
        host(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        print(f"Native UI tests stopped: {error}", file=sys.stderr)
        sys.exit(1)
