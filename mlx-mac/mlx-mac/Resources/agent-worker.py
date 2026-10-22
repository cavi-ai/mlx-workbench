import io
import json
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]).resolve() / "src"))

from mlx_agent.cli import main

OUTPUT_LIMIT = 8 * 1024 * 1024
channel = sys.stdout


def reply(payload):
    channel.write(json.dumps(payload, separators=(",", ":")) + "\n")
    channel.flush()


def run(argv):
    stdout, stderr = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(stdout), redirect_stderr(stderr):
            returned = main(argv)
        code = 0 if returned is None else int(returned)
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else (0 if error.code is None else 1)
    except Exception:
        code = 1
    return {"exit": code, "stdout": stdout.getvalue()[:OUTPUT_LIMIT], "stderr": stderr.getvalue()[:OUTPUT_LIMIT]}


reply({"ready": True})
for line in sys.stdin:
    try:
        request = json.loads(line)
        argv = request["argv"]
        if not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
            raise ValueError("argv must be a list of strings")
    except (ValueError, KeyError, TypeError):
        reply({"exit": 2, "stdout": "", "stderr": "invalid worker request"})
        continue
    reply(run(argv))
