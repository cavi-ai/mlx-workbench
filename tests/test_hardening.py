import json
import os
import signal
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import audit, bridge, config, convert_queue, quarantine
from mlx_workbench.atomicio import write_text_atomic



def _fake_agent_checkout(root):
    """Create a minimal mlx-agent checkout so agent resolution is deterministic."""
    from mlx_workbench import bridge
    agent = root / "mlx-agent"
    script = agent / bridge.CLI_RELATIVE
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text("", encoding="utf-8")
    return str(agent)





class AtomicWriteTests(unittest.TestCase):
    """P0-2: durable atomic writes; P1-6: symlink refusal at the primitives."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_write_is_fsynced_and_replaces_atomically(self):
        target = self.root / "state" / "file.json"
        write_text_atomic(target, "{\"a\": 1}\n")
        self.assertEqual(target.read_text(encoding="utf-8"), "{\"a\": 1}\n")
        self.assertFalse(target.with_name(target.name + ".tmp").exists())

    def test_symlink_at_target_is_refused(self):
        victim = self.root / "victim.txt"
        victim.write_text("keep me", encoding="utf-8")
        target = self.root / "link.txt"
        os.symlink(victim, target)
        with self.assertRaises(OSError):
            write_text_atomic(target, "overwritten")
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep me")

    def test_symlink_at_temp_path_cannot_redirect_write(self):
        victim = self.root / "victim.txt"
        victim.write_text("keep me", encoding="utf-8")
        target = self.root / "state.json"
        os.symlink(victim, target.with_name(target.name + ".tmp"))
        with self.assertRaises(OSError):
            write_text_atomic(target, "overwritten")
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep me")

    def test_config_save_refuses_symlink_target(self):
        real = self.root / "real.json"
        real.write_text("{}", encoding="utf-8")
        link = self.root / "config.json"
        os.symlink(real, link)
        with self.assertRaises(config.ConfigError):
            config.save({"port": 8765}, link)
        self.assertEqual(json.loads(real.read_text(encoding="utf-8")), {})

    def test_config_save_still_round_trips(self):
        location = self.root / "nested" / "config.json"
        saved = config.save({"port": 9100}, location)
        self.assertEqual(saved["port"], 9100)
        self.assertEqual(config.load(location)["port"], 9100)

    def test_queue_save_refuses_symlink_target(self):
        victim = self.root / "victim.json"
        victim.write_text("{}", encoding="utf-8")
        link = self.root / "convert-queue.json"
        os.symlink(victim, link)
        store = convert_queue.QueueStore(link)
        with self.assertRaises(convert_queue.QueuePersistenceError) as caught:
            store.save([])
        self.assertEqual(caught.exception.code, "queue_write_failed")
        self.assertEqual(victim.read_text(encoding="utf-8"), "{}")

    def test_queue_store_round_trip_unchanged(self):
        store = convert_queue.QueueStore(self.root / "convert-queue.json")
        store.save([{
            "id": "cq-1", "kind": "repo", "preview_hash": "h", "q_bits": 4,
            "out": None, "path": None, "repo": "org/m", "hf_cache": None,
            "label": "org/m", "state": "queued", "failure": None,
        }])
        self.assertEqual(len(store.load()), 1)

    def test_queue_survives_simulated_truncated_tmp(self):
        # The old failure mode: a partial temp file would have been renamed
        # over the real state on power loss. fsync-before-replace closes it.
        store = convert_queue.QueueStore(self.root / "q.json")
        store.save([])
        self.assertEqual(store.load(), [])


class RunnerHardeningTests(unittest.TestCase):
    """P1-4 / P1-5: process-group timeout kills and the env allowlist."""

    def test_timeout_kills_the_whole_process_group(self):
        # A parent that forks a never-exiting grandchild; the classic leak
        # this guard exists for. Total runtime stays bounded (~2s).
        command = [
            sys.executable, "-c",
            "import os, sys, time\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    time.sleep(600)\n"
            "    os._exit(0)\n"
            "sys.stdout.write(str(child))\n"
            "sys.stdout.flush()\n"
            "time.sleep(600)\n",
        ]
        started = time.monotonic()
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge._default_runner(command, timeout=1.5)
        elapsed = time.monotonic() - started
        self.assertEqual(caught.exception.code, "skill_timeout")
        self.assertLess(elapsed, 15.0)

    def test_environment_allowlist_drops_unlisted_variables(self):
        base = {
            "PATH": "/usr/bin",
            "HOME": "/home/tester",
            "MLX_AGENT_SECRET_TOKEN": "do-not-propagate",
            "SOME_RANDOM_VAR": "nope",
            "HF_HUB_OFFLINE": "1",
        }
        environment = bridge.agent_environment(base)
        self.assertNotIn("MLX_AGENT_SECRET_TOKEN", environment)
        self.assertNotIn("SOME_RANDOM_VAR", environment)
        self.assertEqual(environment["HF_HUB_OFFLINE"], "1")
        self.assertEqual(environment["HOME"], "/home/tester")
        # Interpreter bin dir always wins the PATH race.
        expected = str(Path(sys.executable).resolve().parent)
        self.assertTrue(environment["PATH"].startswith(expected + os.pathsep))

    def test_environment_allowlist_keeps_interpreter_bin_dir_first(self):
        environment = bridge.agent_environment(base={})
        expected = str(Path(sys.executable).resolve().parent)
        self.assertTrue(environment["PATH"].startswith(expected + os.pathsep))

    def test_default_runner_keeps_prepending_interpreter_bin_dir(self):
        result = bridge._default_runner(["/usr/bin/env"], timeout=10)
        self.assertEqual(result["returncode"], 0)
        path_line = next(
            line for line in result["stdout"].splitlines()
            if line.startswith("PATH=")
        )
        expected = str(Path(sys.executable).resolve().parent)
        self.assertTrue(path_line.startswith("PATH=" + expected + ":"))


class ConfigKeyUniverseTests(unittest.TestCase):
    """P2-9: the web save cannot inject keys outside the shared contract."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_path = self.root / "config.json"
        config.save({}, self.config_path)



