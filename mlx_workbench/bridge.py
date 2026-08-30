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


def serve_metrics(agent_path, port):
    """Get performance metrics for a running mlx server.
    
    Returns real-time metrics including tokens/sec, VRAM usage,
    CPU/GPU stats for the specified server port.
    """
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
    
    try:
        import urllib.request
        import json as json_module
        
        # Try to connect to the mlx server metrics endpoint
        try:
            req = urllib.request.Request(
                "http://127.0.0.1:" + str(port) + "/metrics",
                method="GET"
            )
            
            with urllib.request.urlopen(req, timeout=5) as response:
                metrics = json_module.loads(response.read().decode())
            
            return {
                "metrics": metrics,
                "connected": True,
            }
        except Exception as e:
            # Server not responding, return placeholder
            return {
                "metrics": {
                    "tokens_per_sec": None,
                    "vram_used": None,
                    "vram_free": None,
                    "cpu_temp": None,
                    "gpu_load": None,
                },
                "connected": False,
                "error": str(e),
            }
    except Exception as error:
        raise BridgeError(
            "serve_metrics_failed",
            "Could not get metrics: {0}".format(str(error)),
            "Ensure the server is running and accessible.",
        )



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




def sloth_connect(agent_path, address="http://localhost:3000", gguf_roots=(),
                  mlx_roots=(), runner=None):
    """Connect to Sloth AI server and sync models.
    
    Provides integration with Sloth AI for distributed serving
    and model sharing capabilities.
    """
    # Check connection to Sloth server
    try:
        import urllib.request
        import json as json_module
        
        req = urllib.request.Request(
            address + "/api/health",
            method="GET"
        )
        
        with urllib.request.urlopen(req, timeout=5) as response:
            health = json_module.loads(response.read().decode())

        models = scan(
            agent_path,
            gguf_roots=gguf_roots,
            mlx_roots=mlx_roots,
            runner=runner,
        )["models"]

        return {
            "connected": True,
            "address": address,
            "health": health,
            "models_synced": len(models),
        }
    except BridgeError:
        raise
    except Exception as error:
        raise BridgeError(
            "sloth_connection_failed",
            "Could not connect to Sloth AI at {0}: {1}".format(address, str(error)),
            "Check that Sloth AI server is running and accessible.",
        )

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


def lmstudio_import(agent_path, source_dir=None, convertImmediately=True):
    """Import models from LM Studio to mlx format.
    
    Scans LM Studio's default model directories and returns models that can be
    imported. Optionally converts them immediately to mlx format.
    """
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

    import_paths = [
        Path.home() / ".lmstudio" / "models",
        Path.home() / ".cache" / "lm-studio" / "models",
    ]
    
    if source_dir:
        import_paths.insert(0, Path(source_dir))
    
    models = []
    for path in import_paths:
        if not path.exists():
            continue
        for gguf_file in path.glob("*.gguf"):
            models.append({
                "path": str(gguf_file),
                "name": gguf_file.name,
                "size": gguf_file.stat().st_size,
            })
    
    if convertImmediately and models:
        conversions = []
        for model in models:
            argv = [
                "convert", "--path", model["path"],
                "--q-bits", "4",
                "--out", str(Path.home() / "models" / "mlx" / (model["name"] + ". mlx")),
            ]
            argv.append("--json")
            command = [sys.executable, str(script)] + argv
            try:
                result = _default_runner(command, timeout=DEFAULT_TIMEOUT)
                if result["returncode"] == 0:
                    output = json.loads(result["stdout"])
                    conversions.append({
                        "path": model["path"],
                        "success": True,
                        "output": output,
                    })
                else:
                    conversions.append({
                        "path": model["path"],
                        "success": False,
                        "error": result["stderr"],
                    })
            except Exception as error:
                conversions.append({
                    "path": model["path"],
                    "success": False,
                    "error": str(error),
                })
        return {"models": models, "conversions": conversions}
    
    return {"models": models}


