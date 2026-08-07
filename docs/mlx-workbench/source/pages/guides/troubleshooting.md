# Troubleshooting

## The server does not start

Run `make status`, then inspect `.run/mlx-workbench.log`. A stale PID file is
reported by `make status`; `make stop` removes stale state without killing an
unowned listener. If the configured port is occupied, choose another loopback
port with `make start PORT=9876`.

## MLX Agent is missing

Run `git submodule update --init --recursive`, then `make check`. Confirm that
`vendor/mlx-agent/scripts/mlx-agent` exists, or set `MLX_AGENT_HOME` to a
compatible pinned checkout. Do not point the setting at an individual script;
it expects the checkout root.

## Conversion or serving dependencies are missing

Run `make install` and `make doctor`. Confirm that the project `.venv` uses
Python 3.12. The foreground command `make run` exposes startup diagnostics.

## A queue file is invalid

Invalid persisted queue state is preserved rather than overwritten. Open
**Jobs**, note the numbered `convert-queue.json.N.corrupt` recovery path,
inspect that file, and submit the affected conversions again. Launched work is
recovered from MLX Agent receipts, not guessed from queue state.

## A quarantined weight is needed again

Quarantine moves files; it never deletes them. Read
`quarantine-ledger.jsonl` in the configured quarantine directory, find the
recorded `from` and `to` paths, stop active jobs using the file, and move it
back deliberately. Rescan Models afterward.

## Hub-backed commands fail

Check network access and Hugging Face Hub credentials. Loopback UI operation
does not prevent child commands from accessing the Hub.