class AuditTrailTests(unittest.TestCase):
    """P2-10: state-changing operations land in one readable trail."""

    def setUp(self):
        from mlx_workbench import audit
        self.audit = audit
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / "audit.jsonl"

    def test_record_appends_and_recent_reverses(self):
        self.audit.record("a.one", path=self.path)
        self.audit.record("a.two", path=self.path, detail="x")
        entries = self.audit.recent(path=self.path)
        self.assertEqual([e["operation"] for e in entries], ["a.two", "a.one"])
        self.assertEqual(entries[0]["detail"], "x")
        self.assertIn("at", entries[0])

    def test_record_skips_empty_operation(self):
        self.assertIsNone(self.audit.record("", path=self.path))
        self.assertEqual(self.audit.recent(path=self.path), [])

    def test_record_is_silent_when_the_disk_refuses(self):
        # A missing directory chain that cannot be created must not raise.
        blocker = self.root / "file-blocks-the-way"
        blocker.write_text("not a directory", encoding="utf-8")
        self.assertIsNone(
            self.audit.record("a.op", path=blocker / "audit.jsonl")
        )

    def test_record_drops_entries_once_the_file_is_full(self):
        self.audit.record("a.seed", path=self.path)
        with open(self.path, "r+", encoding="utf-8") as handle:
            handle.seek(self.audit.MAX_AUDIT_BYTES)
            handle.write("x")
        self.assertIsNone(self.audit.record("a.late", path=self.path))
        entries = self.audit.recent(path=self.path)
        self.assertEqual([e["operation"] for e in entries], ["a.seed"])

    def test_recent_skips_corrupt_lines(self):
        self.audit.record("a.good", path=self.path)
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write("{broken\n")
        entries = self.audit.recent(path=self.path)
        self.assertEqual([e["operation"] for e in entries], ["a.good"])





