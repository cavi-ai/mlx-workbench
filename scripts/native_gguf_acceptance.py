#!/usr/bin/env python3
"""Run opt-in native acceptance for an allowlisted local model."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import shutil
import subprocess
import sys
import secrets
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler
from socketserver import TCPServer
from dataclasses import dataclass
from pathlib import Path
from typing import Any


EXIT_MANIFEST_INVALID = 2
EXIT_PREREQUISITE = 3
EXIT_ACCEPTANCE_FAILED = 4
MAX_SOURCE_BYTES = 29_000_000_000
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
REQUIRED_KEYS = {
    "source_path",
    "model_query",
    "agent_home",
    "config_path",
    "evidence_root",
}
ONLY_TEST = (
    "mlx-workbenchUITests/GGUFToRunRealDataUITests/"
    "testRealGGUFToRunningMLXGoldenPath"
)
MLX_ONLY_TEST = (
    "mlx-workbenchUITests/GGUFToRunRealDataUITests/"
    "testRealMLXToRunningGoldenPath"
)
TRAINING_ONLY_TEST = "mlx-workbenchUITests/GGUFToRunRealDataUITests/testRealMLXTrainingAndEvaluation"


class ManifestError(ValueError):
    pass


@dataclass(frozen=True)
class RuntimeManifest:
    path: Path
    source_path: Path
    model_query: str
    agent_home: Path
    config_path: Path
    evidence_root: Path


def _absolute_path(value: str, key: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise ManifestError(f"{key} must be an absolute path")
    return path.resolve()


def _read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ManifestError(f"{label} does not exist: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"{label} is not readable JSON: {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"{label} must contain a JSON object")
    return value


def _inside(path: Path, roots: list[Path]) -> bool:
    return any(path == root or path.is_relative_to(root) for root in roots)


def load_manifest(manifest_path: str, source_format: str = "gguf") -> RuntimeManifest:
    raw_path = Path(manifest_path)
    if not raw_path.is_absolute():
        raise ManifestError("manifest path must be absolute")
    path = raw_path.resolve()
    values = _read_object(path, "manifest")

    missing = sorted(REQUIRED_KEYS - values.keys())
    if missing:
        raise ManifestError(f"missing required keys: {', '.join(missing)}")
    unknown = sorted(values.keys() - REQUIRED_KEYS)
    if unknown:
        raise ManifestError(f"unknown keys: {', '.join(unknown)}")
    for key in sorted(REQUIRED_KEYS):
        if not isinstance(values[key], str) or not values[key].strip():
            raise ManifestError(f"{key} must be a non-empty string")
        if "$(" in values[key]:
            raise ManifestError(f"{key} contains an unexpanded placeholder")

    source_path = _absolute_path(values["source_path"], "source_path")
    if source_format == "gguf":
        if source_path.suffix.lower() != ".gguf" or not source_path.is_file():
            raise ManifestError("source_path must identify an existing regular .gguf file")
        if source_path.stat().st_size >= MAX_SOURCE_BYTES:
            raise ManifestError(f"source_path must be smaller than {MAX_SOURCE_BYTES} bytes")
    elif not source_path.is_dir():
        raise ManifestError("MLX source_path must identify an existing model directory")

    agent_home = _absolute_path(values["agent_home"], "agent_home")
    agent_cli = agent_home / "scripts" / "mlx-agent"
    if not agent_cli.is_file() or not os.access(agent_cli, os.X_OK):
        raise ManifestError(f"agent_home must contain executable scripts/mlx-agent: {agent_home}")

    config_path = _absolute_path(values["config_path"], "config_path")
    config = _read_object(config_path, "config_path")
    configured_agent = config.get("mlx_agent_path")
    if configured_agent is not None and not isinstance(configured_agent, str):
        raise ManifestError("config mlx_agent_path must be a path string when present")
    if isinstance(configured_agent, str) and configured_agent.strip():
        configured_agent_path = _absolute_path(
            os.path.expanduser(configured_agent.strip()),
            "config mlx_agent_path",
        )
        if configured_agent_path != agent_home:
            raise ManifestError("config mlx_agent_path must match manifest agent_home")
    host = config.get("host", "127.0.0.1") or "127.0.0.1"
    if not isinstance(host, str) or host.strip() not in LOOPBACK_HOSTS:
        raise ManifestError("config host must be loopback-only (127.0.0.1, localhost, or ::1)")

    root_key = "mlx_roots" if source_format == "mlx" else "gguf_roots"
    raw_roots = config.get(root_key)
    if not isinstance(raw_roots, list) or not raw_roots:
        raise ManifestError(f"config {root_key} must explicitly list the source root")
    if not all(isinstance(root, str) and root.strip() for root in raw_roots):
        raise ManifestError(f"config {root_key} must contain non-empty path strings")
    roots = [_absolute_path(root, f"config {root_key} entry") for root in raw_roots]
    if not _inside(source_path, roots):
        raise ManifestError(f"source_path must be inside an explicitly configured {root_key} entry")

    if source_format == "mlx":
        weights = list(source_path.glob("*.safetensors"))
        members = [source_path / "config.json", *weights]
        if not weights or any(not member.is_file() or not _inside(member.resolve(), roots) for member in members):
            raise ManifestError("MLX source requires config.json and safetensors weights inside configured mlx_roots")
        _read_object(source_path / "config.json", "MLX source config")
        if any(member.stat().st_size == 0 for member in members) or sum(member.stat().st_size for member in members) >= MAX_SOURCE_BYTES:
            raise ManifestError(f"MLX source must be nonempty and smaller than {MAX_SOURCE_BYTES} bytes")

    evidence_root = _absolute_path(values["evidence_root"], "evidence_root")
    if _inside(evidence_root, roots):
        raise ManifestError(f"evidence_root must be outside configured {root_key}")

    return RuntimeManifest(
        path=path,
        source_path=source_path,
        model_query=values["model_query"].strip(),
        agent_home=agent_home,
        config_path=config_path,
        evidence_root=evidence_root,
    )


def create_evidence_directory(root: Path, source_format: str = "gguf") -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise ManifestError(f"cannot create evidence_root {root}: {error}") from error
    for suffix in range(1_000):
        discriminator = f"-{suffix}" if suffix else ""
        candidate = root / f"native-{source_format}-{timestamp}-{os.getpid()}{discriminator}"
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            continue
        except OSError as error:
            raise ManifestError(f"cannot create evidence directory under {root}: {error}") from error
    raise ManifestError(f"could not allocate a unique evidence directory under {root}")


def write_outcome(
    evidence: Path,
    *,
    classification: str,
    xcodebuild_exit_code: int | None,
    detail: str,
) -> None:
    payload = {
        "classification": classification,
        "detail": detail,
        "xcodebuild_exit_code": xcodebuild_exit_code,
    }
    destination = evidence / "outcome.json"
    temporary = evidence / "outcome.json.tmp"
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(destination)


def training_repo(manifest: RuntimeManifest) -> str:
    source = manifest.source_path
    parts = source.parent.parent.name.split("--")
    if source.parent.name != "snapshots" or len(parts) != 3 or parts[0] != "models" or not all(parts[1:]):
        raise ManifestError("training source must be a Hugging Face cache snapshot")
    try:
        revision = (source.parent.parent / "refs/main").read_text().strip()
    except OSError as error:
        raise ManifestError("training source requires a readable cached main revision") from error
    if revision != source.name:
        raise ManifestError("training source must match the cache's current main revision")
    return "/".join(parts[1:])


def cleanup_training(manifest: RuntimeManifest, environment: dict[str, str]) -> None:
    """Stop only a running job at this acceptance run's exact output path."""
    command = [environment.get("MLX_WORKBENCH_PYTHON", sys.executable),
               str(manifest.agent_home / "scripts/mlx-agent")]
    receipts = str(Path.home() / "Library/Application Support/mlx-workbench")
    result = subprocess.run(command + ["lora", "status", "--receipts-dir", receipts, "--json"],
                            env=environment, capture_output=True, timeout=30, check=True)
    payload = json.loads(result.stdout)
    if payload.get("status") != "ok" or not isinstance(payload.get("data", {}).get("jobs"), list):
        raise RuntimeError("Training cleanup could not read authoritative job status")
    output = str(Path(environment["TASK6_TRAINING_ROOT"]) / "adapter")
    for job in payload["data"]["jobs"]:
        if job.get("out") == output and job.get("repo") == environment["TASK6_TRAINING_REPO"] and job.get("state") == "running":
            subprocess.run(command + ["lora", "stop", "--pid", str(job["pid"]), "--receipts-dir", receipts, "--json"],
                           env=environment, capture_output=True, timeout=30, check=True)


