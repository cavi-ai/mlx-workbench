import unittest
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import quarantine


def _clock():
    return datetime(2026, 7, 28, 12, 0, 0, tzinfo=timezone.utc)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.models = self.root / "models"
        self.models.mkdir()

    def _gguf(self, name="model-Q4_K_M.gguf", size=16):
        path = self.models / name
        path.write_bytes(b"x" * size)
        return path

    def test_accepts_a_gguf_under_a_root(self):
        path = self._gguf()
        self.assertEqual(quarantine.guard(path, [self.models]), path.resolve())

    def test_rejects_other_suffixes(self):
        other = self.models / "weights.safetensors"
        other.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.guard(other, [self.models])
        self.assertEqual(caught.exception.code, "not_a_gguf")

    def test_rejects_missing_file(self):
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.guard(self.models / "absent.gguf", [self.models])
        self.assertEqual(caught.exception.code, "not_found")

    def test_rejects_paths_outside_every_root(self):
        outside = self.root / "elsewhere"
        outside.mkdir()
        path = outside / "model-Q4_K_M.gguf"
        path.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.guard(path, [self.models])
        self.assertEqual(caught.exception.code, "outside_roots")

    def test_rejects_traversal_out_of_a_root(self):
        outside = self.root / "secret.gguf"
        outside.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.guard(self.models / ".." / "secret.gguf", [self.models])
        self.assertEqual(caught.exception.code, "outside_roots")


class MoveTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.models = self.root / "models"
        self.models.mkdir()
        self.hold = self.root / "quarantine"

    def _gguf(self, name="model-Q4_K_M.gguf"):
        path = self.models / name
        path.write_bytes(b"x" * 32)
        return path

    def test_move_records_and_preserves_the_file(self):
        path = self._gguf()
        record = quarantine.quarantine(path, [self.models], self.hold, clock=_clock)
        self.assertFalse(path.exists())
        moved = Path(record["to"])
        self.assertTrue(moved.is_file())
        self.assertEqual(moved.read_bytes(), b"x" * 32)
        self.assertEqual(record["bytes"], 32)
        self.assertEqual(record["from"], str(path.resolve()))

    def test_repeated_names_do_not_collide(self):
        first = quarantine.quarantine(self._gguf(), [self.models], self.hold, clock=_clock)
        second = quarantine.quarantine(self._gguf(), [self.models], self.hold, clock=_clock)
        self.assertNotEqual(first["to"], second["to"])
        self.assertTrue(Path(first["to"]).is_file())
        self.assertTrue(Path(second["to"]).is_file())

    def test_ledger_lists_newest_first(self):
        quarantine.quarantine(self._gguf("a-Q4_K_M.gguf"), [self.models], self.hold, clock=_clock)
        quarantine.quarantine(self._gguf("b-Q4_K_M.gguf"), [self.models], self.hold, clock=_clock)
        records = quarantine.ledger(self.hold)
        self.assertEqual(len(records), 2)
        self.assertTrue(records[0]["from"].endswith("b-Q4_K_M.gguf"))
        self.assertTrue(records[0]["exists"])

    def test_refuses_to_requarantine(self):
        path = self._gguf()
        record = quarantine.quarantine(path, [self.models], self.hold, clock=_clock)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.quarantine(record["to"], [self.root], self.hold, clock=_clock)
        self.assertEqual(caught.exception.code, "already_quarantined")

    def test_failed_move_is_classified(self):
        def _explode(source, destination):
            raise OSError("disk full")

        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.quarantine(
                self._gguf(), [self.models], self.hold, clock=_clock, move=_explode
            )
        self.assertEqual(caught.exception.code, "move_failed")

    def test_empty_ledger_for_a_missing_directory(self):
        self.assertEqual(quarantine.ledger(self.root / "nothing"), [])


if __name__ == "__main__":
    unittest.main()