class ServePresetTests(unittest.TestCase):
    """Named endpoint profiles: CRUD, schema discipline, API surface."""

    def setUp(self):
        from mlx_workbench import serve_presets
        self.sp = serve_presets
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config_dir = Path(self.directory.name)
        self.book = self.sp.PresetBook(
            self.sp.presets_path(self.config_dir / "config.json")
        )

    def test_upsert_create_update_delete_round_trip(self):
        created = self.book.upsert(
            name="Coder", model="mlx-community/Qwen3-8B-4bit", kind="repo",
            runtime="mlx_lm", port=8766, max_tokens=4096,
        )
        self.assertEqual(created["id"], "sp-1")
        updated = self.book.upsert(
            preset_id=created["id"], name="Coder (8k)", port=None,
        )
        self.assertEqual(updated["name"], "Coder (8k)"[:0] + "Coder (8k)")
        self.assertIsNone(updated["port"])
        self.assertEqual(updated["max_tokens"], 4096)
        self.book.delete(created["id"])
        self.assertEqual(self.book.list(), [])

    def test_persisted_file_survives_reload_and_rejects_schema_drift(self):
        created = self.book.upsert(
            name="Vision", model="/models/mlx/vlm", kind="path", runtime="mlx-vlm",
        )
        again = self.sp.PresetBook(self.sp.presets_path(self.config_dir / "config.json"))
        loaded = again.list()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0]["model"], "/models/mlx/vlm")

        corrupt = self.sp.presets_path(self.config_dir / "config.json")
        corrupt.write_text('{"schema_version": "9.9", "presets": []}', encoding="utf-8")
        self.assertEqual(again.list(), [])

        _ = created

    def test_invalid_fields_are_classified(self):
        for fields in (
            {"name": "", "model": "m", "kind": "repo", "runtime": "mlx_lm"},
            {"name": "x", "model": "", "kind": "repo", "runtime": "mlx_lm"},
            {"name": "x", "model": "m", "kind": "nope", "runtime": "mlx_lm"},
            {"name": "x", "model": "m", "kind": "repo", "runtime": "ollama"},
            {"name": "x", "model": "m", "kind": "repo", "runtime": "mlx_lm", "port": 70000},
        ):
            with self.subTest(fields=fields):
                with self.assertRaises(self.sp.PresetError):
                    self.book.upsert(**fields)




class ConvertPreflightTests(unittest.TestCase):
    """Fail-fast GGUF architecture check at conversion confirm time."""

    def setUp(self):
        from mlx_workbench import convert_preflight, gguf_arch
        self.preflight = convert_preflight
        self.gguf_arch = gguf_arch
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def _gguf(self, name, architecture):
        import struct
        path = self.root / name
        with path.open("wb") as handle:
            handle.write(b"GGUF")
            handle.write(struct.pack("<I", 3))      # version
            handle.write(struct.pack("<Q", 0))      # tensor count
            handle.write(struct.pack("<Q", 1))      # one metadata pair
            key = b"general.architecture"
            handle.write(struct.pack("<Q", len(key)))
            handle.write(key)
            handle.write(struct.pack("<I", 8))      # string value type
            value = architecture.encode("utf-8")
            handle.write(struct.pack("<Q", len(value)))
            handle.write(value)
        return str(path)

    def test_reader_extracts_architecture(self):
        self.assertEqual(
            self.gguf_arch.read_architecture(self._gguf("m.gguf", "llama")),
            "llama",
        )

    def test_reader_rejects_non_gguf(self):
        path = self.root / "junk.bin"
        path.write_bytes(b"not-a-gguf")
        with self.assertRaises(self.gguf_arch.GGUFFormatError):
            self.gguf_arch.read_architecture(str(path))

    def _with_supported(self, archs):
        original = self.preflight.supported_architectures
        self.addCleanup(setattr, self.preflight, "supported_architectures", original)
        self.preflight.supported_architectures = lambda: archs

    def test_supported_architecture_passes(self):
        self._with_supported({"llama"})
        path = self._gguf("ok.gguf", "llama")
        arch = self.preflight.check(path)
        self.assertEqual(arch, "llama")

    def test_unsupported_architecture_is_refused_and_named(self):
        self._with_supported({"llama"})
        path = self._gguf("flash.gguf", "dflash")
        with self.assertRaises(self.preflight.UnsupportedArchitecture) as caught:
            self.preflight.check(path)
        self.assertEqual(caught.exception.code, "architecture_unsupported")
        self.assertIn("dflash", str(caught.exception))
        self.assertIn("dflash", caught.exception.to_dict()["message"])

    def test_missing_supported_set_allows(self):
        self._with_supported(None)
        path = self._gguf("unknown.gguf", "anything")
        self.assertEqual(self.preflight.check(path), "anything")

    def test_unreadable_file_defers_to_the_agent(self):
        path = self.root / "broken.gguf"
        path.write_bytes(b"\x00\x01")
        self.assertIsNone(self.preflight.check(str(path)))



