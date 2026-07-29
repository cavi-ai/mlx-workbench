import json
import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from mlx_workbench import config


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "config.json"

    def test_missing_file_yields_defaults(self):
        value = config.load(self.path)
        self.assertEqual(value["schema_version"], config.SCHEMA_VERSION)
        self.assertEqual(value["q_bits"], 4)
        self.assertEqual(value["host"], "127.0.0.1")

    def test_save_round_trip(self):
        saved = config.save({"gguf_roots": ["~/models"], "q_bits": 8}, self.path)
        self.assertEqual(saved["q_bits"], 8)
        self.assertTrue(saved["gguf_roots"][0].endswith("/models"))
        self.assertNotIn("~", saved["gguf_roots"][0])
        self.assertEqual(config.load(self.path)["q_bits"], 8)

    def test_partial_update_keeps_defaults(self):
        saved = config.save({"port": 9100}, self.path)
        self.assertEqual(saved["port"], 9100)
        self.assertEqual(saved["q_bits"], 4)

    def test_rejects_bad_q_bits(self):
        with self.assertRaises(config.ConfigError):
            config.save({"q_bits": 5}, self.path)

    def test_rejects_bad_port(self):
        with self.assertRaises(config.ConfigError):
            config.save({"port": 0}, self.path)

    def test_rejects_non_string_roots(self):
        with self.assertRaises(config.ConfigError):
            config.save({"gguf_roots": [1]}, self.path)

    def test_rejects_too_many_roots(self):
        with self.assertRaises(config.ConfigError):
            config.save({"gguf_roots": ["/x"] * (config.MAX_ROOTS + 1)}, self.path)

    def test_rejects_unreadable_file(self):
        self.path.write_text("{not json", encoding="utf-8")
        with self.assertRaises(config.ConfigError):
            config.load(self.path)

    def test_unknown_keys_are_dropped(self):
        saved = config.save({"surprise": True}, self.path)
        self.assertNotIn("surprise", saved)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8")), saved)

    def test_scan_roots_falls_back_to_discovery(self):
        self.assertEqual(
            config.scan_roots({"gguf_roots": ["/a"]}), ["/a"]
        )
        self.assertEqual(
            config.scan_roots({"gguf_roots": []}), config.discover_gguf_roots()
        )

    def test_discover_agent_path_finds_a_sibling_checkout(self):
        root = Path(self.directory.name)
        (root / "mlx-agent" / "skills" / "mlx-converter").mkdir(parents=True)
        with patch.dict(os.environ, {}, clear=True):
            found = config.discover_agent_path(root / "mlx-converter")
        self.assertEqual(found, str(root / "mlx-agent"))

    def test_discover_agent_path_prefers_the_environment(self):
        root = Path(self.directory.name)
        (root / "elsewhere" / "skills").mkdir(parents=True)
        with patch.dict(os.environ, {config.AGENT_ENV: str(root / "elsewhere")}, clear=True):
            self.assertEqual(config.discover_agent_path(root), str(root / "elsewhere"))

    def test_discover_agent_path_is_empty_without_a_checkout(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(config.discover_agent_path(Path(self.directory.name) / "nope"), "")


if __name__ == "__main__":
    unittest.main()
