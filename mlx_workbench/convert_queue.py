"""In-memory convert queue. Serializes jobs under mlx-agent's one-job rule."""

from __future__ import annotations

import itertools
import threading

from . import bridge


class ConvertQueue:
    """Process-local FIFO of reviewed convert plans."""

    def __init__(self):
        self._lock = threading.Lock()
        self._drain_lock = threading.Lock()
        self._items = []
        self._ids = itertools.count(1)
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
        }
        with self._lock:
            self._items.append(item)
        return dict(item)

    def snapshot(self):
        with self._lock:
            return [dict(item) for item in self._items]

    def cancel(self, item_id):
        with self._lock:
            kept = [item for item in self._items if item["id"] != item_id]
            removed = len(kept) != len(self._items)
            self._items = kept
        return removed

    def clear(self):
        with self._lock:
            count = len(self._items)
            self._items = []
        return count

    def try_start_next(self, agent_path, runner=None):
        """Start the head item if no convert is live. Returns a status dict or None."""
        with self._drain_lock:
            return self._try_start_next(agent_path, runner=runner)

    def _try_start_next(self, agent_path, runner=None):
        with self._lock:
            if not self._items:
                return None
        if bridge.convert_is_busy(agent_path, runner=runner):
            return None
        with self._lock:
            if not self._items:
                return None
            item = self._items.pop(0)
        try:
            if item["kind"] == "gguf":
                result = bridge.start(
                    agent_path,
                    item["path"],
                    item["preview_hash"],
                    q_bits=item["q_bits"],
                    out=item.get("out"),
                    runner=runner,
                )
            else:
                result = bridge.start_repo(
                    agent_path,
                    item["repo"],
                    item["preview_hash"],
                    q_bits=item["q_bits"],
                    out=item.get("out"),
                    hf_cache=item.get("hf_cache"),
                    runner=runner,
                )
            self.last_error = None
            return {"status": "started", "item": item, "result": result}
        except bridge.BridgeError as error:
            if error.code == "job_in_progress":
                with self._lock:
                    self._items.insert(0, item)
                return None
            payload = {"status": "failed", "item": item, "error": error.to_dict()}
            self.last_error = payload
            return payload
