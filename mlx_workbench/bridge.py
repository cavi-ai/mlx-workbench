"""Subprocess bridge to the vendored mlx-agent CLI.

This app owns no conversion or discovery logic. It locates ``scripts/mlx-agent``
in an mlx-agent checkout, runs it with ``--json``, and reads the result
envelope back. Nothing is imported from mlx-agent, so the two repositories
stay independently versioned.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


CLI_RELATIVE = Path("scripts") / "mlx-agent"
DEFAULT_TIMEOUT = 300
SCOUT_TIMEOUT = 600
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_LOG_BYTES = 64 * 1024


class BridgeError(RuntimeError):
    """A classified failure to reach or run the agent CLI."""

    def __init__(self, code, message, remediation):
        super().__init__(message)
        self.code = code
        self.remediation = remediation

    def to_dict(self):
        return {
            "code": self.code,
            "message": str(self),
            "remediation": self.remediation,
        }


def cli_script(agent_path):
    """Resolve the mlx-agent CLI entry point inside a checkout."""
    if not agent_path:
        raise BridgeError(
            "agent_not_configured",
            "No mlx-agent checkout is configured.",
            "Clone with --recurse-submodules, or set mlx_agent_path / MLX_AGENT_HOME.",
        )
    script = Path(agent_path).expanduser() / CLI_RELATIVE
    if not script.is_file():
        raise BridgeError(
            "agent_not_found",
            "No mlx-agent CLI at {0}.".format(script),
            "Run `git submodule update --init --recursive`, or point mlx_agent_path "
            "at an mlx-agent checkout that contains scripts/mlx-agent.",
        )
    return script


def agent_health(agent_path):
    """Return a small status dict for startup / Settings, never raises."""
    if not agent_path:
        return {
            "ok": False,
            "path": "",
            "cli": "",
            "message": "No mlx-agent checkout configured.",
        }
    root = Path(agent_path).expanduser()
    script = root / CLI_RELATIVE
    if not script.is_file():
        return {
            "ok": False,
            "path": str(root),
            "cli": str(script),
            "message": "scripts/mlx-agent is missing (init the vendor submodule?).",
        }
    return {
        "ok": True,
        "path": str(root),
        "cli": str(script),
        "message": "mlx-agent CLI ready.",
    }


def run(agent_path, argv, timeout=DEFAULT_TIMEOUT, runner=None):
    """Run one mlx-agent subcommand and return its parsed result envelope."""
    script = cli_script(agent_path)
    command = [sys.executable, str(script)] + [str(item) for item in argv]
    if "--json" not in command:
        command.append("--json")
    execute = runner or _default_runner
    try:
        completed = execute(command, timeout)
    except subprocess.TimeoutExpired as error:
        raise BridgeError(
            "skill_timeout",
            "The agent did not finish within {0}s.".format(timeout),
            "Narrow the request (for example discover --fast), or raise the timeout.",
        ) from error
    except OSError as error:
        raise BridgeError(
            "skill_unavailable",
            "The agent could not be started: {0}".format(error),
            "Check that python3 and the mlx-agent checkout are both readable.",
        ) from error
    stdout = completed.get("stdout") or ""
    if len(stdout) > MAX_OUTPUT_BYTES:
        raise BridgeError(
            "skill_output_too_large",
            "The agent returned more output than this app will buffer.",
            "Narrow roots, lower --limit, or use --fast for discovery.",
        )
    try:
        payload = json.loads(stdout)
    except ValueError as error:
        detail = (completed.get("stderr") or stdout or "").strip()[:400]
        raise BridgeError(
            "skill_output_unreadable",
            "The agent did not return JSON: {0}".format(detail or error),
            "Run the same command by hand in the mlx-agent checkout to see the failure.",
        ) from error
    if not isinstance(payload, dict) or "status" not in payload:
        raise BridgeError(
            "skill_output_unreadable",
            "The agent returned an unexpected payload.",
            "Check that the mlx-agent checkout is up to date.",
        )
    return payload


def unwrap(envelope):
    """Return the envelope's data, or raise its classified error."""
    if envelope.get("status") == "ok":
        return envelope.get("data") or {}
    error = envelope.get("error") or {}
    raise BridgeError(
        error.get("code", "skill_failed"),
        error.get("message", "The agent reported an error."),
        error.get("remediation", "Inspect the agent output and retry."),
    )


def run_cli(agent_path, argv, timeout=DEFAULT_TIMEOUT, runner=None):
    """Run arbitrary argv through the CLI and return unwrapped data."""
    if not isinstance(argv, (list, tuple)) or not argv:
        raise BridgeError(
            "invalid_argv",
            "CLI argv must be a non-empty list of strings.",
            "Pass subcommand tokens such as ['discover', '--role', 'coding'].",
        )
    cleaned = []
    for item in argv:
        if not isinstance(item, str) or not item:
            raise BridgeError(
                "invalid_argv",
                "CLI argv entries must be non-empty strings.",
                "Do not pass a shell string; pass discrete argv tokens.",
            )
        cleaned.append(item)
    return unwrap(run(agent_path, cleaned, timeout=timeout, runner=runner))


