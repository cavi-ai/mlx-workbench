"""Start the local mlx-workbench UI."""

from __future__ import annotations

import argparse
import sys
import webbrowser

from . import config as config_module, server as server_module


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=None, help="bind address (loopback only)")
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--config", default=None, help="path to the configuration file")
    parser.add_argument("--no-open", action="store_true", help="do not open a browser")
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

    url = "http://{0}:{1}/".format(host, httpd.server_address[1])
    print("mlx-workbench on {0}".format(url))
    if not settings["mlx_agent_path"]:
        print("no mlx-agent checkout configured; set it under Settings.")
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