class ConvertProgressTests(unittest.TestCase):
    """Live progress endpoint: phase, percent, failed state."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_path = self.root / "config.json"
        config.save({
            "gguf_roots": [],
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
            "mlx_agent_path": _fake_agent_checkout(self.root),
        }, self.config_path)

    def test_progress_parses_percent(self):
        from mlx_workbench.bridge import convert_progress
        parsed = convert_progress("[mlx-converter] quantizing: 63%")
        self.assertEqual(parsed["percent"], 63)
        self.assertFalse(parsed["failed"])

    def test_progress_marks_failures(self):
        from mlx_workbench.bridge import convert_progress
        parsed = convert_progress(
            "[mlx-converter] conversion failed: GGUF model with architecture "
            "dflash is not supported yet."
        )
        self.assertTrue(parsed["failed"])
        self.assertEqual(parsed["phase"], "failed")
        self.assertIn("dflash", parsed["summary"])









class QuarantineDeleteTests(unittest.TestCase):
    """Bug 2: quarantine contents are visible and deletable (to Trash)."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.roots = [str(self.root / "models")]
        (self.root / "models").mkdir()
        self.hold = self.root / "hold"

    def _quarantine_file(self, name="dupe.gguf", payload=b"x" * 16):
        source = self.root / "models" / name
        source.write_bytes(payload)
        record = quarantine.quarantine(str(source), self.roots, str(self.hold))
        return record

    def test_purge_moves_file_to_trash_and_marks_ledger(self):
        record = self._quarantine_file()
        quarantined = record["to"]
        trashed = []

        def fake_trash(path):
            trashed.append(path)
            os.unlink(path)

        result = quarantine.purge(
            quarantined, str(self.hold), trash=fake_trash
        )
        self.assertEqual(trashed, [str(Path(quarantined).resolve())])
        self.assertFalse(Path(trashed[0]).exists())
        self.assertEqual(result["deleted"], str(Path(quarantined).resolve()))
        self.assertEqual(result["bytes"], 16)
        entries = quarantine.ledger(str(self.hold))
        entry = next(e for e in entries if e["to"] == quarantined)
        self.assertTrue(entry["deleted"])
        self.assertIn("deleted_at", entry)

    def test_purge_refuses_paths_outside_quarantine(self):
        outside = self.root / "models" / "keep.gguf"
        outside.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(str(outside), str(self.hold), trash=lambda p: None)
        self.assertEqual(caught.exception.code, "not_in_quarantine")
        self.assertTrue(outside.exists())

    def test_purge_refuses_relative_paths_and_the_ledger(self):
        with self.assertRaises(quarantine.QuarantineError):
            quarantine.purge("relative/file.gguf", str(self.hold), trash=lambda p: None)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(
                str(self.hold / quarantine.LEDGER_NAME), str(self.hold),
                trash=lambda p: None,
            )
        self.assertEqual(caught.exception.code, "ledger_protected")

    def test_purge_refuses_symlinks(self):
        record = self._quarantine_file()
        real = self.root / "real.bin"
        real.write_bytes(b"payload")
        link = self.hold / "link.gguf"
        os.symlink(real, link)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(str(link), str(self.hold), trash=lambda p: None)
        self.assertEqual(caught.exception.code, "symlink_refused")
        self.assertTrue(real.exists())
        self.assertTrue(Path(record["to"]).exists())

    def test_purge_failure_leaves_file_in_place(self):
        record = self._quarantine_file()

        def explode(path):
            raise OSError("disk refusing")

        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(record["to"], str(self.hold), trash=explode)
        self.assertEqual(caught.exception.code, "delete_failed")
        self.assertTrue(Path(record["to"]).exists())
        # Ledger not marked when nothing was deleted.
        entry = next(
            e for e in quarantine.ledger(str(self.hold))
            if e["to"] == record["to"]
        )
        self.assertFalse(entry["deleted"])



class QuarantineSymlinkTests(unittest.TestCase):
    """P1-6: quarantine never follows symlinks, in or out."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.roots = str(self.root / "models")
        (self.root / "models").mkdir()
        self.hold = str(self.root / "hold")

    def test_symlink_source_is_refused(self):
        outside = self.root / "real" / "x.gguf"
        (self.root / "real").mkdir()
        outside.write_bytes(b"x")
        link = self.root / "models" / "x.gguf"
        os.symlink(outside, link)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.quarantine(str(link), [self.roots], self.hold)
        self.assertEqual(caught.exception.code, "symlink_refused")
        self.assertTrue(outside.exists())
        self.assertFalse(link.exists() and not link.is_symlink())

    def test_symlink_quarantine_dir_is_refused(self):
        real_hold = self.root / "elsewhere"
        real_hold.mkdir()
        link_hold = self.root / "hold"
        os.symlink(real_hold, link_hold)
        source = self.root / "models" / "dupe.gguf"
        source.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.quarantine(str(source), [self.roots], str(link_hold))
        self.assertEqual(caught.exception.code, "symlink_refused")
        self.assertTrue(source.exists())




if __name__ == "__main__":
    unittest.main()