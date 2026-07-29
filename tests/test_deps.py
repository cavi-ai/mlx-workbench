import unittest
from unittest.mock import patch

from mlx_workbench import deps


class DepsTests(unittest.TestCase):
    def test_convert_ready_when_everything_present(self):
        with patch.object(deps, "_module_present", return_value=True), \
                patch.object(deps, "_executable_present", return_value=True):
            report = deps.convert_ready()
        self.assertTrue(report["ok"])
        self.assertEqual(report["missing_modules"], [])
        self.assertIn("ready", report["message"].lower())

    def test_convert_ready_lists_missing_pieces(self):
        def modules(name):
            return name != "torch"

        def executables(name):
            return False

        with patch.object(deps, "_module_present", side_effect=modules), \
                patch.object(deps, "_executable_present", side_effect=executables):
            report = deps.convert_ready()
        self.assertFalse(report["ok"])
        self.assertEqual(report["missing_modules"], ["torch"])
        self.assertEqual(report["missing_executables"], ["mlx_lm.convert"])
        self.assertIn("make install", report["message"])

    def test_runtime_report_includes_install_hint(self):
        with patch.object(deps, "_module_present", return_value=True), \
                patch.object(deps, "_executable_present", return_value=True):
            report = deps.runtime_report()
        self.assertEqual(report["install"], "make install")
        self.assertTrue(report["ok"])


if __name__ == "__main__":
    unittest.main()
