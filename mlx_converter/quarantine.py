"""Move redundant weights aside. Nothing here deletes anything.

Removing 80GB of weights is not an action a web button should take. The app
moves a file into a quarantine directory and records where it came from, so
the user can review, restore, or delete it themselves.
"""

from __future__ import annotations

import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path


LEDGER_NAME = "quarantine-ledger.jsonl"
MAX_LEDGER_BYTES = 4 * 1024 * 1024


class QuarantineError(RuntimeError):
    """A classified refusal to move a file."""

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


def _resolve(path):
    try:
        return Path(path).expanduser().resolve()
    except OSError as error:
        raise QuarantineError(
            "path_unreadable",
            "{0} could not be resolved.".format(path),
            "Check the path and its permissions.",
        ) from error


def _within(child, parent):
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


def guard(target, roots):
    """Allow only .gguf files that live under a configured scan root."""
    location = _resolve(target)
    if location.suffix.lower() != ".gguf":
        raise QuarantineError(
            "not_a_gguf",
            "Only .gguf files can be moved from here.",
            "Move anything else yourself, deliberately.",
        )
    if not location.is_file():
        raise QuarantineError(
            "not_found",
            "No file at {0}.".format(location),
            "Rescan; the file may already have been moved.",
        )
    allowed = [_resolve(root) for root in roots if str(root).strip()]
    if not any(_within(location, root) for root in allowed):
        raise QuarantineError(
            "outside_roots",
            "{0} is not under any configured scan root.".format(location),
            "Add its directory to gguf_roots first, or move the file yourself.",
        )
    return location


def _stamp(clock=None):
    now = (clock or (lambda: datetime.now(timezone.utc)))()
    return now.strftime("%Y%m%dT%H%M%SZ"), now.isoformat()


def quarantine(target, roots, quarantine_dir, clock=None, move=shutil.move):
    """Move one redundant GGUF into the quarantine directory."""
    location = guard(target, roots)
    destination_root = Path(quarantine_dir).expanduser()
    if _within(location, _resolve(destination_root) if destination_root.exists() else destination_root):
        raise QuarantineError(
            "already_quarantined",
            "{0} is already in the quarantine directory.".format(location),
            "Delete it yourself when you are sure you no longer need it.",
        )
    destination_root.mkdir(parents=True, exist_ok=True)
    stamp, iso = _stamp(clock)
    destination = destination_root / "{0}-{1}".format(stamp, location.name)
    suffix = 1
    while destination.exists():
        destination = destination_root / "{0}-{1}-{2}".format(stamp, suffix, location.name)
        suffix += 1
    size = location.stat().st_size
    try:
        move(str(location), str(destination))
    except (OSError, shutil.Error) as error:
        raise QuarantineError(
            "move_failed",
            "{0} could not be moved: {1}".format(location, error),
            "Check free space and permissions on the quarantine directory.",
        ) from error
    record = {
        "moved_at": iso,
        "from": str(location),
        "to": str(destination),
        "bytes": size,
    }
    _append_ledger(destination_root, record)
    return record


def _append_ledger(root, record):
    ledger = Path(root) / LEDGER_NAME
    try:
        if ledger.exists() and ledger.stat().st_size > MAX_LEDGER_BYTES:
            return
        with ledger.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        return


def ledger(quarantine_dir, limit=200):
    """Read recent quarantine records, newest first."""
    location = Path(quarantine_dir).expanduser() / LEDGER_NAME
    try:
        lines = location.read_text(encoding="utf-8").splitlines()
    except (OSError, ValueError):
        return []
    records = []
    for line in lines[-limit:]:
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            value["exists"] = os.path.exists(value.get("to", ""))
            records.append(value)
    records.reverse()
    return records
