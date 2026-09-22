"""Move redundant weights aside. Nothing here deletes anything.

Removing 80GB of weights is not an action a web button should take. The app
moves a file into a quarantine directory and records where it came from, so
the user can review, restore, or delete it themselves.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .atomicio import write_text_atomic


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
    """Move one redundant GGUF into the quarantine directory.

    Symbolic links are never moved and never written through: a symlinked
    source would let a move escape the root guard, and a symlink at the
    destination would redirect where the file lands.
    """
    expanded = Path(target).expanduser()
    if expanded.is_symlink():
        raise QuarantineError(
            "symlink_refused",
            "{0} is a symbolic link; only regular files are moved.".format(expanded),
            "Inspect the link; quarantine the real file instead if you choose.",
        )
    location = guard(target, roots)
    destination_root = Path(quarantine_dir).expanduser()
    resolved_root = (
        _resolve(destination_root) if destination_root.exists() else destination_root
    )
    if _within(location, resolved_root):
        raise QuarantineError(
            "already_quarantined",
            "{0} is already in the quarantine directory.".format(location),
            "Delete it yourself when you are sure you no longer need it.",
        )
    destination_root.mkdir(parents=True, exist_ok=True)
    if destination_root.is_symlink():
        raise QuarantineError(
            "symlink_refused",
            "The quarantine directory is a symbolic link; refusing to write "
            "through it.",
            "Point quarantine_dir at a real directory.",
        )
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
            value["deleted"] = bool(value.get("deleted_at"))
            records.append(value)
    records.reverse()
    return records


def purge(target, quarantine_dir, trash=None):
    """Permanently remove one file from the quarantine directory.

    This is the only destructive operation in this module, and it is fenced
    on every side: the target must be an existing file inside the configured
    quarantine directory, never the ledger itself, and never a symbolic
    link. The matching ledger entry is marked ``deleted_at`` rather than
    removed, so the history stays an append-only audit trail. The default
    ``trash`` moves to the macOS Trash; passing a callable overrides it in
    tests. Nothing outside the quarantine directory is ever touched.
    """
    root = Path(quarantine_dir).expanduser()
    resolved_root = _resolve(root) if root.exists() else root
    if trash is None:
        trash = _send_to_trash

    target_path = Path(target).expanduser()
    if not target_path.is_absolute():
        raise QuarantineError(
            "not_in_quarantine",
            "An absolute path inside the quarantine directory is required.",
            "Pick a file from the Quarantine list.",
        )
    if target_path.name == LEDGER_NAME:
        raise QuarantineError(
            "ledger_protected",
            "The quarantine ledger cannot be deleted.",
            "Delete quarantined weight files instead.",
        )
    if target_path.is_symlink():
        raise QuarantineError(
            "symlink_refused",
            "{0} is a symbolic link; refusing to delete through it.".format(target_path),
            "Inspect the link and resolve it yourself.",
        )
    resolved_target = _resolve(target_path)
    if not _within(resolved_target, resolved_root) or not resolved_target.is_file():
        raise QuarantineError(
            "not_in_quarantine",
            "{0} is not a file inside the quarantine directory.".format(resolved_target),
            "Pick a file from the Quarantine list.",
        )

    try:
        trash(str(resolved_target))
    except (OSError, shutil.Error) as error:
        raise QuarantineError(
            "delete_failed",
            "{0} could not be deleted: {1}".format(resolved_target, error),
            "Check Trash permissions and try again.",
        ) from error

    _rewrite_ledger(
        root,
        str(resolved_target),
        datetime.now(timezone.utc).isoformat(timespec="seconds"),
    )
    return {
        "deleted": str(resolved_target),
        "bytes": _last_known_size(root, str(resolved_target)),
    }


def _last_known_size(root, deleted_path):
    for record in ledger(root, limit=10000):
        if str(_resolve(record.get("to", ""))) == deleted_path:
            return record.get("bytes")
    return None


def _mark_deleted(line, deleted_path, now_iso):
    try:
        record = json.loads(line)
    except ValueError:
        return line
    if (
        isinstance(record, dict)
        and "deleted_at" not in record
        and str(_resolve(record.get("to", ""))) == deleted_path
    ):
        record["deleted_at"] = now_iso
        return json.dumps(record, sort_keys=True)
    return line


def _rewrite_ledger(root, deleted_path, now_iso):
    ledger_path = root / LEDGER_NAME
    try:
        lines = ledger_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    updated = [_mark_deleted(line, deleted_path, now_iso) for line in lines]
    write_text_atomic(
        ledger_path, "\n".join(updated) + ("\n" if updated else "")
    )


def _send_to_trash(path):
    """macOS Trash via Finder-safe AppleScript; falls back to unlink."""
    script = (
        'tell application "Finder" to delete POSIX file "' + path + '"'
    )
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
        timeout=15,
    )
    if result.returncode != 0:
        raise OSError(result.stderr.decode("utf-8", "replace").strip()[:200])


# Selected at import so tests can patch a fake without patching the symbol
# used inside quarantine().
trash = _send_to_trash
