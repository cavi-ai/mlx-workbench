"""Opt-in regression against the configured local model inventory.

This test is intentionally disabled for ordinary unit-test runs: it shells out
to the locally configured mlx-agent checkout and reads user-owned model files.
It never writes to model roots or starts conversion work.
"""

from __future__ import annotations

import os
import unittest
from pathlib import Path

from mlx_workbench import bridge, config


@unittest.skipUnless(
    os.environ.get("MLX_WORKBENCH_LIVE_SCAN") == "1",
    "set MLX_WORKBENCH_LIVE_SCAN=1 to validate the configured local inventory",
)
class LiveScanE2ETests(unittest.TestCase):
    def test_configured_scan_matches_model_filesystem_bytes(self):
        settings = config.load()
        result = bridge.scan(
            settings["mlx_agent_path"],
            gguf_roots=config.scan_roots(settings),
            mlx_roots=settings["mlx_roots"],
            signatures=settings["signatures"],
        )
        models = result.get("models") or []
        if not models:
            self.skipTest("no GGUF models exist in the configured scan roots")

        model_bytes = 0
        for model in models:
            path = Path(model["path"])
            self.assertTrue(path.is_file(), path)
            self.assertGreater(model["bytes"], 0, path)
            self.assertEqual(model["bytes"], path.stat().st_size, path)
            model_bytes += model["bytes"]

        self.assertEqual(result["totals"]["bytes"], model_bytes)
