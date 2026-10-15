# Security model

MLX Workbench is a single-user local app, not a service. Protect the Mac account, the configuration, model files and engine receipts with filesystem permissions.

## Execution

- Engine commands run through `scripts/mlx-agent` with argv tokens and `--json`, never shell strings.
- Preview hashes bind reviewed inputs. Conversion, training, serving, wiring, cleanup and prune confirmations run only the plan that was previewed; a changed input requires a new preview.
- A timed-out engine call terminates its whole process group, including backend children: SIGTERM, then SIGKILL after two seconds. The app does the same for live children when it quits.
- Model repository runtime code is never executed, and intake never passes `--trust-remote-code`. Unsupported loaders are refused.

## Network

Serving endpoints bind to loopback, such as `127.0.0.1`. Load-on-request gateways use an authenticated control channel to their worker. Hugging Face Hub discovery, intake and downloads contact the network, and update checks contact GitHub. Loopback binding is not a promise of network isolation.

## Files

- State stores, client config writes and the config file are replaced atomically. Stores refuse a symbolic link in place of their file.
- Client wiring writes only to a fixed allowlist of config paths, backs each file up, rechecks it for changes before writing, and refuses symbolic links at the config, backup and restore paths.
- Reclaim previews recheck paths, contents, file identity and protection rules before every move. Protected models, shared cache references, changed items and symbolic links refuse destructive actions. Moves go to quarantine or the macOS Trash, never to permanent deletion.
- Comparison outputs are stored under fenced folders named by run; artifact names containing `/`, `..` or a leading dot are refused, and links are never followed. Your original input files are never changed or removed.

## Experiments

The engine owns the experiment database and conversion queue. Experiment artifacts are integrity-checked and reviewer-scoped. Blind-review scores become immutable receipts before sealed assignments are revealed. Legacy queue import preserves its source and an exact backup.

## Dependencies

`make install` installs exact pins from `requirements.txt` and the engine's lab requirements. Optional backends install into isolated environments from hash-locked requirement files. `make pip-audit` checks all of them against the OSV database. The transformers 4.x pin is required by mlx-lm's GGUF conversion path; its accepted advisories are listed explicitly in the `Makefile`.

## App updates

An installed app replaces itself only with a published DMG whose sha256 matches GitHub's digest, mounted read-only, that satisfies the code requirement for `com.cavi.mlxworkbench`, team `Y76GMV87GM`, notarized. Validation precedes replacement; the previous app goes to the Trash. Translocated, disk-image and unwritable locations are refused. Distribution builds record their commit and channel and contain no build-machine source path.
