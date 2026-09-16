"""Shared-fixture contract tests.

These consume the same JSON files as the native app's XCTest suite
(mlx-mac/mlx-macTests). Assertions about fixture content must match the
Swift side; see tests/fixtures/README.md.
"""

import json
import shutil
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import bridge, config, convert_queue, quarantine

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class ScanContractFixtureTests(unittest.TestCase):
    def test_valid_scan_payload_is_accepted_with_expected_bytes(self):
        payload = bridge.validate_scan(_fixture("convert-scan-valid.json"))
        self.assertEqual(
            [model["bytes"] for model in payload["models"]],
            [903453952, 29047084448],
        )
        self.assertEqual(payload["totals"]["bytes"], 29950538400)
        self.assertEqual(len(payload["outputs"]), 1)

    def test_missing_model_bytes_is_rejected(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.validate_scan(_fixture("convert-scan-missing-bytes.json"))
        self.assertEqual(caught.exception.code, "scan_contract_invalid")


class ConfigContractFixtureTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "config.json"
        shutil.copy(FIXTURES / "config-premium-keys.json", self.path)

    def test_premium_keys_survive_load_and_save(self):
        loaded = config.load(self.path)
        self.assertEqual(loaded["verification_enabled"], False)
        self.assertEqual(loaded["watch_enabled"], False)
        self.assertEqual(loaded["fit_reserve_gb"], 8)
        self.assertEqual(loaded["reclaim_stale_days"], 30)
        self.assertEqual(loaded["comparison_max_tokens"], 256)
        self.assertEqual(loaded["q_bits"], 8)

        saved = config.save(loaded, self.path)
        for key in (
            "verification_enabled",
            "watch_enabled",
            "fit_reserve_gb",
            "reclaim_stale_days",
            "comparison_max_tokens",
        ):
            self.assertEqual(saved[key], loaded[key])


class QuarantineLedgerFixtureTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        shutil.copy(
            FIXTURES / "quarantine-ledger.jsonl",
            Path(self.directory.name) / quarantine.LEDGER_NAME,
        )

    def test_ledger_reads_newest_first_with_expected_fields(self):
        records = quarantine.ledger(self.directory.name)
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["from"], "/fixtures/gguf/newer.gguf")
        self.assertEqual(records[0]["bytes"], 2048)
        self.assertEqual(records[0]["moved_at"], "2026-08-02T11:00:00+00:00")
        self.assertEqual(records[1]["from"], "/fixtures/gguf/older.gguf")
        self.assertEqual(records[1]["bytes"], 1024)
        # The quarantined files do not exist on disk in the fixture.
        self.assertFalse(any(record["exists"] for record in records))


class ConvertQueueFixtureTests(unittest.TestCase):
    def test_current_queue_loads_three_items_in_order(self):
        queue = convert_queue.ConvertQueue(path=FIXTURES / "convert-queue.json")
        self.assertIsNone(queue.load_error)
        items = queue.snapshot()
        self.assertEqual([item["id"] for item in items], ["cq-1", "cq-2", "cq-3"])
        self.assertEqual(
            [item["state"] for item in items],
            ["queued", "starting", "failed"],
        )
        self.assertEqual(items[0]["kind"], "gguf")
        self.assertEqual(items[1]["kind"], "repo")
        self.assertEqual(items[1]["repo"], "mlx-community/Qwen3-8B-8bit")
        self.assertEqual(items[2]["failure"]["code"], "convert_failed")

    def test_legacy_queue_migrates_items_with_null_failure(self):
        queue = convert_queue.ConvertQueue(
            path=FIXTURES / "convert-queue-legacy.json"
        )
        self.assertIsNone(queue.load_error)
        items = queue.snapshot()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["id"], "cq-7")
        self.assertEqual(items[0]["state"], "queued")
        self.assertIsNone(items[0]["failure"])


if __name__ == "__main__":
    unittest.main()
