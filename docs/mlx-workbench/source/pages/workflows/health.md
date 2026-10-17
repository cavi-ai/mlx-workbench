# Health and alerts

## Health

**Health** leads with checks of the engine checkout, base Python environment, conversion tools and mlx-lm server (**Base runtime checks passed**, **Base conversion needs setup**, **Base serving needs setup**). It names missing components, with a command to copy or a link to the right setting. **Install Runtime…** runs `make install` in the engine checkout to install the base dependencies.

These checks do not establish readiness of isolated optional backends or Strata. **Model-specific runtimes → Open Run** leads to serving preview, which checks the selected model's runtime before confirmation. A successful base check does not prove that every model can run, and a missing base component does not establish that an isolated runtime is unavailable.

**Model-specific runtimes** also lists optional MLX backend installation records, target versions and declared tasks. Health refreshes them when opened; **Refresh backends** checks again after setup. **Installed** does not mean that a model has loaded or passed verification. Other states distinguish an installation in progress, a failed install, an absent installation and an unknown engine state. Base mlx-lm checks remain above this list; Strata is separate.

Each successful check records its time. A failed refresh keeps the last result with an explicit stale label and the error; a successful retry replaces it. Changing the engine checkout clears the previous checkout's result. **Add from Hugging Face…** opens model intake, where missing dependencies keep their existing installation preview and confirmation. Opening Health or refreshing its status starts no installation, model download or generation.

It also counts verified models whose verification still matches this environment, and lists model health findings from the engine's `doctor models` scan:

| Finding | Meaning |
|---|---|
| Incomplete download | A Hugging Face cache entry that never finished; reclaim it in [Reclaim](reclaim.md) |
| Client config names a missing model | A wired client points at a model that is gone |
| Wired file changed after wiring | A client config differs from what the wiring wrote |
| Wired file missing | A client config the wiring wrote no longer exists |
| Port claimed by two runtimes | Two servers report the same port |

**Setup Assistant…** reopens the first-launch assistant: a four-step sheet over the same engine, runtime and model-folder checks. **Review setup** summarizes the current base checks and links back to any engine or runtime step that needs attention. **Scan my library** is offered when those checks pass; otherwise **Finish for now** closes the review without claiming readiness or starting a scan. Finishing either way is remembered. **Skip setup** leaves it unfinished, so it returns on the next launch. Model-specific readiness remains separate from these base checks.

## Watch alerts

With **Settings → Advisors → Watch & regression alerts** on, the app checks two kinds of change and shows them under **Watch alerts** on Overview:

- **Upstream changes.** The engine's `watch diff` digests changes to the Hugging Face repositories your models came from. The first check sets a baseline silently, and network failures stay silent.
- **Environment drift.** A macOS or MLX change makes verified models stale. The alert offers **Re-verify** to run the quality gate again for those models.

Alerts are deduplicated. **Snooze**, **Snooze 7 days** and **Mute** persist across launches.
