# Health and alerts

## Health

**Health** leads with runtime readiness: whether Prepare and Run can work on this Mac (**Ready to prepare and run**, **Prepare needs setup**, **Run needs setup**). It names what is missing, such as the engine checkout or the Python interpreter, with a command to copy or a link to the right setting. When the runtime is missing, **Install Runtime…** runs `make install` in the engine checkout.

It also counts verified models whose verification still matches this environment, and lists model health findings from the engine's `doctor models` scan:

| Finding | Meaning |
|---|---|
| Incomplete download | A Hugging Face cache entry that never finished; reclaim it in [Reclaim](reclaim.md) |
| Client config names a missing model | A wired client points at a model that is gone |
| Wired file changed after wiring | A client config differs from what the wiring wrote |
| Wired file missing | A client config the wiring wrote no longer exists |
| Port claimed by two runtimes | Two servers report the same port |

**Setup Assistant…** reopens the first-launch assistant: a four-step sheet over the same engine, runtime and model-folder checks. Completing it once is remembered.

## Watch alerts

With **Settings → Advisors → Watch & regression alerts** on, the app checks two kinds of change and shows them under **Watch alerts** on Overview:

- **Upstream changes.** The engine's `watch diff` digests changes to the Hugging Face repositories your models came from. The first check sets a baseline silently, and network failures stay silent.
- **Environment drift.** A macOS or MLX change makes verified models stale. The alert offers **Re-verify** to run the quality gate again for those models.

Alerts are deduplicated. **Snooze**, **Snooze 7 days** and **Mute** persist across launches.