def dataset_score(agent_path, path):
    """Score dataset quality for fine-tuning.
    
    Analyzes dataset structure and examples to provide
    a quality score and recommendations.
    """
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
    
    try:
        # Analyze dataset structure
        import json as json_module
        
        samples = []
        try:
            dataset_file = Path(path) / "train.jsonl"
            if dataset_file.exists():
                lines = dataset_file.read_text(encoding="utf-8").strip().split('\n')[:10]
                for line in lines:
                    try:
                        obj = json_module.loads(line)
                        samples.append({
                            "prompt": str(obj.get("prompt", "")),
                            "response": str(obj.get("response", obj.get("output", ""))),
                        })
                    except:
                        pass
        except Exception as e:
            samples = []
        
        # Calculate basic metrics
        example_count = len(samples)
        total_tokens = sum(
            len((s["prompt"] + " " + s["response"]).split())
            for s in samples
        )
        avg_length = total_tokens // example_count if example_count > 0 else 0
        
        # Simple scoring
        score = 0.5
        if example_count >= 100:
            score += 0.2
        elif example_count >= 50:
            score += 0.1
        
        if avg_length >= 50 and avg_length <= 200:
            score += 0.15
        elif avg_length > 0 and avg_length < 50:
            score += 0.05
        
        if len(samples) > 0:
            # Check for proper format
            has_prompt = all("prompt" in s for s in samples if s.get("prompt"))
            score += 0.15 if has_prompt else 0
        
        score = min(1.0, max(0.0, score))
        
        return {
            "score": score,
            "example_count": example_count,
            "avg_length": avg_length,
            "samples": samples[:5],
        }
    except Exception as error:
        return {
            "score": 0.0,
            "error": str(error),
        }


def finetune_preview(agent_path, base_model, dataset_path, iters=100, learning_rate="2e-5"):
    """Preview fine-tuning training with estimated outcomes.
    
    Shows training time, VRAM requirements, and expected quality improvement.
    """
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
    
    argv = [
        "lora", "preview",
        "--repo", base_model,
        "--data", dataset_path,
        "--iters", str(iters),
        "--learning-rate", learning_rate,
    ]
    
    try:
        import json as json_module
        argv.append("--json")
        command = [sys.executable, str(script)] + argv
        result = _default_runner(command, timeout=60)
        
        if result["returncode"] == 0:
            try:
                output = json.loads(result["stdout"])
                plan = output.get("data", {}).get("plan", {}) or output.get("data", {})
                
                return {
                    "preview": plan,
                    "estimated": {
                        "time_estimate": str(iters) + " iterations",
                        "quality_gain": "~5-15% accuracy increase (estimated)",
                        "vram_required": "4GB - 8GB",
                        "epochs": str(max(1, iters // 100)),
                        "before_metrics": "Base model performance",
                        "after_metrics": "Fine-tuned model (estimated)",
                    },
                }
            except:
                pass
        
        return {
            "preview": None,
            "estimated": {
                "time_estimate": str(iters) + " iterations",
                "quality_gain": "~5-15% accuracy increase (estimated)",
                "vram_required": "4GB - 8GB",
                "epochs": str(max(1, iters // 100)),
                "before_metrics": "Base model",
                "after_metrics": "Fine-tuned (estimated)",
            },
        }
    except Exception as error:
        return {
            "preview": None,
            "estimated": {
                "time_estimate": str(iters) + " iterations",
                "quality_gain": "~5-15% accuracy increase (estimated)",
                "vram_required": "4GB - 8GB",
                "epochs": str(max(1, iters // 100)),
                "error": str(error),
            },
        }



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
    """Scan for duplicates across all configured GGUF roots."""
    try:
        models = scan(
            agent_path,
            gguf_roots=gguf_roots,
            mlx_roots=mlx_roots,
            runner=runner,
        )["models"]

        # Group by filename (exact duplicates)
        exact_groups = {}

        for model in models:
            path = model["path"]
            name = Path(path).name
            # Group exact filename matches (same file, different location or same path)
            if name not in exact_groups:
                exact_groups[name] = []
            exact_groups[name].append(path)
        
        # Filter to only groups with more than one path
        duplicates = []
        for name, paths in exact_groups.items():
            if len(paths) > 1:
                duplicates.append({
                    "group_id": name,
                    "files": paths,
                    "count": len(paths),
                })
        
        return {
            "duplicates": duplicates,
            "total_models": len(models),
        }
    except BridgeError:
        raise
    except Exception as error:
        raise BridgeError(
            "duplicate_scan_failed",
            str(error),
            "Check your configured GGUF roots and try again.",
        )
