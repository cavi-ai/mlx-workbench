"""Loopback HTTP server for the mlx-workbench UI. Standard library only."""

from __future__ import annotations

import json
import secrets
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import (
    audit as audit_module,
    bridge,
    config as config_module,
    convert_queue as convert_queue_module,
    deps as deps_module,
    quarantine as quarantine_module,
)


STATIC_ROOT = Path(__file__).resolve().with_name("static")
MAX_BODY_BYTES = 64 * 1024
MAX_CONCURRENT_REQUESTS = 16
TOKEN_HEADER = "X-MLX-Workbench-Token"
_ALLOWED_HOSTS = ("127.0.0.1", "localhost", "[::1]")
_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}


class ConversionWorker:
    """Background single-flight drain for the durable conversion queue."""

    def __init__(self, queue, agent_provider, runner=None, interval=2.0):
        self.queue = queue
        self.agent_provider = agent_provider
        self.runner = runner
        self.interval = interval
        self.last_result = None
        self.last_error = None
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="mlx-workbench-convert-worker",
            daemon=True,
        )

    def start(self):
        if not self._thread.is_alive():
            self._thread.start()
        self.wake()

    def wake(self):
        self._wake.set()

    def stop(self):
        self._stop.set()
        self.wake()
        if self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=max(5.0, self.interval + 1.0))

    def _run(self):
        while not self._stop.is_set():
            if not self.queue.snapshot():
                self._wake.wait()
                self._wake.clear()
                continue
            try:
                self.last_result = self.queue.try_start_next(
                    self.agent_provider(), runner=self.runner,
                )
                self.last_error = None
            except (bridge.BridgeError, convert_queue_module.QueuePersistenceError) as error:
                self.last_result = None
                self.last_error = error.to_dict()
            if self._stop.is_set():
                break
            timeout = self.interval if self.queue.snapshot() else None
            self._wake.wait(timeout)
            self._wake.clear()


class Application:
    """Everything the handler needs, with no global state."""

    def __init__(self, config_path=None, token=None, runner=None,
                 queue_path_override=None, worker_interval=2.0,
                 request_slots=MAX_CONCURRENT_REQUESTS, scan_ttl_seconds=60.0):
        self.config_path = config_path
        self.token = token or secrets.token_urlsafe(24)
        self.runner = runner
        self.lock = threading.Lock()
        self.request_slots = threading.BoundedSemaphore(request_slots)
        self._scan_cache = None
        self._scan_cached_at = 0.0
        self._scan_refreshing = False
        self.scan_ttl_seconds = scan_ttl_seconds
        state_path = (
            Path(queue_path_override)
            if queue_path_override is not None
            else convert_queue_module.queue_path(config_path)
        )
        self.convert_queue = convert_queue_module.ConvertQueue(path=state_path)
        self.audit_file = audit_module.audit_path(config_path)
        self.worker = ConversionWorker(
            self.convert_queue,
            lambda: self.config()["mlx_agent_path"],
            runner=runner,
            interval=worker_interval,
        )

    def config(self):
        return config_module.load(self.config_path)

    def save_config(self, value):
        with self.lock:
            return config_module.save(value, self.config_path)

    def audit(self, operation, **details):
        """Note a state-changing operation in the local audit trail."""
        return audit_module.record(
            operation, path=self.audit_file, **details
        )

    def cached_scan(self, settings, agent, runner, refresh=False):
        """Scan results with stale-while-revalidate caching.

        A scan walks every configured root with full signatures and can take
        minutes on a large library, so screens must never block on it. The
        first scan populates the cache; later calls return the cached
        snapshot immediately (marked ``cached``/``stale``) and kick off a
        background refresh so the next load is fresher. ``refresh=True``
        (the Rescan button) scans synchronously instead.
        """
        now = time.monotonic()
        with self.lock:
            cached = self._scan_cache
            cache_fresh = (
                cached is not None and now - self._scan_cached_at < self.scan_ttl_seconds
            )
            if cached is not None and not refresh and cache_fresh:
                return dict(cached), False
            if cached is not None and not refresh:
                # Serve the stale snapshot now; refresh in the background.
                self._start_scan_refresh(settings, agent, runner)
                return dict(cached), True
        payload = bridge.scan(
            agent,
            gguf_roots=config_module.scan_roots(settings),
            mlx_roots=settings["mlx_roots"],
            signatures=settings["signatures"],
            runner=runner,
        )
        with self.lock:
            self._scan_cache = payload
            self._scan_cached_at = time.monotonic()
        return payload, False

    def _start_scan_refresh(self, settings, agent, runner):
        """Spawn a background refresh. Callers must NOT hold self.lock."""
        if self._scan_refreshing:
            return
        self._scan_refreshing = True

        def refresh():
            try:
                payload = bridge.scan(
                    agent,
                    gguf_roots=config_module.scan_roots(settings),
                    mlx_roots=settings["mlx_roots"],
                    signatures=settings["signatures"],
                    runner=runner,
                )
                with self.lock:
                    self._scan_cache = payload
                    self._scan_cached_at = time.monotonic()
            except Exception:
                # Keep serving the previous snapshot; the next request
                # retries. A failed background scan is never fatal.
                pass
            finally:
                with self.lock:
                    self._scan_refreshing = False

        thread = threading.Thread(
            target=refresh, name="mlx-workbench-scan-refresh", daemon=True
        )
        thread.start()


