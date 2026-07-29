"""Start the local mlx-workbench UI."""

from __future__ import annotations

import argparse
import atexit
import os
import sys
import webbrowser
from pathlib import Path

from . import bridge, config as config_module, deps as deps_module, server as server_module


def _write_pid_file(path):
    """Record this process id so `make stop` can find it."""
    location = Path(path).expanduser()
    location.parent.mkdir(parents=True, exist_ok=True)
    location.write_text("{0}\n".format(os.getpid()), encoding="utf-8")

    def _cleanup():
        try:
            if location.is_file() and location.read_text(encoding="utf-8").strip() == str(os.getpid()):
                location.unlink()
        except OSError:
            pass

    atexit.register(_cleanup)
    return location


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=None, help="bind address (loopback only)")
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--config", default=None, help="path to the configuration file")
    parser.add_argument("--no-open", action="store_true", help="do not open a browser")
    parser.add_argument(
        "--pid-file",
        default=None,
        help="write this process id to a file (removed on exit)",
    )
    arguments = parser.parse_args(argv)

    try:
        settings = config_module.load(arguments.config)
    except config_module.ConfigError as error:
        print("configuration error: {0}".format(error), file=sys.stderr)
        return 2

    host = arguments.host or settings["host"]
    if host not in ("127.0.0.1", "localhost", "::1"):
        print("refusing to bind {0}: this UI is loopback only.".format(host), file=sys.stderr)
        return 2
    port = arguments.port or settings["port"]

    try:
        httpd = server_module.build(host, port, config_path=arguments.config)
    except OSError as error:
        print("could not bind {0}:{1}: {2}".format(host, port, error), file=sys.stderr)
        return 2

    if arguments.pid_file:
        _write_pid_file(arguments.pid_file)

    bound_port = httpd.server_address[1]
    url = "http://{0}:{1}/".format(host, bound_port)
    print("mlx-workbench on {0}".format(url))
    health = bridge.agent_health(settings["mlx_agent_path"])
    if health["ok"]:
        print("mlx-agent: {0}".format(health["path"]))
    else:
        print("mlx-agent: {0}".format(health["message"]), file=sys.stderr)
        if not settings["mlx_agent_path"]:
            print(
                "hint: run `make install`, or "
                "`git submodule update --init --recursive`.",
                file=sys.stderr,
            )
    runtime = deps_module.runtime_report()
    if runtime["convert"]["ok"]:
        print("convert: ready")
    else:
        print("convert: {0}".format(runtime["convert"]["message"]), file=sys.stderr)
    if not runtime["serve"]["ok"]:
        print("serve: {0}".format(runtime["serve"]["message"]), file=sys.stderr)
    if not arguments.no_open:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
