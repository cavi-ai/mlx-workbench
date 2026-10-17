import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/runtime_bundle.py"


class RuntimeBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.output = Path(self.temp.name) / "bundles"
        self.files = ["Makefile", "requirements.txt", "LICENSE", "mlx_workbench/__init__.py",
                      "mlx_workbench/config.py", "mlx_workbench/deps.py", "vendor/mlx-agent/LICENSE",
                      "vendor/mlx-agent/scripts/mlx-agent", "vendor/mlx-agent/src/mlx_agent/__init__.py"]
        for name in self.files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('__version__ = "1.2.3"\n' if name == "mlx_workbench/__init__.py" else name + "\n")

    def module(self):
        self.assertTrue(SCRIPT.is_file(), "Distribution builds need a runtime bundle builder")
        spec = importlib.util.spec_from_file_location("runtime_bundle", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_deterministic_bundle_reuses_only_identical_verified_sources(self):
        module = self.module()
        first = module.create_bundle(self.root, self.output, self.files, "a" * 40)
        manifest = module.verify_bundle(first)
        self.assertEqual(manifest["engine_revision"], "a" * 40)
        self.assertEqual(manifest["workbench_version"], "1.2.3")
        self.assertEqual({f["path"] for f in manifest["files"]}, set(self.files))
        self.assertEqual(first, module.create_bundle(self.root, self.output, reversed(self.files), "a" * 40))
        self.assertEqual(first, module.resolve_bundle(self.output))
        (first / "requirements.txt").write_text("changed\n")
        with self.assertRaises(ValueError):
            module.create_bundle(self.root, self.output, self.files, "a" * 40)
        self.assertEqual((first / "requirements.txt").read_text(), "changed\n")

    def test_new_sources_get_a_new_directory_without_replacing_the_previous_bundle(self):
        module = self.module()
        first = module.create_bundle(self.root, self.output, self.files, "a" * 40)
        (self.root / "requirements.txt").write_text("new pins\n")
        second = module.create_bundle(self.root, self.output, self.files, "a" * 40)
        self.assertNotEqual(first, second)
        self.assertTrue(first.is_dir())
        self.assertEqual(module.resolve_bundle(self.output), second)

    def test_links_traversal_missing_sources_and_forged_metadata_are_refused(self):
        module = self.module()
        with self.assertRaises(ValueError):
            module.create_bundle(self.root, self.output, [*self.files, "../outside"], "a" * 40)
        with self.assertRaises(ValueError):
            module.create_bundle(self.root, self.output, self.files[1:], "a" * 40)
        target = self.root / "requirements.txt"
        target.unlink()
        target.symlink_to(self.root / "LICENSE")
        with self.assertRaises(ValueError):
            module.create_bundle(self.root, self.output, self.files, "a" * 40)
        target.unlink()
        target.write_text("pins\n")
        bundle = module.create_bundle(self.root, self.output, self.files, "a" * 40)
        metadata = json.loads((bundle / "manifest.json").read_text())
        metadata["files"][0]["path"] = "../outside"
        (bundle / "manifest.json").write_text(json.dumps(metadata))
        with self.assertRaises(ValueError):
            module.verify_bundle(bundle)
