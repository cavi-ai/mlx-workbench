"""Loopback HTTP server for the mlx-workbench UI. Standard library only."""

from __future__ import annotations

import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import (
    bridge,
    config as config_module,
    convert_queue as convert_queue_module,
    deps as deps_module,
    quarantine as quarantine_module,
)


STATIC_ROOT = Path(__file__).resolve().with_name("static")
MAX_BODY_BYTES = 64 * 1024
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
                 queue_path_override=None, worker_interval=2.0):
        self.config_path = config_path
        self.token = token or secrets.token_urlsafe(24)
        self.runner = runner
        self.lock = threading.Lock()
        state_path = (
            Path(queue_path_override)
            if queue_path_override is not None
            else convert_queue_module.queue_path(config_path)
        )
        self.convert_queue = convert_queue_module.ConvertQueue(path=state_path)
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


def _static(name):
    location = (STATIC_ROOT / name).resolve()
    if not location.is_file() or STATIC_ROOT not in location.parents:
        return 404, "text/plain; charset=utf-8", b"not found"
    content_type = _CONTENT_TYPES.get(location.suffix, "application/octet-stream")
    return 200, content_type, location.read_bytes()


class Handler(BaseHTTPRequestHandler):
    server_version = "mlx-workbench"
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
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'",
        )
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _body(self):
        length = self.headers.get("Content-Length")
        try:
            size = int(length or 0)
        except ValueError:
            return None
        if size <= 0 or size > MAX_BODY_BYTES:
            return None
        try:
            return json.loads(self.rfile.read(size).decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            return None

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
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
        except quarantine_module.QuarantineError as error:
            status, content_type, body = _json_bytes(
                {"status": "error", "error": error.to_dict()}, 400
            )
        except config_module.ConfigError as error:
            status, content_type, body = _error("invalid_config", str(error), "Fix the field and save again.")
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
        if method == "GET" and route == "/api/config":
            return _ok({
                "config": settings,
                "discovered_roots": config_module.discover_gguf_roots(),
                "config_path": str(self.app.config_path or config_module.config_path()),
                "agent": bridge.agent_health(agent),
                "vendor_agent_path": config_module.vendor_agent_path(),
                "runtime": deps_module.runtime_report(),
            })
        if method == "POST" and route == "/api/config":
            payload = self._body()
            if payload is None:
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            return _ok({
                "config": self.app.save_config(payload),
                "agent": bridge.agent_health(self.app.config()["mlx_agent_path"]),
                "runtime": deps_module.runtime_report(),
            })
        if method == "GET" and route == "/api/health":
            return _ok({
                "agent": bridge.agent_health(agent),
                "runtime": deps_module.runtime_report(),
            })
        if method == "GET" and route == "/api/scan":
            return _ok(bridge.scan(
                agent,
                gguf_roots=config_module.scan_roots(settings),
                mlx_roots=settings["mlx_roots"],
                signatures=settings["signatures"],
                runner=runner,
            ))
        if method == "GET" and route == "/api/jobs":
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
        if method == "GET" and route == "/api/jobs/log":
            params = parse_qs(urlparse(self.path).query)
            values = params.get("path") or []
            log_path = values[0] if values else ""
            return _ok(bridge.read_log(agent, log_path, runner=runner))
        if method == "GET" and route == "/api/quarantine":
            return _ok({"records": quarantine_module.ledger(settings["quarantine_dir"])})
        if method == "POST" and route == "/api/convert/queue":
            return _ok({"queue": self.app.convert_queue.snapshot()})
        if method == "POST" and route == "/api/convert/queue/cancel":
            payload = self._body() or {}
            if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
                return _error("invalid_body", "id is required.", "Retry from the UI.")
            removed = self.app.convert_queue.cancel(payload["id"])
            self.app.worker.wake()
            return _ok({
                "removed": removed,
                "queue": self.app.convert_queue.snapshot(),
            })
        if method == "POST" and route == "/api/convert/queue/clear":
            cleared = self.app.convert_queue.clear()
            self.app.worker.wake()
            return _ok({
                "cleared": cleared,
                "queue": self.app.convert_queue.snapshot(),
            })
        if method == "POST" and route in ("/api/convert/preview", "/api/convert/start"):
            return self._convert_route(route, settings, agent, runner)
        if method == "POST" and route == "/api/scout":
            payload = self._body() or {}
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            role = payload.get("role") or None
            if role is not None and not isinstance(role, str):
                return _error("invalid_body", "role must be a string.", "Pick a role in the UI.")
            limit = payload.get("limit")
            if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool) or limit < 1):
                return _error("invalid_body", "limit must be a positive integer.", "Retry from the UI.")
            return _ok(bridge.discover(
                agent,
                role=role or None,
                limit=limit,
                fast=bool(payload.get("fast")),
                new=bool(payload.get("new")),
                runner=runner,
            ))
        if method == "POST" and route == "/api/doctor":
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
        if method == "POST" and route in ("/api/doctor/prune/preview", "/api/doctor/prune/confirm"):
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
        if method == "POST" and route == "/api/adopt/start":
            payload = self._body() or {}
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            role = payload.get("role")
            state = payload.get("state")
            if role is not None and not isinstance(role, str):
                return _error("invalid_body", "role must be a string.", "Pick a role.")
            if state is not None and not isinstance(state, str):
                return _error("invalid_body", "state must be a path string.", "Retry.")
            return _ok(bridge.adopt_start(
                agent,
                role=role or None,
                state=state or None,
                fast=bool(payload.get("fast")),
                offline=bool(payload.get("offline")),
                runner=runner,
            ))
        if method == "POST" and route == "/api/adopt/status":
            payload = self._body() or {}
            if not isinstance(payload, dict) or not isinstance(payload.get("state"), str):
                return _error("invalid_body", "state path is required.", "Retry from the UI.")
            return _ok(bridge.adopt_status(agent, payload["state"], runner=runner))
        if method == "POST" and route in ("/api/wire/preview", "/api/wire/apply"):
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            model = payload.get("model")
            path = payload.get("path")
            target = payload.get("target") or "mlx_lm"
            if not isinstance(model, str) or not model.strip():
                return _error("invalid_body", "model is required.", "Enter a repo id.")
            if not isinstance(path, str) or not path.strip():
                return _error("invalid_body", "path is required.", "Enter a config file path.")
            if target not in ("ollama", "lmstudio", "mlx_lm", "mlx-vlm", "litellm"):
                return _error("invalid_body", "unsupported wire target.", "Pick a target.")
            if route.endswith("preview"):
                return _ok(bridge.wire_preview(agent, model, path, target, runner=runner))
            preview_hash = payload.get("preview_hash")
            if not isinstance(preview_hash, str) or not preview_hash:
                return _error(
                    "preview_required",
                    "Wire apply needs the hash from its preview.",
                    "Preview first, then confirm.",
                )
            return _ok(bridge.wire_apply(
                agent, model, path, preview_hash, target, runner=runner,
            ))
        if method == "POST" and route in ("/api/lora/preview", "/api/lora/start"):
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
        if method == "POST" and route in ("/api/fuse/preview", "/api/fuse/start"):
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
        if method == "POST" and route in ("/api/serve/preview", "/api/serve/start"):
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            repo = payload.get("repo")
            runtime = payload.get("runtime")
            if not isinstance(repo, str) or not repo.strip():
                return _error("invalid_body", "repo is required.", "Enter a cached model id.")
            if runtime not in ("mlx_lm", "mlx-vlm"):
                return _error("invalid_body", "runtime must be mlx_lm or mlx-vlm.", "Pick a runtime.")
            port = payload.get("port")
            if port is not None and (not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535):
                return _error("invalid_body", "port must be 1–65535.", "Retry from the UI.")
            if route.endswith("preview"):
                return _ok(bridge.serve_preview(agent, repo, runtime, port, runner=runner))
            preview_hash = payload.get("preview_hash")
            if not isinstance(preview_hash, str) or not preview_hash:
                return _error(
                    "preview_required",
                    "Confirming a serve plan needs the hash from its preview.",
                    "Preview the plan first, then confirm it.",
                )
            return _ok(bridge.serve_start(
                agent, repo, runtime, preview_hash, port, runner=runner,
            ))
        if method == "POST" and route == "/api/duplicates/scan":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            return _ok(bridge.scan_duplicates(agent, runner=runner))

        if method == "POST" and route == "/api/model/arch":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            path = payload.get("path")
            if not isinstance(path, str) or not path.strip():
                return _error("invalid_body", "path is required.", "Enter model path.")
            return _ok(bridge.model_architecture(agent, path=path or None, runner=runner))

        if method == "POST" and route == "/api/training/dataset/score":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            path = payload.get("path")
            if not isinstance(path, str) or not path.strip():
                return _error("invalid_body", "path is required.", "Enter dataset directory.")
            return _ok(bridge.dataset_score(agent, path=path or None, runner=runner))
        
        if method == "POST" and route == "/api/training/preview":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            base_model = payload.get("base_model")
            dataset_path = payload.get("dataset_path")
            iters = payload.get("iters")
            lr = payload.get("learning_rate", "2e-5")
            
            if not isinstance(base_model, str) or not base_model.strip():
                return _error("invalid_body", "base_model is required.", "Enter model repo.")
            if not isinstance(dataset_path, str) or not dataset_path.strip():
                return _error("invalid_body", "dataset_path is required.", "Enter dataset directory.")
            
            return _ok(bridge.finetune_preview(
                agent, base_model, dataset_path,
                iters=iters, learning_rate=lr, runner=runner
            ))

        if method == "POST" and route == "/api/serve/metrics":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            port = payload.get("port")
            if not isinstance(port, int) or isinstance(port, bool):
                return _error("invalid_body", "port is required.", "Enter a server port.")
            return _ok(bridge.serve_metrics(agent, port, runner=runner))

        if method == "POST" and route == "/api/serve/stop":
            payload = self._body()
            if not isinstance(payload, dict) or not isinstance(payload.get("port"), int):
                return _error("invalid_body", "port is required.", "Retry from the UI.")
            return _ok(bridge.serve_stop(agent, payload["port"], runner=runner))
        if method == "POST" and route == "/api/sloth/connect":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            address = payload.get("address")
            if not isinstance(address, str):
                return _error("invalid_body", "address is required.", "Enter a server address.")
            return _ok(bridge.sloth_connect(agent, address=address or "http://localhost:3000", runner=runner))

        if method == "POST" and route == "/api/cli":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            argv = payload.get("argv")
            return _ok(bridge.run_cli(agent, argv, runner=runner))
        if method == "POST" and route == "/api/lmstudio/import":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            source = payload.get("source_dir")
            if source is not None and not isinstance(source, str):
                return _error("invalid_body", "source_dir must be a string.", "Retry.")
            convert = payload.get("convert_immediately", True)
            if not isinstance(convert, bool):
                return _error("invalid_body", "convert_immediately must be a boolean.", "Retry.")
            return _ok(bridge.lmstudio_import(agent, source_dir=source or None, convertImmediately=convert))
        if method == "POST" and route == "/api/quant/profile":
            payload = self._body()
            if not isinstance(payload, dict):
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            path = payload.get("path")
            targets = payload.get("targets")
            if not isinstance(path, str) or not path.strip():
                return _error("invalid_body", "path is required.", "Enter a model path.")
            if not isinstance(targets, list) or not all(isinstance(t, str) for t in targets):
                return _error("invalid_body", "targets must be a list of strings.", "Select formats.")
            return _ok(bridge.quant_profile(agent, path, targets))
        if method == "POST" and route == "/api/quarantine":
            payload = self._body()
            if not isinstance(payload, dict) or not isinstance(payload.get("path"), str):
                return _error("invalid_body", "A gguf path is required.", "Retry from the UI.")
            record = quarantine_module.quarantine(
                payload["path"],
                config_module.scan_roots(settings),
                settings["quarantine_dir"],
            )
            return _ok({"moved": record})
        return 404, "text/plain; charset=utf-8", b"not found"

    def _convert_route(self, route, settings, agent, runner):
        payload = self._body()
        if not isinstance(payload, dict):
            return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
        path = payload.get("path")
        repo = payload.get("repo")
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
          start_worker=True, queue_path_override=None, worker_interval=2.0):
    """Create a bound server; the caller decides how to run it."""
    app = Application(
        config_path,
        token,
        runner,
        queue_path_override=queue_path_override,
        worker_interval=worker_interval,
    )
    return Server((host, port), app, start_worker=start_worker)
