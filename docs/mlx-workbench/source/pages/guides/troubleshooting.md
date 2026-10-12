# Troubleshooting

## The native app does not open

Source builds require Xcode: run `make build-swift` and inspect its error.
The release DMG supplies the app without a source build. Copy the app to
Applications before opening it. Browser UI and UI-server controls have been
removed.

## MLX Agent or its runtime is missing

Settings expects a checkout containing `scripts/mlx-agent`. In the matching
Workbench checkout, run:

```bash
git submodule update --init --recursive
make install
make check
make doctor
```

Distribution apps use that checkout's `.venv` when the engine is its
`vendor/mlx-agent`. A different engine needs its corresponding runtime.
Python 3.12 is supported.

## Training or controlled studies cannot load

Re-run `make install` for the engine's `requirements-lab.txt`.
Optional inference dependencies install separately through
**Controlled studies → Install runtime…**. Inspect errors and receipts
before retrying.

## Conversion fails

Inspect Activity's error and log. `make install` restores the pinned
`requirements.txt`, including `accelerate` and `transformers<5`.
Unsupported architectures, missing backends, and non-servable tasks have
different remedies; follow the plan's reason instead of forcing execution.

## An earlier queue cannot be imported

Stop the former Workbench server first. Choose the exact earlier
`convert-queue.json`; import preserves the source and an exact backup.
Invalid state is refused. Resolve the error without deleting the only copy
of queued work. Launched work is reconciled from engine receipts.

## A reclaimed model is needed again

Use the guarded recovery action in Reclaim or source-cleanup history.
Preview the original destination; changed items or occupied destinations
can refuse restore. Files moved to Trash retain disk space until Trash is
emptied. Rescan Library after recovery.

## An update is unavailable or refused

v0.4.0 DMG installations need a manual upgrade: quit the old app and install
the new DMG. They do not contain the release installer.

In this release, **Settings → Updates** requires a published DMG with a
GitHub sha256 digest and a notarized Developer ID signature for MLX Workbench.
Mounted, translocated, or unwritable installations cannot replace themselves;
copy the app to Applications first. Replaced apps go to Trash. Keep the
previous copy until the new app has been checked.

## Hub-backed operations fail

Check network access and Hugging Face Hub credentials. Local serving does not
prevent discovery and downloads from contacting the Hub.

## Reported model size is incorrect

The opt-in read-only inventory checks compare reported bytes with the
configured filesystem paths:

```bash
make test-live-scan
make test-swift-live-scan
```

Resolve a reported mismatch before converting that model. These checks do
not certify conversion quality or inference.
