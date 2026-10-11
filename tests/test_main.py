from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from mlx_workbench.__main__ import main


class NativeLauncherTests(unittest.TestCase):
    def test_missing_application_does_not_launch(self):
        with patch("mlx_workbench.__main__.subprocess.run") as run:
            self.assertEqual(main(["--app", "/missing/workbench.app"]), 2)
            run.assert_not_called()

    def test_launcher_opens_selected_application(self):
        with TemporaryDirectory() as directory:
            app = Path(directory) / "mlx-workbench.app"
            app.mkdir()
            with patch("mlx_workbench.__main__.subprocess.run") as run:
                run.return_value.returncode = 0
                self.assertEqual(main(["--app", str(app)]), 0)
                run.assert_called_once_with(["/usr/bin/open", str(app)], check=False)
