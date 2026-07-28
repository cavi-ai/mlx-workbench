"""Subprocess bridge to the mlx-agent mlx-converter skill.

This app owns no conversion logic. It locates the skill script in an mlx-agent
checkout, runs it with ``--json``, and reads the result envelope back. Nothing
is imported from mlx-agent, so the two repositories stay independently
versioned and installable.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


SKILL_RELATIVE = Path("skills") / "mlx-converter" / "scripts" / "mlx_converter.py"
DEFAULT_TIMEOUT = 300
MAX_OUTPUT_BYTES = 8 * 1024 * 1024


class BridgeError(RuntimeError):
    """A classified failure to reach or run the skill."""

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


def skill_script(agent_path):
    """Resolve the skill entry point inside an mlx-agent checkout."""
    if not agent_path:
        raise BridgeError(
            "agent_not_configured",
            "No mlx-agent checkout is configured.",
            "Set mlx_agent_path in the configuration to your mlx-agent clone.",
        )
    script = Path(agent_path).expanduser() / SKILL_RELATIVE
    if not script.is_file():
        raise BridgeError(
            "agent_not_found",
            "No mlx-converter skill at {0}.".format(script),
            "Point mlx_agent_path at an mlx-agent checkout that bundles the mlx-converter skill.",
        )
    return script


def run(agent_path, argv, timeout=DEFAULT_TIMEOUT, runner=None):
    """Run one skill subcommand and return its parsed result envelope."""
    script = skill_script(agent_path)
    command = [sys.executable, str(script)] + [str(item) for item in argv] + ["--json"]
    execute = runner or _default_runner
    try:
        completed = execute(command, timeout)
    except subprocess.TimeoutExpired as error:
        raise BridgeError(
            "skill_timeout",
            "The skill did not finish within {0}s.".format(timeout),
            "Narrow the scan roots, or raise the timeout for very large collections.",
        ) from error
    except OSError as error:
        raise BridgeError(
            "skill_unavailable",
            "The skill could not be started: {0}".format(error),
            "Check that python3 and the mlx-agent checkout are both readable.",
        ) from error
    stdout = completed.get("stdout") or ""
    if len(stdout) > MAX_OUTPUT_BYTES:
        raise BridgeError(
            "skill_output_too_large",
            "The skill returned more output than this app will buffer.",
            "Scan fewer roots at a time, or pass a lower --limit.",
        )
    try:
        payload = json.loads(stdout)
    except ValueError as error:
        detail = (completed.get("stderr") or stdout or "").strip()[:400]
        raise BridgeError(
            "skill_output_unreadable",
            "The skill did not return JSON: {0}".format(detail or error),
            "Run the same command by hand in the mlx-agent checkout to see the failure.",
        ) from error
    if not isinstance(payload, dict) or "status" not in payload:
        raise BridgeError(
            "skill_output_unreadable",
            "The skill returned an unexpected payload.",
            "Check that the mlx-agent checkout is up to date.",
        )
    return payload


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


def unwrap(envelope):
    """Return the envelope's data, or raise its classified error."""
    if envelope.get("status") == "ok":
        return envelope.get("data") or {}
    error = envelope.get("error") or {}
    raise BridgeError(
        error.get("code", "skill_failed"),
        error.get("message", "The skill reported an error."),
        error.get("remediation", "Inspect the skill output and retry."),
    )


def scan(agent_path, gguf_roots=(), mlx_roots=(), signatures=True, limit=None,
         timeout=DEFAULT_TIMEOUT, runner=None):
    """Inventory local GGUF weights through the skill."""
    argv = ["scan"]
    for root in gguf_roots:
        argv.extend(["--gguf-root", root])
    for root in mlx_roots:
        argv.extend(["--mlx-root", root])
    if not signatures:
        argv.append("--no-signature")
    if limit:
        argv.extend(["--limit", limit])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def preview(agent_path, gguf_path, q_bits=4, out=None, timeout=DEFAULT_TIMEOUT, runner=None):
    """Render a conversion plan without starting anything."""
    argv = ["start", "--gguf", gguf_path, "--q-bits", q_bits]
    if out:
        argv.extend(["--out", out])
    envelope = run(agent_path, argv, timeout=timeout, runner=runner)
    return unwrap(envelope)


def start(agent_path, gguf_path, preview_hash, q_bits=4, out=None,
          timeout=DEFAULT_TIMEOUT, runner=None):
    """Start a reviewed conversion. The hash must come from a preview."""
    argv = [
        "start", "--gguf", gguf_path, "--q-bits", q_bits,
        "--confirm", "--preview-hash", preview_hash,
    ]
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def jobs(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    """Cross-check conversion receipts against live processes."""
    return unwrap(run(agent_path, ["status"], timeout=timeout, runner=runner))
