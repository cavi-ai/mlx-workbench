"""Durable convert queue. Serializes jobs under mlx-agent's one-job rule."""

from __future__ import annotations

import json
import itertools
import os
import threading
from pathlib import Path

from . import bridge


QUEUE_SCHEMA_VERSION = "1.0"
QUEUE_FILENAME = "convert-queue.json"
ITEM_STATES = ("queued", "starting")
QUEUE_ITEM_KEYS = {
    "id", "kind", "preview_hash", "q_bits", "out", "path", "repo",
    "hf_cache", "label", "state",
}


def queue_path(config_path=None):
    """Return the durable queue path for a config profile or default state."""
    if config_path is not None:
        return Path(config_path).expanduser().with_name(QUEUE_FILENAME)
    state_home = os.environ.get("XDG_STATE_HOME")
    root = Path(state_home).expanduser() if state_home else Path.home() / ".local" / "state"
    return root / "mlx-workbench" / QUEUE_FILENAME


class QueuePersistenceError(RuntimeError):
    """A classified failure to load or persist durable queue state."""

    def __init__(self, code, message, remediation, path=None, preserved_path=None):
        super().__init__(message)
        self.code = code
        self.remediation = remediation
        self.path = str(path) if path is not None else None
        self.preserved_path = (
            str(preserved_path) if preserved_path is not None else None
        )

    def to_dict(self):
        payload = {
            "code": self.code,
            "message": str(self),
            "remediation": self.remediation,
        }
        if self.path is not None:
            payload["path"] = self.path
        if self.preserved_path is not None:
            payload["preserved_path"] = self.preserved_path
        return payload


def _optional_string(value):
    return value is None or (isinstance(value, str) and bool(value))


def _validate_item(item):
    if not isinstance(item, dict) or set(item) != QUEUE_ITEM_KEYS:
        raise ValueError("queue item fields do not match schema")
    item_id = item["id"]
    if (
        not isinstance(item_id, str)
        or not item_id.startswith("cq-")
        or not item_id[3:].isdigit()
    ):
        raise ValueError("queue item id is invalid")
    if item["kind"] not in ("gguf", "repo"):
        raise ValueError("queue item kind is invalid")
    if not isinstance(item["preview_hash"], str) or not item["preview_hash"]:
        raise ValueError("queue item preview_hash is invalid")
    if isinstance(item["q_bits"], bool) or item["q_bits"] not in (4, 8):
        raise ValueError("queue item q_bits is invalid")
    for field in ("out", "path", "repo", "hf_cache"):
        if not _optional_string(item[field]):
            raise ValueError("queue item {0} is invalid".format(field))
    if not isinstance(item["label"], str) or not item["label"]:
        raise ValueError("queue item label is invalid")
    if item["state"] not in ITEM_STATES:
        raise ValueError("queue item state is invalid")
    if item["kind"] == "gguf":
        if not item["path"] or item["repo"] is not None:
            raise ValueError("GGUF queue item requires only path")
    elif not item["repo"] or item["path"] is not None:
        raise ValueError("repo queue item requires only repo")


def _validated_items(payload):
    if not isinstance(payload, dict):
        raise ValueError("queue state must be an object")
    if set(payload) != {"schema_version", "items"}:
        raise ValueError("queue state fields do not match schema")
    if payload["schema_version"] != QUEUE_SCHEMA_VERSION:
        raise ValueError("queue schema version is unsupported")
    if not isinstance(payload["items"], list):
        raise ValueError("queue items must be a list")
    for item in payload["items"]:
        _validate_item(item)
    return [dict(item) for item in payload["items"]]


class QueueStore:
    """Atomically persist schema-versioned conversion queue snapshots."""

    def __init__(self, path):
        self.path = Path(path)

    def load(self):
        if not self.path.exists():
            return []
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            return _validated_items(payload)
        except (OSError, UnicodeError, ValueError, TypeError, KeyError) as error:
            preserved = self._preserve_corrupt()
            raise QueuePersistenceError(
                "queue_state_invalid",
                "The saved conversion queue is invalid: {0}".format(error),
                "Inspect the preserved corrupt file, then submit conversions again.",
                path=self.path,
                preserved_path=preserved,
            ) from error

    def save(self, items):
        items = _validated_items({
            "schema_version": QUEUE_SCHEMA_VERSION,
            "items": items,
        })
        temporary = self.path.with_name(self.path.name + ".tmp")
        payload = {
            "schema_version": QUEUE_SCHEMA_VERSION,
            "items": items,
        }
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            os.replace(temporary, self.path)
        except (OSError, UnicodeError) as error:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            raise QueuePersistenceError(
                "queue_write_failed",
                "The conversion queue could not be saved: {0}".format(error),
                "Check the state directory permissions and available disk space, then retry.",
                path=self.path,
            ) from error

    def _preserve_corrupt(self):
        suffix = 1
        while True:
            preserved = self.path.with_name(
                "{0}.{1}.corrupt".format(self.path.name, suffix)
            )
            if not preserved.exists():
                os.replace(self.path, preserved)
                return preserved
            suffix += 1


class _MemoryQueueStore:
    """Non-persistent store used by explicitly in-memory queue instances."""

    def __init__(self):
        self.items = []

    def load(self):
        return [dict(item) for item in self.items]

    def save(self, items):
        self.items = [dict(item) for item in items]


