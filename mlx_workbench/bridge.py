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


def preview_repo(agent_path, repo, q_bits=4, out=None, hf_cache=None,
                 timeout=DEFAULT_TIMEOUT, runner=None):
    """Render an HF-cache conversion plan without starting anything."""
    argv = ["convert", "start", "--repo", repo, "--q-bits", str(q_bits)]
    if out:
        argv.extend(["--out", out])
    if hf_cache:
        argv.extend(["--hf-cache", hf_cache])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def start_repo(agent_path, repo, preview_hash, q_bits=4, out=None, hf_cache=None,
               timeout=DEFAULT_TIMEOUT, runner=None):
    """Start a reviewed HF-cache conversion. The hash must come from a preview."""
    argv = [
        "convert", "start", "--repo", repo, "--q-bits", str(q_bits),
        "--confirm", "--preview-hash", preview_hash,
    ]
    if out:
        argv.extend(["--out", out])
    if hf_cache:
        argv.extend(["--hf-cache", hf_cache])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def convert_is_busy(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    """True when mlx-agent reports a live convert process."""
    try:
        payload = jobs(agent_path, timeout=timeout, runner=runner)
    except BridgeError:
        return False
    for entry in payload.get("jobs") or []:
        if isinstance(entry, dict) and entry.get("state") == "running":
            return True
    return False


_PROGRESS_PHASES = (
    ("loading", "Loading"),
    ("convert", "Converting"),
    ("quantiz", "Quantizing"),
    ("saving", "Saving"),
    ("writing", "Writing"),
    ("download", "Downloading"),
)


def convert_progress(log_text):
    """Cheap phase summary from a convert log tail."""
    lines = [line.strip() for line in (log_text or "").splitlines() if line.strip()]
    last_line = lines[-1] if lines else ""
    summary = "Running" if last_line else "Waiting for output"
    lower = last_line.lower()
    for needle, label in _PROGRESS_PHASES:
        if needle in lower:
            summary = label
            break
    if "%" in last_line:
        summary = last_line[:120]
    return {"summary": summary, "last_line": last_line}


def jobs(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    """Cross-check conversion receipts against live processes."""
    return unwrap(run(agent_path, ["convert", "status"], timeout=timeout, runner=runner))


def read_convert_receipts(entries, max_bytes=MAX_LOG_BYTES):
    """Read bounded receipt JSON from paths advertised by convert status."""
    receipts = []
    for entry in entries or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("receipt"), str):
            continue
        advertised = Path(entry["receipt"]).expanduser()
        try:
            location = advertised.resolve(strict=True)
        except FileNotFoundError as error:
            raise BridgeError(
                "receipt_missing",
                "A conversion receipt no longer exists: {0}".format(advertised),
                "Run convert status again or inspect the mlx-agent receipt directory.",
            ) from error
        except OSError as error:
            raise BridgeError(
                "receipt_unreadable",
                "A conversion receipt could not be resolved: {0}".format(error),
                "Check the receipt path and file permissions.",
            ) from error
        if not location.is_file():
            raise BridgeError(
                "receipt_missing",
                "A conversion receipt is not a regular file: {0}".format(location),
                "Run convert status again or inspect the mlx-agent receipt directory.",
            )
        try:
            size = location.stat().st_size
        except OSError as error:
            raise BridgeError(
                "receipt_unreadable",
                "A conversion receipt could not be inspected: {0}".format(error),
                "Check the receipt file permissions.",
            ) from error
        if size > max_bytes:
            raise BridgeError(
                "receipt_too_large",
                "A conversion receipt exceeds the {0}-byte read limit.".format(max_bytes),
                "Inspect or remove the malformed receipt in the mlx-agent state directory.",
            )
        try:
            receipt = json.loads(location.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as error:
            raise BridgeError(
                "receipt_unreadable",
                "A conversion receipt is not readable JSON: {0}".format(error),
                "Inspect or remove the malformed receipt in the mlx-agent state directory.",
            ) from error
        if not isinstance(receipt, dict):
            raise BridgeError(
                "receipt_unreadable",
                "A conversion receipt is not a JSON object.",
                "Inspect or remove the malformed receipt in the mlx-agent state directory.",
            )
        receipts.append(receipt)
    return receipts


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


def doctor_prune_preview(agent_path, hf_cache=None, timeout=DEFAULT_TIMEOUT, runner=None):
    """Preview irreversible deletion of incomplete HF cache snapshots."""
    argv = ["doctor", "models", "--prune"]
    if hf_cache:
        argv.extend(["--hf-cache", hf_cache])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def doctor_prune_confirm(agent_path, preview_hash, hf_cache=None,
                         timeout=DEFAULT_TIMEOUT, runner=None):
    """Execute a reviewed incomplete-cache prune."""
    argv = [
        "doctor", "models", "--prune", "--confirm", "--preview-hash", preview_hash,
    ]
    if hf_cache:
        argv.extend(["--hf-cache", hf_cache])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def adopt_start(agent_path, role=None, state=None, fast=False, offline=False,
                timeout=SCOUT_TIMEOUT, runner=None):
    """Start a durable adopt workflow for a role."""
    argv = ["adopt", "start"]
    if role:
        argv.extend(["--role", role])
    if state:
        argv.extend(["--state", state])
    if fast:
        argv.append("--fast")
    if offline:
        argv.append("--offline")
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def adopt_status(agent_path, state, timeout=DEFAULT_TIMEOUT, runner=None):
    """Inspect an adoption handoff file."""
    return unwrap(run(
        agent_path, ["adopt", "status", "--state", state],
        timeout=timeout, runner=runner,
    ))


def wire_preview(agent_path, model, path, target="mlx_lm",
                 timeout=DEFAULT_TIMEOUT, runner=None):
    """Preview a wire apply transaction (no mutation)."""
    argv = ["wire", "apply", model, "--path", path, "--target", target]
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def wire_apply(agent_path, model, path, preview_hash, target="mlx_lm",
               timeout=DEFAULT_TIMEOUT, runner=None):
    """Apply a reviewed wire configuration."""
    argv = [
        "wire", "apply", model, "--path", path, "--target", target,
        "--confirm", "--preview-hash", preview_hash,
    ]
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def lora_preview(agent_path, repo, data, iters=None, out=None,
                 timeout=DEFAULT_TIMEOUT, runner=None):
    """Preview LoRA training without starting."""
    argv = ["lora", "start", "--repo", repo, "--data", data]
    if iters is not None:
        argv.extend(["--iters", str(iters)])
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def lora_start(agent_path, repo, data, preview_hash, iters=None, out=None,
               timeout=DEFAULT_TIMEOUT, runner=None):
    """Start a reviewed LoRA training job."""
    argv = [
        "lora", "start", "--repo", repo, "--data", data,
        "--confirm", "--preview-hash", preview_hash,
    ]
    if iters is not None:
        argv.extend(["--iters", str(iters)])
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def lora_status(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    return unwrap(run(agent_path, ["lora", "status"], timeout=timeout, runner=runner))


def fuse_preview(agent_path, repo, adapter, out=None,
                 timeout=DEFAULT_TIMEOUT, runner=None):
    """Preview fuse without starting."""
    argv = ["fuse", "start", "--repo", repo, "--adapter", adapter]
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def fuse_start(agent_path, repo, adapter, preview_hash, out=None,
               timeout=DEFAULT_TIMEOUT, runner=None):
    """Start a reviewed fuse job."""
    argv = [
        "fuse", "start", "--repo", repo, "--adapter", adapter,
        "--confirm", "--preview-hash", preview_hash,
    ]
    if out:
        argv.extend(["--out", out])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def fuse_status(agent_path, timeout=DEFAULT_TIMEOUT, runner=None):
    return unwrap(run(agent_path, ["fuse", "status"], timeout=timeout, runner=runner))


def all_job_lists(agent_path, runner=None):
    """Aggregate convert / serve / lora / fuse status payloads."""
    result = {"jobs": [], "servers": [], "lora": [], "fuse": []}
    try:
        result["jobs"] = jobs(agent_path, runner=runner).get("jobs") or []
    except BridgeError:
        pass
    try:
        result["servers"] = serve_status(agent_path, runner=runner).get("servers") or []
    except BridgeError:
        pass
    try:
        result["lora"] = lora_status(agent_path, runner=runner).get("jobs") or []
    except BridgeError:
        pass
    try:
        result["fuse"] = fuse_status(agent_path, runner=runner).get("jobs") or []
    except BridgeError:
        pass
    return result


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
    """Paths the UI may tail: log_path values from job receipts."""
    paths = set()
    lists = all_job_lists(agent_path, runner=runner)
    for key in ("jobs", "servers", "lora", "fuse"):
        for entry in lists.get(key) or []:
            if not isinstance(entry, dict):
                continue
            log_path = entry.get("log_path")
            if isinstance(log_path, str) and log_path:
                paths.add(str(Path(log_path).expanduser().resolve()))
            receipt = entry.get("receipt") or {}
            if isinstance(receipt, dict):
                nested = receipt.get("log_path")
                if isinstance(nested, str) and nested:
                    paths.add(str(Path(nested).expanduser().resolve()))
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
    progress = convert_progress(text)
    return {
        "path": str(target),
        "text": text,
        "truncated": truncated,
        "progress": progress,
    }


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


def quant_profile(agent_path, path, targets):
    """Profile quantization options using mlx-agent convert preview."""
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

    profiles = []
    for target in targets:
        argv = ["convert", "preview", "--path", path]
        
        if target == "gguf-q4":
            argv.extend(["--q-bits", "4", "--out", path + ".Q4_K_M.gguf"])
        elif target == "gguf-q8":
            argv.extend(["--q-bits", "8", "--out", path + ".Q8_0.gguf"])
        elif target == "gguf-q5":
            argv.extend(["--q-bits", "5", "--out", path + ".Q5_K_M.gguf"])
        elif target == "mlx-bf16":
            argv.extend(["--q-bits", "bf16", "--out", path + ".mlx-bf16"])
        elif target == "mlx-4bit":
            argv.extend(["--q-bits", "4", "--out", path + ".mlx-4bit"])
        elif target == "mlx-8bit":
            argv.extend(["--q-bits", "8", "--out", path + ".mlx-8bit"])
        
        argv.append("--json")
        command = [sys.executable, str(script)] + argv
        try:
            result = _default_runner(command, timeout=DEFAULT_TIMEOUT)
            if result["returncode"] == 0:
                output = json.loads(result["stdout"])
                plan = output.get("data", {}).get("plan", {}) or output.get("data", {})
                
                profile = {
                    "target": target,
                    "size": plan.get("preview_hash", 0),
                    "tokens_per_sec": None,
                    "vram": None,
                    "command": argv,
                }
                
                if target.startswith("mlx-"):
                    profile["actions"] = [{
                        "type": "convert",
                        "label": f"Convert to {target}",
                        "path": path,
                    }]
                
                profiles.append(profile)
        except Exception as error:
            profiles.append({
                "target": target,
                "error": str(error),
                "command": argv,
            })
    
    return {"profiles": profiles}