def xcodebuild_command(xcodebuild: str, evidence: Path, source_format: str = "gguf", workflow: str = "serving") -> list[str]:
    return [
        xcodebuild,
        "-project",
        "mlx-mac/mlx-mac.xcodeproj",
        "-scheme",
        "mlx-workbench-real-data-e2e",
        "-configuration",
        "Debug",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(evidence / "DerivedData"),
        "-resultBundlePath",
        str(evidence / "result.xcresult"),
        "-parallel-testing-enabled",
        "NO",
        f"-only-testing:{TRAINING_ONLY_TEST if workflow == 'training' else MLX_ONLY_TEST if source_format == 'mlx' else ONLY_TEST}",
        "test",
    ]


def run_xcodebuild(command: list[str], environment: dict[str, str], log_path: Path) -> int:
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            log.write(line)
        return process.wait()


@contextmanager
def runtime_status_bridge(manifest: RuntimeManifest, environment: dict[str, str], workflow: str = "serving"):
    """Query real process status outside XCTest's sandbox; accept no commands."""
    route = "/status/" + secrets.token_urlsafe(32)
    receipts = Path.home() / "Library/Application Support/mlx-workbench"
    operation = {"serving": "serve", "training": "lora"}[workflow]
    command = [environment.get("MLX_WORKBENCH_PYTHON", sys.executable),
               str(manifest.agent_home / "scripts/mlx-agent"), operation, "status",
               "--receipts-dir", str(receipts), "--json"]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != route:
                self.send_error(404)
                return
            try:
                result = subprocess.run(command, env=environment, capture_output=True, timeout=30, check=True)
                payload = json.loads(result.stdout)
                if not isinstance(payload, dict) or payload.get("status") != "ok":
                    raise ValueError("status query did not succeed")
            except (OSError, subprocess.SubprocessError, ValueError):
                self.send_error(503, "Runtime status unavailable")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(result.stdout)))
            self.end_headers()
            self.wfile.write(result.stdout)

        def log_message(self, *_args):
            pass

    # HTTPServer resolves a hostname during binding. This numeric loopback
    # endpoint needs no DNS and uses only the HTTP request handler.
    with TCPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, name="acceptance-runtime-status")
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_address[1]}{route}"
        finally:
            server.shutdown()
            thread.join()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="absolute path to the local runtime manifest")
    parser.add_argument("--source-format", choices=("gguf", "mlx"), default="gguf")
    parser.add_argument("--workflow", choices=("serving", "training"), default="serving")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.workflow == "training" and args.source_format != "mlx":
            raise ManifestError("training acceptance requires --source-format mlx")
        manifest = load_manifest(args.manifest, args.source_format)
        repo = training_repo(manifest) if args.workflow == "training" else None
        evidence = create_evidence_directory(manifest.evidence_root, "training" if repo else args.source_format)
    except ManifestError as error:
        print(f"manifest-invalid: {error}", file=sys.stderr)
        return EXIT_MANIFEST_INVALID

    print(f"evidence directory: {evidence}", flush=True)

    if platform.system() != "Darwin" or platform.machine() != "arm64":
        detail = f"requires Apple Silicon macOS; got {platform.system()}/{platform.machine()}"
        write_outcome(
            evidence,
            classification="prerequisite-unavailable",
            xcodebuild_exit_code=None,
            detail=detail,
        )
        print(f"prerequisite-unavailable: {detail}", file=sys.stderr)
        return EXIT_PREREQUISITE

    xcodebuild = shutil.which("xcodebuild")
    if xcodebuild is None:
        detail = "xcodebuild is not available on PATH"
        write_outcome(
            evidence,
            classification="prerequisite-unavailable",
            xcodebuild_exit_code=None,
            detail=detail,
        )
        print(f"prerequisite-unavailable: {detail}", file=sys.stderr)
        return EXIT_PREREQUISITE

    environment = dict(os.environ)
    if repo:
        environment.update(TASK6_TRAINING_REPO=repo, HF_HUB_CACHE=str(manifest.source_path.parents[2]),
                           TASK6_TRAINING_ROOT=str(evidence), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
        dataset = evidence / "dataset"
        dataset.mkdir()
        for split, text in (("train", "The morning sky is blue."), ("valid", "The evening sky is dark.")):
            (dataset / f"{split}.jsonl").write_text(json.dumps({"text": text}) + "\n")
    environment.update(
        {
            "TASK6_RUNTIME_MANIFEST": str(manifest.path),
            "TASK6_SOURCE_PATH": str(manifest.source_path),
            "TASK6_MODEL_QUERY": manifest.model_query,
            "TASK6_AGENT_HOME": str(manifest.agent_home),
            "TASK6_CONFIG_PATH": str(manifest.config_path),
            "TASK6_EVIDENCE_DIR": str(evidence),
        }
    )
    # xcodebuild forwards TEST_RUNNER_* variables into its test process.
    for key in ("TASK6_RUNTIME_MANIFEST", "TASK6_SOURCE_PATH", "TASK6_MODEL_QUERY", "TASK6_AGENT_HOME",
                "TASK6_CONFIG_PATH", "TASK6_EVIDENCE_DIR", "MLX_WORKBENCH_PYTHON", "HF_HUB_OFFLINE",
                "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "TASK6_TRAINING_REPO", "TASK6_TRAINING_ROOT", "HF_HUB_CACHE"):
        if key in environment:
            environment[f"TEST_RUNNER_{key}"] = environment[key]
    command = xcodebuild_command(xcodebuild, evidence, args.source_format, args.workflow)
    try:
        with runtime_status_bridge(manifest, environment, args.workflow) as status_url:
            environment["TEST_RUNNER_TASK6_STATUS_URL"] = status_url
            try:
                exit_code = run_xcodebuild(command, environment, evidence / "xcodebuild.log")
            finally:
                if repo:
                    cleanup_training(manifest, environment)
    except (subprocess.SubprocessError, RuntimeError, ValueError) as error:
        write_outcome(evidence, classification="acceptance-failed", xcodebuild_exit_code=None,
                      detail=f"runtime status or cleanup failed: {error}")
        return EXIT_ACCEPTANCE_FAILED
    except OSError as error:
        detail = f"could not launch xcodebuild: {error}"
        write_outcome(
            evidence,
            classification="prerequisite-unavailable",
            xcodebuild_exit_code=None,
            detail=detail,
        )
        print(f"prerequisite-unavailable: {detail}", file=sys.stderr)
        return EXIT_PREREQUISITE

    if exit_code != 0:
        write_outcome(
            evidence,
            classification="acceptance-failed",
            xcodebuild_exit_code=exit_code,
            detail="inspect xcodebuild.log and result.xcresult to classify the failing assertion or infrastructure error",
        )
        print(f"acceptance-failed: xcodebuild exited {exit_code}; evidence directory: {evidence}", file=sys.stderr)
        return EXIT_ACCEPTANCE_FAILED

    try:
        summary = json.loads(subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(evidence / "result.xcresult")],
            text=True, stderr=subprocess.PIPE, timeout=30,
        ))
        (evidence / "test-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        if summary.get("result") != "Passed" or summary.get("passedTests") != 1 or summary.get("skippedTests", 0) or summary.get("failedTests", 0):
            raise ValueError("the selected native test must execute and pass without skips")
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        write_outcome(evidence, classification="acceptance-failed", xcodebuild_exit_code=0, detail=str(error))
        print(f"acceptance-failed: {error}; evidence directory: {evidence}", file=sys.stderr)
        return EXIT_ACCEPTANCE_FAILED

    write_outcome(
        evidence,
        classification="passed",
        xcodebuild_exit_code=0,
        detail="the configured real-data UI acceptance test passed",
    )
    print(f"acceptance passed; evidence directory: {evidence}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
