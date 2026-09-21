# Security model

MLX Workbench is a local operator tool, not a multi-user service.

## Boundary

- The launcher refuses non-loopback addresses and binds to `127.0.0.1` by
  default; the configured `host` is validated against a loopback allowlist on
  every load and save.
- Requests must use an accepted loopback Host and same-origin Origin.
  Spoofed Host values (for example `127.0.0.1.evil.com`) and Origin hosts
  that merely embed a loopback name are refused.
- The HTML receives a fresh per-process session token. Every API request must
  return that token in `X-MLX-Workbench-Token`; restarting invalidates it.
- Concurrent requests are capped by a bounded semaphore; excess requests get
  a structured `server_busy` 503 instead of unbounded thread growth.
- Responses carry a strict CSP (`default-src 'none'`, `frame-ancestors
  'none'`, `form-action 'self'`, `base-uri 'none'`), `X-Frame-Options: DENY`,
  `nosniff`, and a `Server:` header without the Python version.

## Subprocesses

- MLX Agent commands are arrays of argv tokens, never shell strings. The
  bridge runs the pinned `scripts/mlx-agent` CLI and requests `--json` output.
- The agent subprocess environment is an explicit allowlist — PATH (with the
  project interpreter's bin directory first), HOME, XDG variables, Hugging
  Face variables, and TLS/proxy basics. The web server's full environment is
  never passed through.
- Timed-out agent commands are killed as a whole process group (SIGTERM, then
  SIGKILL), so a stalled conversion cannot leave orphaned grandchildren.
- Job logs are read only from paths advertised by MLX Agent status envelopes.
- Path fields submitted to the API must not contain control characters;
  embedded NUL bytes are refused before any process spawn.

## Durable state

- `config.json` and `convert-queue.json` are written atomically with the
  file contents fsynced before the rename and the containing directory
  fsynced afterwards, so a power loss cannot leave truncated state.
- The config key universe is closed: known web fields plus the native app's
  premium keys. Unknown keys are rejected on load and refused on save, so a
  hostile or corrupted file cannot smuggle arbitrary fields into either
  frontend.
- Symbolic links are refused before every durable write — config saves,
  queue saves, quarantine operations, and the native app's client-config
  wiring, backups, restore targets, and JSON stores. Links are never
  followed.
- Quarantine accepts existing `.gguf` files only when they resolve beneath a
  configured scan root. It moves them and records a ledger entry; it does not
  delete them.
- Every state-changing web operation (config save, convert submit, queue
  operations, serve start/stop, quarantine moves) appends a line to a local
  audit trail at `$XDG_STATE_HOME/mlx-workbench/audit.jsonl`. The trail is
  bounded and best-effort; durable stores stay authoritative.
- Convert and serve dependencies are pinned in `requirements.txt`, installed
  by `make install`, and audited against the OSV database by `make pip-audit`
  as a PR gate. Known advisories without a fix on the pinned line are
  recorded explicitly in the Makefile rather than silently ignored.

## Limits

Loopback and same-origin controls reduce exposure to other sites and hosts;
they do not create an authentication boundary between local operating-system
users. Protect the Mac account, configuration, model directories, quarantine,
and MLX Agent receipts with normal filesystem permissions.

Hub-backed child commands such as Discover, Adopt, and Doctor may contact the
Hugging Face Hub. Review the selected command and credentials before running
it. Do not describe the workbench as network isolation — the loopback bind is
not a promise of network isolation.