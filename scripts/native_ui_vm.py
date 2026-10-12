#!/usr/bin/env python3
"""Run native UI tests on a disposable macOS VM, never on the host desktop."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid


def checked(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


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
    checked(["/usr/bin/open", "-a", "Calculator"], timeout=10)
    probe = subprocess.check_output(["/usr/bin/osascript", "-l", "JavaScript", "-e", """
ObjC.import('AppKit');
const app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
const bundle = ObjC.unwrap(app.bundleIdentifier);
if (bundle !== 'com.apple.calculator') {
    throw new Error('Guest Launch Services did not activate Calculator. No tests were started.');
}
JSON.stringify({bundle_id: bundle, pid: app.processIdentifier});
"""], text=True, timeout=30)
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
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    os.chdir(checkout)
    dd = checkout / ".build/native-ui"
    common = ["xcodebuild", "-project", "mlx-mac/mlx-mac.xcodeproj", "-configuration", "Debug",
              "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(dd)]

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
    run("ui-build", common + ["-scheme", "mlx-workbench-real-data-e2e", "build-for-testing"])
    products = dd / "Build/Products"
    runfiles = list(products.glob("mlx-workbench-real-data-e2e_*.xctestrun"))
    if len(runfiles) != 1:
        raise RuntimeError("Expected exactly one native UI test runner.")
    template = plistlib.loads(runfiles[0].read_bytes())
    if manifest.get("ui_test"):
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
                       f"-only-testing:{manifest['ui_test']}", "test-without-building"], expected_ui_tests=1)
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
                       "test-without-building"], expected_ui_tests=1 if stage == "before" or appearance == "Light" else 12)


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
    tart = args.tart or shutil.which("tart")
    if not tart:
        bundled = repo / ".build/native-ui-tools/tart.app/Contents/MacOS/tart"
        if bundled.is_file():
            tart = str(bundled)
        else:
            raise RuntimeError("Tart is required. See mlx-mac/README.md#isolated-native-ui-tests.")
    env = dict(os.environ, TART_HOME=str(Path(args.vm_home).resolve()))
    local_vms = subprocess.check_output([tart, "list", "--source", "local", "--quiet"], env=env, text=True).splitlines()
    if args.base_vm not in local_vms:
        raise RuntimeError("The prepared local base VM is unavailable; image provisioning must be explicit.")
    run_id = f"ui-{uuid.uuid4().hex[:12]}"
    run_dir = repo / ".build/native-ui/runs" / run_id
    input_dir, output_dir = run_dir / "input", run_dir / "output"
    files = snapshot(repo, input_dir / "source")
    manifest = {"run_id": run_id, "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                "files": files, "base_vm": args.base_vm, "unit_test": args.unit_test, "ui_test": args.ui_test,
                "with_unit_tests": args.with_unit_tests, "preflight_only": args.preflight_only}
    if args.unit_evidence:
        if args.unit_test or args.preflight_only:
            raise RuntimeError("Unit evidence reuse is only available for the complete UI review.")
        manifest["unit_evidence"] = reuse_unit_evidence(files, args.unit_evidence)
    if args.baseline_app:
        baseline = Path(args.baseline_app).resolve()
        checked(["ditto", str(baseline), str(input_dir / "baseline.app")])
        binary = baseline / "Contents/MacOS/mlx-workbench"
        manifest["baseline_binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    (input_dir / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    output_dir.mkdir(parents=True)
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
        tart_run("set", vm, "--cpu", "4", "--memory", "8192", "--display", "1440x1000", "--no-display-refit")
        log = (run_dir / "vm.log").open("w")
        running = subprocess.Popen([tart, "run", "--no-graphics", "--no-audio", "--no-clipboard", "--no-usb-accessories",
                                    "--net-host", "--dir", f"review-input:{input_dir}:ro",
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-vm", help="Prepared local Tart VM with Xcode, an active desktop and the guest agent")
    parser.add_argument("--tart", help="Path to the Tart executable")
    parser.add_argument("--vm-home", default=str(Path(__file__).resolve().parent.parent / ".build/native-ui-vms"))
    parser.add_argument("--baseline-app", help="Optional preserved app for matching before captures")
    parser.add_argument("--unit-test", help="Run only this XCTest identifier for failure diagnosis; no full-suite or UI acceptance")
    parser.add_argument("--ui-test", help="Run one UI test for scoped failure diagnosis; no complete UI-suite acceptance")
    parser.add_argument("--with-unit-tests", action="store_true", help="Run the complete native unit gate before the selected UI test")
    parser.add_argument("--preflight-only", action="store_true", help="Check the guest GUI session without building or running tests")
    parser.add_argument("--unit-evidence", help="Reuse a complete passed native unit run only when its source inputs match")
    parser.add_argument("--guest", nargs=2, metavar=("INPUT", "OUTPUT"), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.with_unit_tests and (not args.ui_test or args.unit_test or args.preflight_only):
        parser.error("--with-unit-tests requires --ui-test without --unit-test or --preflight-only")
    if args.ui_test and args.unit_test:
        parser.error("Select either --ui-test or --unit-test")
    if args.guest:
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