def _json_bytes(payload, status=200):
    return status, "application/json; charset=utf-8", json.dumps(payload).encode("utf-8")


def _error(code, message, remediation, status=400):
    return _json_bytes(
        {"status": "error", "error": {
            "code": code, "message": message, "remediation": remediation,
        }},
        status,
    )


def _ok(data):
    return _json_bytes({"status": "ok", "data": data})


def _rejects_control_characters(*values):
    """True when any value is a string carrying C0 control characters.

    Paths travel as argv tokens; embedded NULs crash subprocess spawn and
    other control characters are never legitimate in a filesystem path.
    """
    return any(
        isinstance(value, str) and any(ord(ch) < 32 for ch in value)
        for value in values
    )


def _static(name):
    location = (STATIC_ROOT / name).resolve()
    if not location.is_file() or STATIC_ROOT not in location.parents:
        return 404, "text/plain; charset=utf-8", b"not found"
    content_type = _CONTENT_TYPES.get(location.suffix, "application/octet-stream")
    return 200, content_type, location.read_bytes()


class Handler(BaseHTTPRequestHandler):
    server_version = "mlx-workbench"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    @property
    def app(self):
        return self.server.app

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        return

    def _host_is_local(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        return host in _ALLOWED_HOSTS

    def _origin_is_local(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        hostname = urlparse(origin).hostname
        return hostname in ("127.0.0.1", "localhost", "::1")

    def _authorized(self):
        supplied = self.headers.get(TOKEN_HEADER) or ""
        return secrets.compare_digest(supplied, self.app.token)

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'self'; script-src 'self'; "
            "connect-src 'self'; img-src 'self'; form-action 'self'; "
            "base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def version_string(self):
        """No Python version in the Server header."""
        return self.server_version

    def _body(self):
        length = self.headers.get("Content-Length")
        try:
            size = int(length or 0)
        except ValueError:
            # Drain what the client already sent so it can read the reply
            # instead of dying on a broken pipe mid-upload.
            self._drain_body()
            return None
        if size <= 0 or size > MAX_BODY_BYTES:
            self._drain_body()
            return None
        try:
            return json.loads(self.rfile.read(size).decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            return None

    def _drain_body(self, cap=256 * 1024):
        """Read and discard an unread request body, bounded."""
        try:
            remaining = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            remaining = 0
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            remaining -= len(chunk)
            if remaining > cap:
                break

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        if not self.app.request_slots.acquire(blocking=False):
            self._send(*_error(
                "server_busy",
                "This server is already handling the maximum number of requests.",
                "Wait for an in-flight request to finish, then retry.",
                503,
            ))
            return
        try:
            self._dispatch_checked(method)
        finally:
            self.app.request_slots.release()

    def _dispatch_checked(self, method):
        if not self._host_is_local() or not self._origin_is_local():
            self._send(*_error(
                "forbidden_origin",
                "This server only answers same-origin loopback requests.",
                "Open the printed http://127.0.0.1 URL directly.",
                403,
            ))
            return
        route = urlparse(self.path).path
        try:
            status, content_type, body = self._route(method, route)
        except bridge.BridgeError as error:
            payload = error.to_dict()
            if error.code == "runtime_not_installed":
                hint = " Run `{0}` in the mlx-workbench checkout.".format(
                    deps_module.INSTALL_HINT
                )
                remediation = payload.get("remediation") or ""
                if deps_module.INSTALL_HINT not in remediation:
                    payload["remediation"] = (remediation + hint).strip()
            status, content_type, body = _json_bytes(
                {"status": "error", "error": payload}, 502
            )
        except convert_queue_module.QueuePersistenceError as error:
            status, content_type, body = _json_bytes(
                {"status": "error", "error": error.to_dict()}, 500
            )
        except convert_queue_module.QueueOperationError as error:
            status, content_type, body = _json_bytes(
                {"status": "error", "error": error.to_dict()}, 409
            )
        except quarantine_module.QuarantineError as error:
            status, content_type, body = _json_bytes(
                {"status": "error", "error": error.to_dict()}, 400
            )
        except config_module.ConfigError as error:
            status, content_type, body = _error("invalid_config", str(error), "Fix the field and save again.")
        except Exception:  # last-resort envelope: never drop the connection
            traceback.print_exc()
            status, content_type, body = _error(
                "internal_error",
                "Unexpected server error.",
                "Check the server log for the traceback and retry.",
                500,
            )
        self._send(status, content_type, body)

    def _route(self, method, route):
        if method == "GET" and route in ("/", "/index.html"):
            status, content_type, body = _static("index.html")
            body = body.replace(b"__MLX_TOKEN__", self.app.token.encode("ascii"))
            return status, content_type, body
        if method == "GET" and route.startswith("/static/"):
            return _static(route[len("/static/"):])
        if not route.startswith("/api/"):
            return 404, "text/plain; charset=utf-8", b"not found"
        if not self._authorized():
            return _error(
                "unauthorized",
                "Missing or invalid session token.",
                "Reload the page served by this process.",
                401,
            )
        return self._api(method, route)

    def _api(self, method, route):
        settings = self.app.config()
        agent = settings["mlx_agent_path"]
        runner = self.app.runner
        handler = _API_ROUTES.get((method, route))
        if handler is None:
            return 404, "text/plain; charset=utf-8", b"not found"
        return handler(self, route, settings, agent, runner)

    # MARK: route handlers (registered in _API_ROUTES below)

    def _api_config_get(self, route, settings, agent, runner):
        return _ok({
            "config": settings,
            "discovered_roots": config_module.discover_gguf_roots(),
            "config_path": str(self.app.config_path or config_module.config_path()),
            "agent": bridge.agent_health(agent),
            "vendor_agent_path": config_module.vendor_agent_path(),
            "runtime": deps_module.runtime_report(),
        })

    def _api_config_post(self, route, settings, agent, runner):
        payload = self._body()
        if payload is None:
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        # Overlay the posted fields on the current config so keys this form
        # does not manage (e.g. the native app's premium toggles) survive a
        # web Settings save.
        combined = dict(settings)
        combined.update(payload)
        saved = self.app.save_config(combined)
        self.app.audit(
            "config.save",
            changed=sorted(set(payload) & config_module._ALLOWED_KEYS),
        )
        return _ok({
            "config": saved,
            "agent": bridge.agent_health(self.app.config()["mlx_agent_path"]),
            "runtime": deps_module.runtime_report(),
        })

    def _api_health(self, route, settings, agent, runner):
        return _ok({
            "agent": bridge.agent_health(agent),
            "runtime": deps_module.runtime_report(),
        })

    def _api_scan(self, route, settings, agent, runner):
        params = parse_qs(urlparse(self.path).query)
        refresh = params.get("refresh", [""])[0] in ("1", "true")
        payload, stale = self.app.cached_scan(settings, agent, runner, refresh=refresh)
        payload = dict(payload)
        payload["cached"] = not refresh
        payload["stale"] = stale
        payload["cached_at"] = time.time()
        return _ok(payload)

    def _api_jobs(self, route, settings, agent, runner):
        payload = bridge.all_job_lists(agent, runner=runner)
        payload["convert_queue"] = self.app.convert_queue.snapshot()
        if self.app.convert_queue.load_error is not None:
            payload["convert_queue_load_error"] = self.app.convert_queue.load_error
        if self.app.convert_queue.last_error is not None:
            payload["convert_queue_error"] = self.app.convert_queue.last_error
        if self.app.worker.last_result is not None:
            payload["convert_worker_result"] = self.app.worker.last_result
        elif self.app.worker.last_error is not None:
            payload["convert_worker_result"] = {
                "status": "failed",
                "error": self.app.worker.last_error,
            }
        return _ok(payload)

    def _api_jobs_log(self, route, settings, agent, runner):
        params = parse_qs(urlparse(self.path).query)
        values = params.get("path") or []
        log_path = values[0] if values else ""
        return _ok(bridge.read_log(agent, log_path, runner=runner))

    def _api_quarantine_list(self, route, settings, agent, runner):
        return _ok({"records": quarantine_module.ledger(settings["quarantine_dir"])})

    def _api_queue_snapshot(self, route, settings, agent, runner):
        return _ok({"queue": self.app.convert_queue.snapshot()})

    def _api_queue_cancel(self, route, settings, agent, runner):
        payload = self._body() or {}
        if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
            return _error("invalid_body", "id is required.", "Retry from the UI.")
        removed = self.app.convert_queue.cancel(payload["id"])
        self.app.worker.wake()
        self.app.audit("queue.cancel", item_id=payload["id"], removed=removed)
        return _ok({
            "removed": removed,
            "queue": self.app.convert_queue.snapshot(),
        })

    def _api_queue_clear(self, route, settings, agent, runner):
        cleared = self.app.convert_queue.clear()
        self.app.worker.wake()
        self.app.audit("queue.clear", cleared=cleared)
        return _ok({
            "cleared": cleared,
            "queue": self.app.convert_queue.snapshot(),
        })

    def _api_queue_retry(self, route, settings, agent, runner):
        payload = self._body() or {}
        if (
            not isinstance(payload, dict)
            or not isinstance(payload.get("id"), str)
            or not payload["id"]
        ):
            return _error("invalid_body", "id is required.", "Retry from the UI.")
        retried = self.app.convert_queue.retry(payload["id"])
        self.app.worker.wake()
        self.app.audit("queue.retry", item_id=payload["id"])
        return _ok({
            "retried": retried,
            "queue": self.app.convert_queue.snapshot(),
        })

    def _api_queue_move(self, route, settings, agent, runner):
        payload = self._body() or {}
        if (
            not isinstance(payload, dict)
            or not isinstance(payload.get("id"), str)
            or not payload["id"]
            or payload.get("direction") not in ("up", "down")
        ):
            return _error(
                "invalid_body",
                "id and direction (up or down) are required.",
                "Retry from the UI.",
            )
        moved = self.app.convert_queue.move(
            payload["id"], payload["direction"],
        )
        self.app.worker.wake()
        self.app.audit("queue.move", item_id=payload["id"], direction=payload["direction"])
        return _ok({
            "moved": moved,
            "queue": self.app.convert_queue.snapshot(),
        })

    def _api_convert(self, route, settings, agent, runner):
        return self._convert_route(route, settings, agent, runner)

    def _api_scout(self, route, settings, agent, runner):
        payload = self._body() or {}
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        role = payload.get("role") or None
        if role is not None and not isinstance(role, str):
            return _error("invalid_body", "role must be a string.", "Pick a role in the UI.")
        limit = payload.get("limit")
        if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool) or limit < 1):
            return _error("invalid_body", "limit must be a positive integer.", "Retry from the UI.")
        fast = payload.get("fast")
        new = payload.get("new")
        if not isinstance(fast, bool) or not isinstance(new, bool):
            return _error(
                "invalid_body", "fast and new must be booleans.", "Retry from the UI."
            )
        return _ok(bridge.discover(
            agent,
            role=role or None,
            limit=limit,
            fast=fast,
            new=new,
            runner=runner,
        ))

    def _api_doctor(self, route, settings, agent, runner):
        payload = self._body() or {}
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        wired = payload.get("wired_roots") or []
        if not isinstance(wired, list) or not all(isinstance(item, str) for item in wired):
            return _error("invalid_body", "wired_roots must be a list of strings.", "Retry from the UI.")
        hf_cache = payload.get("hf_cache")
        if hf_cache is not None and not isinstance(hf_cache, str):
            return _error("invalid_body", "hf_cache must be a string.", "Retry from the UI.")
        return _ok(bridge.doctor_models(
            agent, wired_roots=wired, hf_cache=hf_cache or None, runner=runner,
        ))

    def _api_prune(self, route, settings, agent, runner):
        payload = self._body() or {}
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        hf_cache = payload.get("hf_cache")
        if hf_cache is not None and not isinstance(hf_cache, str):
            return _error("invalid_body", "hf_cache must be a string.", "Retry from the UI.")
        if route.endswith("preview"):
            return _ok(bridge.doctor_prune_preview(
                agent, hf_cache=hf_cache or None, runner=runner,
            ))
        preview_hash = payload.get("preview_hash")
        if not isinstance(preview_hash, str) or not preview_hash:
            return _error(
                "preview_required",
                "Prune needs the hash from its preview.",
                "Preview incomplete snapshots first, then confirm.",
            )
        return _ok(bridge.doctor_prune_confirm(
            agent, preview_hash, hf_cache=hf_cache or None, runner=runner,
        ))

    def _api_lora(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        repo = payload.get("repo")
        data = payload.get("data")
        if not isinstance(repo, str) or not repo.strip():
            return _error("invalid_body", "repo is required.", "Enter a cached base model.")
        if not isinstance(data, str) or not data.strip():
            return _error("invalid_body", "data path is required.", "Point at a dataset dir.")
        iters = payload.get("iters")
        if iters is not None and (not isinstance(iters, int) or isinstance(iters, bool) or iters < 1):
            return _error("invalid_body", "iters must be a positive integer.", "Retry.")
        out = payload.get("out")
        if out is not None and not isinstance(out, str):
            return _error("invalid_body", "out must be a string.", "Retry.")
        if route.endswith("preview"):
            return _ok(bridge.lora_preview(
                agent, repo, data, iters=iters, out=out or None, runner=runner,
            ))
        preview_hash = payload.get("preview_hash")
        if not isinstance(preview_hash, str) or not preview_hash:
            return _error(
                "preview_required",
                "LoRA needs the hash from its preview.",
                "Preview first, then confirm.",
            )
        return _ok(bridge.lora_start(
            agent, repo, data, preview_hash, iters=iters, out=out or None, runner=runner,
        ))

    def _api_fuse(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        repo = payload.get("repo")
        adapter = payload.get("adapter")
        if not isinstance(repo, str) or not repo.strip():
            return _error("invalid_body", "repo is required.", "Enter a cached base model.")
        if not isinstance(adapter, str) or not adapter.strip():
            return _error("invalid_body", "adapter path is required.", "Point at a LoRA adapter.")
        out = payload.get("out")
        if out is not None and not isinstance(out, str):
            return _error("invalid_body", "out must be a string.", "Retry.")
        if route.endswith("preview"):
            return _ok(bridge.fuse_preview(
                agent, repo, adapter, out=out or None, runner=runner,
            ))
        preview_hash = payload.get("preview_hash")
        if not isinstance(preview_hash, str) or not preview_hash:
            return _error(
                "preview_required",
                "Fuse needs the hash from its preview.",
                "Preview first, then confirm.",
            )
        return _ok(bridge.fuse_start(
            agent, repo, adapter, preview_hash, out=out or None, runner=runner,
        ))

    def _api_serve(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        repo = payload.get("repo")
        path = payload.get("path")
        has_repo = isinstance(repo, str) and bool(repo.strip())
        has_path = isinstance(path, str) and bool(path.strip())
        if has_repo == has_path:
            return _error(
                "invalid_body",
                "Provide exactly one of repo (HF cache) or path (local directory).",
                "Pick a cached model or a local model directory in the UI.",
            )
        runtime = payload.get("runtime")
        if runtime not in ("mlx_lm", "mlx-vlm"):
            return _error("invalid_body", "runtime must be mlx_lm or mlx-vlm.", "Pick a runtime.")
        port = payload.get("port")
        if port is not None and (not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535):
            return _error("invalid_body", "port must be 1–65535.", "Retry from the UI.")
        local_path = path if has_path else None
        model_repo = repo.strip() if has_repo else None
        if route.endswith("preview"):
            return _ok(bridge.serve_preview(agent, model_repo, runtime, port, runner=runner, path=local_path))
        preview_hash = payload.get("preview_hash")
        if not isinstance(preview_hash, str) or not preview_hash:
            return _error(
                "preview_required",
                "Confirming a serve plan needs the hash from its preview.",
                "Preview the plan first, then confirm it.",
            )
        started = bridge.serve_start(
            agent, model_repo, runtime, preview_hash, port, runner=runner, path=local_path,
        )
        self.app.audit(
            "serve.start",
            model=model_repo or local_path,
            runtime=runtime,
            port=port,
        )
        return _ok(started)

    def _api_duplicates_scan(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        return _ok(bridge.scan_duplicates(
            agent,
            gguf_roots=config_module.scan_roots(settings),
            mlx_roots=settings["mlx_roots"],
            runner=runner,
        ))

    def _api_model_arch(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        path = payload.get("path")
        if not isinstance(path, str) or not path.strip():
            return _error("invalid_body", "path is required.", "Enter model path.")
        return _ok(bridge.model_architecture(agent, path=path, runner=runner))

    def _api_serve_stop(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict) or not isinstance(payload.get("port"), int):
            return _error("invalid_body", "port is required.", "Retry from the UI.")
        stopped = bridge.serve_stop(agent, payload["port"], runner=runner)
        self.app.audit("serve.stop", port=payload["port"])
        return _ok(stopped)

    def _api_quant_profile(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        path = payload.get("path")
        targets = payload.get("targets")
        if not isinstance(path, str) or not path.strip():
            return _error("invalid_body", "path is required.", "Enter a model path.")
        if not isinstance(targets, list) or not all(isinstance(t, str) for t in targets):
            return _error("invalid_body", "targets must be a list of strings.", "Select formats.")
        return _ok(bridge.quant_profile(agent, path, targets, runner=runner))

    def _api_quarantine_move(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict) or not isinstance(payload.get("path"), str):
            return _error("invalid_body", "A gguf path is required.", "Retry from the UI.")
        record = quarantine_module.quarantine(
            payload["path"],
            config_module.scan_roots(settings),
            settings["quarantine_dir"],
        )
        self.app.audit(
            "quarantine.move",
            source=record.get("from"),
            destination=record.get("to"),
        )
        return _ok({"moved": record})

    def _api_quarantine_delete(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict) or not isinstance(payload.get("path"), str):
            return _error(
                "invalid_body",
                "A quarantined file path is required.",
                "Pick a file from the Quarantine list.",
            )
        result = quarantine_module.purge(
            payload["path"],
            settings["quarantine_dir"],
        )
        self.app.audit(
            "quarantine.delete",
            source=result.get("deleted"),
            bytes=result.get("bytes"),
        )
        return _ok(result)

    def _convert_route(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        path = payload.get("path")
        repo = payload.get("repo")
        out = payload.get("out")
        if _rejects_control_characters(path, repo, out):
            return _error(
                "invalid_body",
                "Path fields must not contain control characters.",
                "Retry with a plain filesystem path.",
            )
        has_path = isinstance(path, str) and bool(path.strip())
        has_repo = isinstance(repo, str) and bool(repo.strip())
        if has_path == has_repo:
            return _error(
                "invalid_body",
                "Provide exactly one of path (GGUF) or repo (HF cache).",
                "Retry from the UI.",
            )
        q_bits = payload.get("q_bits", settings["q_bits"])
        if q_bits not in config_module.Q_BITS_CHOICES:
            return _error("invalid_body", "q_bits must be 4 or 8.", "Pick 4 or 8 in the UI.")
        out = _output_path(settings, payload)
        hf_cache = payload.get("hf_cache")
        if hf_cache is not None and not isinstance(hf_cache, str):
            return _error("invalid_body", "hf_cache must be a string.", "Retry from the UI.")
        hf_cache = hf_cache.strip() if isinstance(hf_cache, str) and hf_cache.strip() else None

        if route.endswith("preview"):
            if has_path:
                return _ok(bridge.preview(agent, path, q_bits, out, runner=runner))
            return _ok(bridge.preview_repo(
                agent, repo.strip(), q_bits, out, hf_cache=hf_cache, runner=runner,
            ))

        preview_hash = payload.get("preview_hash")
        if not isinstance(preview_hash, str) or not preview_hash:
            return _error(
                "preview_required",
                "Confirming a conversion needs the hash from its preview.",
                "Preview the plan first, then confirm it.",
            )

        kind = "gguf" if has_path else "repo"
        label = path if has_path else repo.strip()
        enqueue_kwargs = {
            "kind": kind,
            "preview_hash": preview_hash,
            "q_bits": q_bits,
            "out": out,
            "path": path if has_path else None,
            "repo": repo.strip() if has_repo else None,
            "hf_cache": hf_cache,
            "label": label,
        }

        item = self.app.convert_queue.enqueue(**enqueue_kwargs)
        drain = self.app.convert_queue.try_start_next(agent, runner=runner)
        self.app.worker.wake()
        started_submitted = (
            isinstance(drain, dict)
            and drain.get("status") == "started"
            and isinstance(drain.get("item"), dict)
            and drain["item"].get("id") == item["id"]
        )
        self.app.audit(
            "convert.submit",
            item_id=item["id"],
            model=label,
            q_bits=q_bits,
            state="started" if started_submitted else "queued",
        )
        return _ok({
            "status": "started" if started_submitted else "queued",
            "item": item,
            "drain": drain,
            "queue": self.app.convert_queue.snapshot(),
        })


def _output_path(settings, payload):
    """Where a conversion should write, from the request or the config."""
    explicit = payload.get("out")
    if isinstance(explicit, str) and explicit.strip():
        return str(Path(explicit).expanduser())
    directory = settings.get("output_dir")
    if not directory:
        return None
    path = payload.get("path")
    repo = payload.get("repo")
    if isinstance(path, str) and path.strip():
        stem = Path(path).stem
    elif isinstance(repo, str) and repo.strip():
        stem = repo.strip().replace("/", "--")
    else:
        return None
    q_bits = payload.get("q_bits", settings["q_bits"])
    return str(Path(directory).expanduser() / "{0}-MLX-{1}bit".format(stem, q_bits))


# Exact-match API routes: (method, path) -> Handler method. Prefix routes
# (/, /static/) live in Handler._route; anything absent here is a 404.
_API_ROUTES = {
    ("GET", "/api/config"): Handler._api_config_get,
    ("POST", "/api/config"): Handler._api_config_post,
    ("GET", "/api/health"): Handler._api_health,
    ("GET", "/api/scan"): Handler._api_scan,
    ("GET", "/api/jobs"): Handler._api_jobs,
    ("GET", "/api/jobs/log"): Handler._api_jobs_log,
    ("GET", "/api/quarantine"): Handler._api_quarantine_list,
    ("POST", "/api/quarantine"): Handler._api_quarantine_move,
    ("POST", "/api/quarantine/delete"): Handler._api_quarantine_delete,
    ("POST", "/api/convert/queue"): Handler._api_queue_snapshot,
    ("POST", "/api/convert/queue/cancel"): Handler._api_queue_cancel,
    ("POST", "/api/convert/queue/clear"): Handler._api_queue_clear,
    ("POST", "/api/convert/queue/retry"): Handler._api_queue_retry,
    ("POST", "/api/convert/queue/move"): Handler._api_queue_move,
    ("POST", "/api/convert/preview"): Handler._api_convert,
    ("POST", "/api/convert/start"): Handler._api_convert,
    ("POST", "/api/scout"): Handler._api_scout,
    ("POST", "/api/doctor"): Handler._api_doctor,
    ("POST", "/api/doctor/prune/preview"): Handler._api_prune,
    ("POST", "/api/doctor/prune/confirm"): Handler._api_prune,
    ("POST", "/api/lora/preview"): Handler._api_lora,
    ("POST", "/api/lora/start"): Handler._api_lora,
    ("POST", "/api/fuse/preview"): Handler._api_fuse,
    ("POST", "/api/fuse/start"): Handler._api_fuse,
    ("POST", "/api/serve/preview"): Handler._api_serve,
    ("POST", "/api/serve/start"): Handler._api_serve,
    ("POST", "/api/serve/stop"): Handler._api_serve_stop,
    ("POST", "/api/duplicates/scan"): Handler._api_duplicates_scan,
    ("POST", "/api/model/arch"): Handler._api_model_arch,
    ("POST", "/api/quant/profile"): Handler._api_quant_profile,
}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, app, start_worker=True):
        self.app = app
        ThreadingHTTPServer.__init__(self, address, Handler)
        if start_worker:
            self.app.worker.start()

    def server_close(self):
        try:
            self.app.worker.stop()
        finally:
            ThreadingHTTPServer.server_close(self)


def build(host="127.0.0.1", port=8765, config_path=None, token=None, runner=None,
          start_worker=True, queue_path_override=None, worker_interval=2.0,
          request_slots=MAX_CONCURRENT_REQUESTS, scan_ttl_seconds=60.0):
    """Create a bound server; the caller decides how to run it."""
    app = Application(
        config_path,
        token,
        runner,
        queue_path_override=queue_path_override,
        worker_interval=worker_interval,
        request_slots=request_slots,
        scan_ttl_seconds=scan_ttl_seconds,
    )
    return Server((host, port), app, start_worker=start_worker)
