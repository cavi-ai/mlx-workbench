"""Subprocess bridge to the vendored mlx-agent CLI.

This app owns no conversion or discovery logic. It locates ``scripts/mlx-agent``
in an mlx-agent checkout, runs it with ``--json``, and reads the result
envelope back. Nothing is imported from mlx-agent, so the two repositories
stay independently versioned.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
from pathlib import Path


CLI_RELATIVE = Path("scripts") / "mlx-agent"
DEFAULT_TIMEOUT = 300
SCOUT_TIMEOUT = 600
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_LOG_BYTES = 64 * 1024

# Only these variables (plus HF_*) reach the agent subprocess. The web UI's
# request environment is never trusted wholesale.
AGENT_ENV_KEYS = (
    "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL",
    "LANG", "LC_ALL",
    "MLX_AGENT_HOME", "MLX_WORKBENCH_CONFIG",
    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
    "SSL_CERT_FILE", "SSL_CERT_DIR",
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "no_proxy",
)
AGENT_ENV_PREFIXES = ("HF_",)


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
    return validate_scan(unwrap(run(agent_path, argv, timeout=timeout, runner=runner)))


def validate_scan(payload):
    """Reject malformed discovery data before a UI can render it as zero bytes."""
    models = payload.get("models")
    if not isinstance(models, list):
        raise BridgeError(
            "scan_contract_invalid",
            "The agent returned an invalid model inventory.",
            "Update mlx-agent and rescan.",
        )
    for index, model in enumerate(models):
        if not isinstance(model, dict):
            raise BridgeError(
                "scan_contract_invalid",
                "The agent returned an invalid model entry for models[{0}].".format(index),
                "Update mlx-agent and rescan.",
            )
        if not _nonempty_string(model.get("path")) or not _nonempty_string(model.get("name")):
            raise BridgeError(
                "scan_contract_invalid",
                "The agent returned an invalid model identity for models[{0}].".format(index),
                "Update mlx-agent and rescan.",
            )
        if not _nonnegative_int(model.get("bytes")):
            raise BridgeError(
                "scan_contract_invalid",
                "The agent returned an invalid byte count for models[{0}].".format(index),
                "Update mlx-agent and rescan.",
            )
    totals = payload.get("totals")
    if not isinstance(totals, dict) or not _nonnegative_int(totals.get("bytes")):
        raise BridgeError(
            "scan_contract_invalid",
            "The agent returned invalid inventory totals.",
            "Update mlx-agent and rescan.",
        )
    return payload


def _nonnegative_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


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
    ("dequantiz", "Dequantizing"),
    ("quantiz", "Quantizing"),
    ("saving", "Saving"),
    ("writing", "Writing"),
    ("download", "Downloading"),
)

_PROGRESS_FAIL_MARKERS = (
    "conversion failed",
    "is not supported",
    "traceback (most recent call last)",
    "assertionerror",
    "error:",
    "exception:",
)


def convert_progress(log_text):
    """Parse a convert log tail into phase, percent, and failure state.

    The log format the agent writes is line-based with a [mlx-converter]
    tag; percentage lines carry "NN%" and failures carry "conversion failed"
    or "not supported". The summary is the most informative recent line,
    truncated for display.
    """
    lines = [line.strip() for line in (log_text or "").splitlines() if line.strip()]
    if not lines:
        return {"summary": "Waiting for output", "last_line": "", "phase": "idle",
                "percent": None, "failed": False}
    last_line = lines[-1]
    lower = last_line.lower()

    failed = any(marker in lower for marker in _PROGRESS_FAIL_MARKERS)
    phase = "failed" if failed else "running"

    percent = None
    import re as _re
    match = _re.search(r"(\d{1,3})\s*%", last_line)
    if match:
        percent = min(100, int(match.group(1)))

    summary = last_line[:120] if last_line else "Running"
    if not failed and percent is None:
        for needle, label in _PROGRESS_PHASES:
            if needle in lower:
                phase = label.lower()
                summary = label
                break
    if failed:
        # Surface the failure line itself as the summary.
        summary = last_line[:160]
    return {
        "summary": summary,
        "last_line": last_line,
        "phase": phase,
        "percent": percent,
        "failed": failed,
    }


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
    """Aggregate convert / serve / lora / fuse status payloads.

    Per-probe failures are reported under "errors" instead of being
    swallowed, so the Jobs tab can tell "agent broken" apart from "idle".
    """
    result = {"jobs": [], "servers": [], "lora": [], "fuse": []}
    probes = (
        ("jobs", lambda: jobs(agent_path, runner=runner).get("jobs") or []),
        ("servers", lambda: serve_status(agent_path, runner=runner).get("servers") or []),
        ("lora", lambda: lora_status(agent_path, runner=runner).get("jobs") or []),
        ("fuse", lambda: fuse_status(agent_path, runner=runner).get("jobs") or []),
    )
    errors = {}
    for name, probe in probes:
        try:
            result[name] = probe()
        except BridgeError as error:
            errors[name] = error.to_dict()
    if errors:
        result["errors"] = errors
    return result


def serve_preview(agent_path, repo, runtime, port=None, timeout=DEFAULT_TIMEOUT,
                  runner=None, path=None, max_tokens=None, adapter_path=None):
    """Render a serve plan without launching. Exactly one of repo/path."""
    argv = ["serve", "start"]
    argv.extend(["--path", path] if path is not None else ["--repo", repo])
    argv.extend(["--runtime", runtime])
    if port is not None:
        argv.extend(["--port", str(port)])
    if max_tokens is not None:
        argv.extend(["--max-tokens", str(max_tokens)])
    if adapter_path is not None:
        argv.extend(["--adapter-path", adapter_path])
    return unwrap(run(agent_path, argv, timeout=timeout, runner=runner))


def serve_start(agent_path, repo, runtime, preview_hash, port=None,
                timeout=DEFAULT_TIMEOUT, runner=None, path=None,
                max_tokens=None, adapter_path=None):
    """Start a reviewed serve plan. Exactly one of repo/path."""
    argv = ["serve", "start"]
    argv.extend(["--path", path] if path is not None else ["--repo", repo])
    argv.extend([
        "--runtime", runtime,
        "--confirm", "--preview-hash", preview_hash,
    ])
    if port is not None:
        argv.extend(["--port", str(port)])
    if max_tokens is not None:
        argv.extend(["--max-tokens", str(max_tokens)])
    if adapter_path is not None:
        argv.extend(["--adapter-path", adapter_path])
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


def agent_environment(base=None):
    """A curated environment for agent subprocesses, never the whole env."""
    source = dict(os.environ) if base is None else dict(base)
    environment = {}
    for key in AGENT_ENV_KEYS:
        value = source.get(key)
        if value is not None:
            environment[key] = value
    for key, value in source.items():
        if key.startswith(AGENT_ENV_PREFIXES):
            environment[key] = value
    # The agent resolves sibling executables (e.g. mlx_lm.convert) via PATH;
    # without this, a uv-tool or Homebrew install of a different version
    # shadows the project venv's. The running interpreter's bin directory is
    # the one whose packages the agent must see.
    bin_dir = str(Path(sys.executable).resolve().parent)
    environment["PATH"] = bin_dir + os.pathsep + environment.get("PATH", "")
    return environment


def _kill_process_group(process):
    """Terminate, then kill, the whole process group of a timed-out child."""
    try:
        group = os.getpgid(process.pid)
    except OSError:
        group = None
    for number in (signal.SIGTERM, signal.SIGKILL):
        if process.poll() is not None:
            return
        try:
            if group is not None and group == process.pid:
                os.killpg(group, number)
            else:
                process.send_signal(number)
        except OSError:
            pass
        try:
            process.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def _default_runner(command, timeout):
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            env=agent_environment(),
        )
    except (OSError, ValueError) as error:
        # ValueError covers e.g. embedded NUL bytes in an argument.
        raise BridgeError(
            "skill_invalid_arguments",
            "The agent could not be started: {0}".format(error),
            "Check the submitted fields for control characters and retry.",
        ) from error
    with process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_process_group(process)
            stdout, stderr = process.communicate()
            raise BridgeError(
                "skill_timeout",
                "The agent did not finish within {0}s.".format(timeout),
                "Narrow the request (for example discover --fast), or raise the timeout.",
            )
    return {
        "returncode": process.returncode,
        "stdout": stdout.decode("utf-8", "replace"),
        "stderr": stderr.decode("utf-8", "replace"),
    }




def quant_profile(agent_path, path, targets, runner=None):
    """Preview supported MLX conversion plans for a local GGUF model."""
    target_bits = {"mlx-4bit": 4, "mlx-8bit": 8}
    profiles = []
    for target in targets:
        q_bits = target_bits.get(target)
        if q_bits is None:
            raise BridgeError(
                "quant_target_invalid",
                "Unsupported conversion target: {0}.".format(target),
                "Choose MLX 4-bit or MLX 8-bit.",
            )
        data = preview(agent_path, path, q_bits=q_bits, runner=runner)
        plan = data.get("plan") if isinstance(data, dict) else None
        if not isinstance(plan, dict):
            raise BridgeError(
                "quant_preview_invalid",
                "mlx-agent did not return a conversion plan.",
                "Retry the preview after rescanning the GGUF file.",
            )
        source = plan.get("source") if isinstance(plan.get("source"), dict) else {}
        profiles.append({
            "target": "MLX {0}-bit".format(q_bits),
            "q_bits": q_bits,
            "source_bytes": source.get("bytes"),
            "output": plan.get("out"),
            "preview_hash": plan.get("preview_hash"),
            "command": plan.get("argv"),
        })
    return {"profiles": profiles}


def model_architecture(agent_path, path, runner=None):
    """Return scan metadata for one local GGUF model.

    mlx-agent's scan contract does not expose transformer topology. Keep the
    UI truthful by returning only the metadata that scan actually reports.
    """
    location = Path(path).expanduser()
    if not location.is_file() or location.suffix.lower() != ".gguf":
        raise BridgeError(
            "model_not_found",
            "Model architecture requires an existing GGUF file.",
            "Select a GGUF file from the Models page and try again.",
        )

    resolved = location.resolve()
    payload = scan(
        agent_path,
        gguf_roots=[str(resolved.parent)],
        signatures=False,
        runner=runner,
    )
    model = next(
        (
            item for item in payload["models"]
            if Path(item["path"]).expanduser().resolve() == resolved
        ),
        None,
    )
    if model is None:
        raise BridgeError(
            "model_not_scanned",
            "mlx-agent did not return the selected GGUF file.",
            "Rescan the model directory and verify the file is readable.",
        )

    return {
        "architecture": {
            "model_path": str(resolved),
            "name": model["name"],
            "bytes": model["bytes"],
            "architecture": model.get("architecture"),
            "quantization": model.get("quantization"),
            "tensor_count": model.get("tensor_count"),
        },
    }



def scan_duplicates(agent_path, gguf_roots=(), mlx_roots=(), runner=None):
    """Return mlx-agent's evidence-backed duplicate groups.

    Exact groups are eligible for quarantine because the agent derives them
    from a content signature or matching model structure and quantization.
    Variant groups are informational only.
    """
    report = scan(
        agent_path,
        gguf_roots=gguf_roots,
        mlx_roots=mlx_roots,
        runner=runner,
    )
    duplicates = _validate_duplicate_groups(report)
    return {"duplicates": duplicates, "total_models": len(report["models"])}


def _validate_duplicate_groups(report):
    duplicates = report.get("duplicates")
    if not isinstance(duplicates, list):
        raise BridgeError(
            "scan_contract_invalid",
            "The agent returned invalid duplicate groups.",
            "Update mlx-agent and rescan.",
        )
    for index, group in enumerate(duplicates):
        if not isinstance(group, dict) or group.get("kind") not in ("exact", "variant"):
            raise BridgeError(
                "scan_contract_invalid",
                "The agent returned an invalid duplicate group for duplicates[{0}].".format(index),
                "Update mlx-agent and rescan.",
            )
        if not _nonempty_string(group.get("model_key")) or not _nonnegative_int(group.get("reclaimable_bytes")):
            raise BridgeError(
                "scan_contract_invalid",
                "The agent returned invalid duplicate metadata for duplicates[{0}].".format(index),
                "Update mlx-agent and rescan.",
            )
        if group["kind"] == "exact":
            if (not _nonempty_string(group.get("keep")) or
                    not _nonempty_string(group.get("quantization")) or
                    not _string_list(group.get("redundant"))):
                raise BridgeError(
                    "scan_contract_invalid",
                    "The agent returned an invalid exact duplicate group for duplicates[{0}].".format(index),
                    "Update mlx-agent and rescan.",
                )
        elif not _string_list(group.get("quantizations")) or not _string_list(group.get("members")):
            raise BridgeError(
                "scan_contract_invalid",
                "The agent returned an invalid variant duplicate group for duplicates[{0}].".format(index),
                "Update mlx-agent and rescan.",
            )
    return duplicates


def _string_list(value):
    return isinstance(value, list) and bool(value) and all(_nonempty_string(item) for item in value)
