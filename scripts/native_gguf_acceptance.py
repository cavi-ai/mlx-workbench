#!/usr/bin/env python3
"""Run the opt-in native GGUF-to-Run acceptance harness."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import shutil
import subprocess
import sys
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


def load_manifest(manifest_path: str) -> RuntimeManifest:
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
    if source_path.suffix.lower() != ".gguf" or not source_path.is_file():
        raise ManifestError("source_path must identify an existing regular .gguf file")
    if source_path.stat().st_size >= MAX_SOURCE_BYTES:
        raise ManifestError(f"source_path must be smaller than {MAX_SOURCE_BYTES} bytes")

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

    raw_roots = config.get("gguf_roots")
    if not isinstance(raw_roots, list) or not raw_roots:
        raise ManifestError("config gguf_roots must explicitly list the source root")
    if not all(isinstance(root, str) and root.strip() for root in raw_roots):
        raise ManifestError("config gguf_roots must contain non-empty path strings")
    roots = [_absolute_path(root, "config gguf_roots entry") for root in raw_roots]
    if not _inside(source_path, roots):
        raise ManifestError("source_path must be inside an explicitly configured gguf_roots entry")

    evidence_root = _absolute_path(values["evidence_root"], "evidence_root")
    if _inside(evidence_root, roots):
        raise ManifestError("evidence_root must be outside configured gguf_roots")

    return RuntimeManifest(
        path=path,
        source_path=source_path,
        model_query=values["model_query"].strip(),
        agent_home=agent_home,
        config_path=config_path,
        evidence_root=evidence_root,
    )


def create_evidence_directory(root: Path) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise ManifestError(f"cannot create evidence_root {root}: {error}") from error
    for suffix in range(1_000):
        discriminator = f"-{suffix}" if suffix else ""
        candidate = root / f"native-gguf-{timestamp}-{os.getpid()}{discriminator}"
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


def xcodebuild_command(xcodebuild: str, evidence: Path) -> list[str]:
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
        f"-only-testing:{ONLY_TEST}",
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


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="absolute path to the local runtime manifest")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        manifest = load_manifest(args.manifest)
        evidence = create_evidence_directory(manifest.evidence_root)
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
    command = xcodebuild_command(xcodebuild, evidence)
    try:
        exit_code = run_xcodebuild(command, environment, evidence / "xcodebuild.log")
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
