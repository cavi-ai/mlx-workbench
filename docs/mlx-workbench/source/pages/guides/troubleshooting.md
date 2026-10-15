# Troubleshooting

## The app does not open

Copy the app from the disk image to **Applications** before opening it. Source builds need Xcode: run `make build-swift` and read its error.

## The engine or its runtime is missing

**Settings → Engine → mlx-agent checkout** must point at a checkout containing `scripts/mlx-agent`. Health shows what is missing and offers **Install Runtime…**. From the Workbench checkout:

```bash
git submodule update --init --recursive
make install
make doctor
```

An installed app uses the `.venv` of the checkout whose `vendor/mlx-agent` is the configured engine. A different engine checkout needs its own runtime. Python 3.12 is supported.

## Hugging Face Hub operations fail

Discovery, intake and downloads need network access and, for gated repositories, Hub credentials. Local serving does not prevent the Hub from being contacted. A **Blocked** or **Hub unreachable** verdict downloads nothing.

## A conversion fails

Read the error and log in Activity. `make install` restores the pinned `requirements.txt`, including `accelerate` and `transformers<5`. Unsupported architectures, missing backends and non-servable task types each have a different remedy; follow the reason in the plan instead of forcing a run. **Retry** reuses the reviewed plan.

## Verification fails

A failed canary marks the workflow **verification failed**. Always-on endpoints refuse an unverified model unless you explicitly override. After a macOS or MLX change, verified models go stale and Watch alerts offer **Re-verify**.

## A model will not load on request

The cold-load check needs fresh headroom for weights × 1.10 + 1.5 GB + the endpoint's reserve. Unknown memory or weight size blocks the load. Free memory, lower the endpoint's reserve in Run, or unload another endpoint. Changed model files require a fresh serving plan.

## Client wiring is refused

Confirmation refuses a server that stopped or changed since the preview, a config file that changed since the preview, and symbolic links. **Refresh servers**, preview again and confirm.

## Training or controlled studies cannot load

Re-run `make install` for the engine's `requirements-lab.txt`. Video generation needs **Studies → Runtime setup → Install video runtime**. Read the error and the receipt before retrying; **Recover interrupted jobs** reconciles jobs left by a crash.

## An earlier queue cannot be imported

Stop the former Workbench server first, then choose the exact earlier `convert-queue.json` in Activity. Import preserves the source and an exact backup and refuses invalid state. Do not delete the only copy of queued work while resolving an error.

## A reclaimed model is needed again

Use **Put back** in Reclaim for quarantined items, or **Restore originals** for source cleanup. Changed items or occupied destinations refuse restore. Files in the Trash keep their disk space until it is emptied. Rescan Library afterwards.

## An update is unavailable or refused

**Settings → Updates** installs only a published DMG whose sha256 matches GitHub's digest and which is a notarized Developer ID build of MLX Workbench. An app running from a disk image, a translocated location or an unwritable folder cannot replace itself; move it to **Applications** first. v0.4.0 installations need one manual DMG upgrade.

## A reported model size is wrong

The opt-in, read-only checks compare reported bytes with the files on disk:

```bash
make test-live-scan
make test-swift-live-scan
```

Resolve a mismatch before converting that model. These checks do not certify conversion quality or inference.

## Reporting a problem

Include the app version and commit, macOS version and chip, Python version, engine tag or commit, the failing screen and the redacted error. Leave out credentials and proprietary model data.