class ConvertQueue:
    """FIFO of reviewed convert plans with optional durable persistence."""

    def __init__(self, path=None, store=None):
        self._lock = threading.Lock()
        self._drain_lock = threading.Lock()
        self.store = store or (QueueStore(path) if path is not None else _MemoryQueueStore())
        self.load_error = None
        try:
            self._items = self.store.load()
        except QueuePersistenceError as error:
            self._items = []
            self.load_error = error.to_dict()
        next_id = max(
            (int(item["id"][3:]) for item in self._items),
            default=0,
        ) + 1
        self._ids = itertools.count(next_id)
        self.last_error = None

    def enqueue(self, kind, preview_hash, q_bits, out=None, path=None, repo=None,
                label=None, hf_cache=None):
        if kind not in ("gguf", "repo"):
            raise ValueError("kind must be gguf or repo")
        if not isinstance(preview_hash, str) or not preview_hash:
            raise ValueError("preview_hash is required")
        item = {
            "id": "cq-{0}".format(next(self._ids)),
            "kind": kind,
            "preview_hash": preview_hash,
            "q_bits": q_bits,
            "out": out,
            "path": path,
            "repo": repo,
            "hf_cache": hf_cache,
            "label": label or path or repo or "convert",
            "state": "queued",
        }
        with self._lock:
            self._publish_locked(self._items + [item])
        return dict(item)

    def _publish_locked(self, candidate):
        self.store.save(candidate)
        self._items = candidate

    def snapshot(self):
        with self._lock:
            return [dict(item) for item in self._items]

    def cancel(self, item_id):
        with self._lock:
            kept = [item for item in self._items if item["id"] != item_id]
            removed = len(kept) != len(self._items)
            if removed:
                self._publish_locked(kept)
        return removed

    def clear(self):
        with self._lock:
            count = len(self._items)
            if count:
                self._publish_locked([])
        return count

    def try_start_next(self, agent_path, runner=None):
        """Start the head item if no convert is live. Returns a status dict or None."""
        with self._drain_lock:
            return self._try_start_next(agent_path, runner=runner)

    def _try_start_next(self, agent_path, runner=None):
        with self._lock:
            if not self._items:
                return None
            item = dict(self._items[0])
        status = bridge.jobs(agent_path, runner=runner)
        raw_jobs = status.get("jobs")
        if raw_jobs is None:
            raw_jobs = []
        elif not isinstance(raw_jobs, list):
            raise bridge.BridgeError(
                "job_status_invalid",
                "convert status did not return a job list.",
                "Retry conversion and upgrade mlx-agent if the issue persists.",
            )
        entries = [entry for entry in raw_jobs if isinstance(entry, dict)]

        if item["state"] == "starting":
            try:
                receipts = bridge.read_convert_receipts(entries)
            except bridge.BridgeError as error:
                payload = {
                    "status": "waiting_recovery",
                    "item": item,
                    "error": error.to_dict(),
                }
                self.last_error = payload
                return payload
            if any(self._receipt_matches(item, receipt) for receipt in receipts):
                with self._lock:
                    if self._items and self._items[0]["id"] == item["id"]:
                        self._publish_locked(self._items[1:])
                self.last_error = None
                return {"status": "recovered", "item": item}
            queued = dict(item, state="queued")
            with self._lock:
                if self._items and self._items[0]["id"] == item["id"]:
                    self._publish_locked([queued] + self._items[1:])
            item = queued

        if any(entry.get("state") == "running" for entry in entries):
            return None

        starting = dict(item, state="starting")
        with self._lock:
            if not self._items or self._items[0]["id"] != item["id"]:
                return None
            self._publish_locked([starting] + self._items[1:])
        try:
            if starting["kind"] == "gguf":
                result = bridge.start(
                    agent_path,
                    starting["path"],
                    starting["preview_hash"],
                    q_bits=starting["q_bits"],
                    out=starting.get("out"),
                    runner=runner,
                )
            else:
                result = bridge.start_repo(
                    agent_path,
                    starting["repo"],
                    starting["preview_hash"],
                    q_bits=starting["q_bits"],
                    out=starting.get("out"),
                    hf_cache=starting.get("hf_cache"),
                    runner=runner,
                )
            try:
                with self._lock:
                    if self._items and self._items[0]["id"] == starting["id"]:
                        self._publish_locked(self._items[1:])
            except QueuePersistenceError as error:
                persistence_error = error.to_dict()
                self.last_error = {
                    "status": "waiting_recovery",
                    "item": starting,
                    "error": persistence_error,
                }
                return {
                    "status": "started",
                    "item": starting,
                    "result": result,
                    "persistence_error": persistence_error,
                }
            self.last_error = None
            return {"status": "started", "item": starting, "result": result}
        except bridge.BridgeError as error:
            if error.code == "job_in_progress":
                with self._lock:
                    if self._items and self._items[0]["id"] == starting["id"]:
                        queued = dict(starting, state="queued")
                        self._publish_locked([queued] + self._items[1:])
                return None
            with self._lock:
                if self._items and self._items[0]["id"] == starting["id"]:
                    self._publish_locked(self._items[1:])
            payload = {
                "status": "failed",
                "item": starting,
                "error": error.to_dict(),
            }
            self.last_error = payload
            return payload

    @staticmethod
    def _receipt_matches(item, receipt):
        if not isinstance(receipt, dict):
            return False
        if receipt.get("preview_hash") != item["preview_hash"]:
            return False
        if receipt.get("out") != item.get("out"):
            return False
        if receipt.get("q_bits") != item["q_bits"]:
            return False
        source = receipt.get("source")
        if not isinstance(source, dict):
            return False
        if item["kind"] == "gguf":
            return source.get("path") == item["path"]
        return source.get("repo") == item["repo"]
