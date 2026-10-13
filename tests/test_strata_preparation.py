import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("strata_preparation", ROOT / "scripts/prepare-strata-model.py")
preparation = importlib.util.module_from_spec(spec)
runtime_spec = importlib.util.spec_from_file_location("strata_test_runtime", ROOT / "vendor/mlx-agent/src/mlx_agent/strata_runtime.py")
runtime = importlib.util.module_from_spec(runtime_spec)
runtime_spec.loader.exec_module(runtime)
with patch.dict(sys.modules, {"mlx_agent.strata_runtime": runtime}):
    spec.loader.exec_module(preparation)


class StrataPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.first = self.root / "weights.gguf"
        self.first.write_bytes(b"unchanged local weights")
        metadata = {"general.architecture": "qwen4exp", "tokenizer.ggml.tokens": [str(i) for i in range(248320)],
                    "tokenizer.ggml.merges": ["1 2", "3 4"], "tokenizer.ggml.token_type": [1] * 248320,
                    "tokenizer.chat_template": "{{ messages }}"}
        fake = types.ModuleType("strata_mlx.gguf")
        fake.GGUF = lambda _: types.SimpleNamespace(meta=metadata)
        self.patches = [patch.dict(sys.modules, {"strata_mlx.gguf": fake}),
                        patch.object(preparation, "installed_runtime", return_value={"root": str(self.root)}),
                        patch.object(sys, "argv", ["prepare", "--gguf", str(self.first), "--out", str(self.root)])]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def test_exports_frontend_merge_contract_without_a_blank_last_rule(self):
        with patch.object(preparation, "read_model", return_value={"root": str(self.root)}), contextlib.redirect_stdout(io.StringIO()):
            preparation.main()
        self.assertEqual((self.root / "tokenizer/merges.txt").read_text().split("\n"), ["1 2", "3 4"])
        self.assertEqual(json.loads((self.root / "config.json").read_text())["serving_runtime"], "strata")
        self.assertEqual(self.first.read_bytes(), b"unchanged local weights")

    def test_failed_profile_validation_removes_only_new_metadata_and_retains_weights(self):
        with patch.object(preparation, "read_model", side_effect=ValueError("incomplete pair")):
            with self.assertRaisesRegex(ValueError, "incomplete pair"):
                preparation.main()
        self.assertFalse((self.root / "config.json").exists())
        self.assertFalse((self.root / "strata-model.json").exists())
        self.assertFalse((self.root / "tokenizer").exists())
        self.assertEqual(self.first.read_bytes(), b"unchanged local weights")

    def test_existing_model_config_is_never_overwritten(self):
        original = '{"model_type":"qwen4_exp","quantization":{"bits":8}}'
        (self.root / "config.json").write_text(original)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            preparation.main()
        self.assertEqual((self.root / "config.json").read_text(), original)
        self.assertFalse((self.root / "tokenizer").exists())
