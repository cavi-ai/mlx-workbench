# Security model

MLX Workbench is a local operator tool, not a multi-user service.

- The launcher refuses non-loopback addresses and binds to `127.0.0.1` by
  default.
- Requests must use an accepted loopback Host and same-origin Origin.
- The HTML receives a fresh per-process session token. Every API request must
  return that token in `X-MLX-Workbench-Token`; restarting invalidates it.
- MLX Agent commands are arrays of argv tokens, never shell strings. The
  bridge runs the pinned `scripts/mlx-agent` CLI and requests `--json` output.
- Quarantine accepts existing `.gguf` files only when they resolve beneath a
  configured scan root. It moves them and records a ledger entry; it does not
  delete them.
- Job logs are read only from paths advertised by MLX Agent status envelopes.

Loopback and same-origin controls reduce exposure to other sites and hosts;
they do not create an authentication boundary between local operating-system
users. Protect the Mac account, configuration, model directories, quarantine,
and MLX Agent receipts with normal filesystem permissions.

Hub-backed child commands such as Discover, Adopt, and Doctor may contact the
Hugging Face Hub. Review the selected command and credentials before running
it. Do not describe the workbench as network isolated.
