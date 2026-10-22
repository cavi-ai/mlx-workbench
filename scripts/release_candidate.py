"""Validate a signed disk image through the installed-build update path."""

import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
from urllib.parse import quote
import uuid


TEST = "mlx-workbenchTests/ReleaseUpdaterTests/testLiveInstallFromANotarizedReleaseDiskImage"


def validate_summary(summary):
    expected = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    if any(summary.get(key) != value for key, value in expected.items()):
        raise ValueError("Candidate acceptance must run and pass without skipped or failed tests")


def file_digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


@contextmanager
def serve_artifact(path):
    route = "/" + quote(path.name)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != route:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(path.stat().st_size))
            self.end_headers()
            with path.open("rb") as source:
                shutil.copyfileobj(source, self.wfile)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}{route}"
        finally:
            server.shutdown()
            thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--derived-data", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    subprocess.run(["git", "diff", "--quiet", "HEAD"], cwd=repo, check=True, timeout=10)
    if not args.dmg.is_absolute() or args.dmg.is_symlink() or not args.dmg.is_file():
        parser.error("--dmg must be an absolute path to a regular disk image")
    dmg = args.dmg.resolve(strict=True)
    output = args.output or repo / ".run/release-candidate" / uuid.uuid4().hex
    output.mkdir(parents=True, exist_ok=False)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True, timeout=10).strip()
    engine = subprocess.check_output(["git", "rev-parse", "HEAD:vendor/mlx-agent"], cwd=repo, text=True, timeout=10).strip()
    version = subprocess.check_output([os.sys.executable, "-c", "from mlx_workbench import __version__; print(__version__)"],
                                      cwd=repo, text=True, timeout=10).strip()
    digest = file_digest(dmg)
    result = output / "candidate.xcresult"
    environment = dict(os.environ,
                       TEST_RUNNER_MLX_WORKBENCH_RELEASE_DMG=str(dmg),
                       TEST_RUNNER_MLX_WORKBENCH_RELEASE_EXPECTED_COMMIT=commit[:12],
                       TEST_RUNNER_MLX_WORKBENCH_RELEASE_EXPECTED_ENGINE=engine,
                       TEST_RUNNER_MLX_WORKBENCH_RELEASE_EXPECTED_VERSION=version)
    command = ["xcodebuild", "-project", "mlx-mac/mlx-mac.xcodeproj", "-scheme", "mlx-workbench",
               "-configuration", "Debug", "-destination", "platform=macOS",
               "-derivedDataPath", str(args.derived_data or repo / ".run/swift-build"),
               "-resultBundlePath", str(result), "-only-testing:" + TEST, "test"]
    with serve_artifact(dmg) as url, (output / "test.log").open("w") as log:
        environment["TEST_RUNNER_MLX_WORKBENCH_RELEASE_DMG_URL"] = url
        with subprocess.Popen(command, cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT,
                              start_new_session=True) as process:
            try:
                status = process.wait(timeout=900)
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                raise
        if status:
            with (output / "test.log").open("rb") as failure:
                failure.seek(max(0, failure.seek(0, os.SEEK_END) - 16000))
                print(failure.read().decode("utf-8", errors="replace"), file=os.sys.stderr)
            raise RuntimeError(f"Candidate acceptance failed; see {output / 'test.log'}")
    summary = json.loads(subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
        text=True, timeout=30))
    validate_summary(summary)
    # A disk image changed during the run cannot acquire acceptance evidence.
    if file_digest(dmg) != digest:
        raise ValueError("The candidate disk image changed during acceptance")
    counters = {key: summary[key] for key in ("result", "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
    receipt = {"schema": 1, "commit": commit, "engine_revision": engine, "version": version, "dmg_sha256": digest,
               "test": TEST, "summary": counters}
    (output / "acceptance.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(output / "acceptance.json")


if __name__ == "__main__":
    main()
