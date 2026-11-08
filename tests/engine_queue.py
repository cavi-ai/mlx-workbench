"""Load the queue contract from this checkout's vendored engine."""

from pathlib import Path
from unittest.mock import patch

from mlx_workbench import config


with patch.object(config, "load", return_value={
    "mlx_agent_path": str(Path(__file__).resolve().parents[1] / "vendor" / "mlx-agent"),
}):
    from mlx_workbench import convert_queue
