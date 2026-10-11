"""Compatibility import for the conversion queue owned by mlx-agent."""
import importlib
from pathlib import Path
import sys
from . import config, bridge as _workbench_bridge

root = Path(config.load()["mlx_agent_path"]).expanduser()
if not (root / "src/mlx_agent/convert_queue.py").is_file():
    raise ImportError("The selected mlx-agent does not include the shared conversion queue.")
sys.path.insert(0, str(root / "src"))
_engine = importlib.import_module("mlx_agent.convert_queue")
for _name in dir(_engine):
    if not _name.startswith("__"):
        globals()[_name] = getattr(_engine, _name)


class ConvertQueue(_engine.ConvertQueue):
    """Preserve the legacy bridge error type without duplicating queue behavior."""
    def _try_start_next(self, agent_path, runner=None):
        try:
            return super()._try_start_next(agent_path, runner=runner)
        except _engine.bridge.BridgeError as error:
            raise _workbench_bridge.BridgeError(error.code, str(error), error.remediation) from error