def scan(agent_path, gguf_roots=(), mlx_roots=(), signatures=True, limit=None,
         timeout=DEFAULT_TIMEOUT, runner=None):
    """Inventory local GGUF weights through convert scan."""
    argv = ["convert", "scan"]
    for root in gguf_roots:
        argv.extend(["--gguf-root", root])
    for root in mlx_roots:
        argv.extend(["--mlx-root", root])
    if not signatures:
        argv.append("--no-signature")
    if limit:
        argv.extend(["--limit", str(limit)])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def preview(agent_path, gguf_path, q_bits=4, out=None, timeout=DEFAULT_TIMEOUT, runner=None):
    """Render a GGUF conversion plan without starting anything."""
    argv = ["convert", "start", "--gguf", gguf_path, "--q-bits", str(q_bits)]
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def start(agent_path, gguf_path, preview_hash, q_bits=4, out=None,
          timeout=DEFAULT_TIMEOUT, runner=None):
    """Start a reviewed GGUF conversion. The hash must come from a preview."""
    argv = [
        "convert", "start", "--gguf", gguf_path, "--q-bits", str(q_bits),
        "--confirm", "--preview-hash", preview_hash,
    ]
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def jobs(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    """Cross-check conversion receipts against live processes."""
    return unwrap(run(agent_path, ["convert", "status"], timeout=timeout, runner=runner))


def discover(agent_path, role=None, limit=None, fast=False, new=False,
             timeout=SCOUT_TIMEOUT, runner=None):
    """Discover MLX models for this host (Scout)."""
    argv = ["discover"]
    if role:
        argv.extend(["--role", role])
    if limit:
        argv.extend(["--limit", str(limit)])
    if fast:
        argv.append("--fast")
    if new:
        argv.append("--new")
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def doctor_models(agent_path, wired_roots=(), hf_cache=None,
                  timeout=DEFAULT_TIMEOUT, runner=None):
    """Run model doctor (read-only inventory and findings)."""
    argv = ["doctor", "models"]
    for root in wired_roots:
        argv.extend(["--wired-root", root])
    if hf_cache:
        argv.extend(["--hf-cache", hf_cache])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def serve_preview(agent_path, repo, runtime, port=None, timeout=DEFAULT_TIMEOUT, runner=None):
    """Render a serve plan without launching."""
    argv = ["serve", "start", "--repo", repo, "--runtime", runtime]
    if port is not None:
        argv.extend(["--port", str(port)])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def serve_start(agent_path, repo, runtime, preview_hash, port=None,
                timeout=DEFAULT_TIMEOUT, runner=None):
    """Start a reviewed serve plan."""
    argv = [
        "serve", "start", "--repo", repo, "--runtime", runtime,
        "--confirm", "--preview-hash", preview_hash,
    ]
    if port is not None:
        argv.extend(["--port", str(port)])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def serve_status(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    """List serve receipts against live processes."""
    return unwrap(run(agent_path, ["serve", "status"], timeout=timeout, runner=runner))


def serve_stop(agent_path, port, timeout=DEFAULT_TIMEOUT, runner=None):
    """Stop a serve-owned process on the given port."""
    return unwrap(run(
        agent_path, ["serve", "stop", "--port", str(port)],
        timeout=timeout, runner=runner,
    ))


def allowed_log_paths(agent_path, runner=None):
    """Paths the UI may tail: log_path values from convert and serve status."""
    paths = set()
    try:
        convert = jobs(agent_path, runner=runner)
        for entry in convert.get("jobs") or []:
            log_path = entry.get("log_path")
            if isinstance(log_path, str) and log_path:
                paths.add(str(Path(log_path).expanduser().resolve()))
    except BridgeError:
        pass
    try:
        serve = serve_status(agent_path, runner=runner)
        for entry in serve.get("servers") or []:
            log_path = entry.get("log_path")
            if isinstance(log_path, str) and log_path:
                paths.add(str(Path(log_path).expanduser().resolve()))
            receipt = entry.get("receipt") or {}
            if isinstance(receipt, dict):
                nested = receipt.get("log_path")
                if isinstance(nested, str) and nested:
                    paths.add(str(Path(nested).expanduser().resolve()))
    except BridgeError:
        pass
    return paths


def read_log(agent_path, log_path, max_bytes=MAX_LOG_BYTES, runner=None):
    """Return a bounded tail of a receipt log, only if status advertised it."""
    if not isinstance(log_path, str) or not log_path.strip():
        raise BridgeError(
            "invalid_body",
            "A log path is required.",
            "Pick a job from the Jobs tab.",
        )
    target = Path(log_path).expanduser().resolve()
    allowed = allowed_log_paths(agent_path, runner=runner)
    if str(target) not in allowed:
        raise BridgeError(
            "log_forbidden",
            "That log path is not from a known job receipt.",
            "Refresh Jobs and open a log listed there.",
        )
    if not target.is_file():
        raise BridgeError(
            "log_missing",
            "The log file is not readable yet.",
            "Wait for the job to start writing output, then refresh.",
        )
    data = target.read_bytes()
    truncated = len(data) > max_bytes
    if truncated:
        data = data[-max_bytes:]
    text = data.decode("utf-8", "replace")
    if truncated:
        text = "…\n" + text
    return {"path": str(target), "text": text, "truncated": truncated}


def _default_runner(command, timeout):
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    return {
        "returncode": completed.returncode,
        "stdout": completed.stdout.decode("utf-8", "replace"),
        "stderr": completed.stderr.decode("utf-8", "replace"),
    }
