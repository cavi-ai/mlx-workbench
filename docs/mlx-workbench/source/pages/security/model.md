# Security model

MLX Workbench is a native local operator app, not a multi-user service.
Protect the Mac account, configuration, model files, and engine receipts with
filesystem permissions.

## Execution

Native agent commands use argv tokens and `--json` through
`scripts/mlx-agent`, rather than shell strings. Conversion and training
preview hashes bind reviewed inputs before launch. Timed-out native calls
terminate their owned process group, including backend children.

Serving endpoints bind to loopback, such as `127.0.0.1`. Hugging Face Hub
discovery and downloads may contact the network. Loopback is
not a promise of network isolation.

## Data and recovery

Stores and client configuration writes retain atomic-write and confirmation
boundaries. Cleanup and reclaim previews recheck paths, contents, and
protection rules before a move. Protected models, shared cache references,
changed items, and symbolic links can refuse destructive actions.

The engine owns the conversion queue and experiment database. Legacy queue
import preserves its source and an exact backup. Experiment artifacts are
integrity-checked and reviewer-scoped; accepted review receipts precede
authorized reveal of sealed assignments.

Quarantine and Trash provide distinct recovery locations. Trash does not free
space until it is emptied. Preview restore destinations and back up valuable
configuration and evidence.

## Runtime and app updates

`make install` installs pinned `requirements.txt` and engine lab packages.
`make pip-audit` checks pinned runtime dependencies against OSV. Accepted
advisories on the required transformers 4.x line are explicit in the Makefile.

Installed-app updates require a download matching its published GitHub
sha256 digest and a notarized Developer ID signature for the expected bundle
and team. Validation precedes replacement; the previous app goes to Trash.
Distribution builds carry their commit and channel without an embedded
build-machine source path.
