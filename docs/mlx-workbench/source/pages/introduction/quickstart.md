# Quickstart

Start the background server and open its loopback URL:

```bash
make start
make status
make open
```

The default URL is `http://127.0.0.1:8765/`. The process ID and log are stored
under `.run/`. To use another loopback port, run `make start PORT=9876`.

Open **Settings** first. Confirm the model scan roots, output directory,
quarantine directory, and MLX Agent checkout. Leave the agent path empty to
use the pinned `vendor/mlx-agent` submodule. Then use **Models** for local GGUF
inventory or **Scout** for Hub-backed discovery.

Check and stop the background service with:

```bash
make status
make stop
```

For foreground diagnostics, use `make run`. Never expose the process through
a non-loopback bind or a reverse proxy.
