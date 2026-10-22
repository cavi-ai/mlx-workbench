# Health and alerts

## Health

**Client and host setup → Open setup doctor…** opens the Clients setup doctor for missing client configs, endpoint mismatches and local model-host connections. It offers official installation guides, targeted config previews with backup and rollback, and the existing host connection editor and read-only test. Engine and model-runtime repairs remain in Health; see [Clients](clients.md).

**Health** leads with checks of the engine checkout, base Python environment, conversion tools and mlx-lm server (**Base runtime checks passed**, **Base conversion needs setup**, **Base serving needs setup**). It names missing components, with a command to copy or a link to the right setting. **Install Runtime…** runs `make install` in the engine checkout to install the base dependencies.

These checks do not establish readiness of isolated optional backends or Strata. **Model-specific runtimes → Open Run** leads to serving preview, which checks the selected model's runtime before confirmation. A successful base check does not prove that every model can run, and a missing base component does not establish that an isolated runtime is unavailable.

Base checks use the selected Python interpreter and the same PATH order as model operations. A missing or stalled interpreter, malformed response or excessive output leaves the checks unavailable with a reason. Checks stop their processes after a five-second probe deadline; they do not load a model.

Before a base installation, read-only prerequisite checks identify missing Command Line Tools, Python or uv. **Recheck prerequisites** refreshes them after setup. Install stays disabled until those checks pass, and confirmation rechecks them before starting `make`. Existing environment files are kept when repair is needed.

Guided installation shows the installation being run and the final
base-tool check. **Cancel installation** stops only that installer's process group;
retry stays disabled until its processes exit and the tool check finishes. The
same status and cancellation controls appear in Studies for study-tool and video
runtime installs. Base-tool checks do not certify those optional runtimes.

Cancellation and failures retain the install log. They can leave a partially
installed environment; Workbench keeps those files and does not automatically
delete or rebuild the environment. Review **Tool check details** and **Install
log**, then explicitly retry **Install Runtime…** or the relevant Studies install.
**Install command finished** reports the command's exit, separately from whether
conversion and base serving tools passed their checks. These checks do not load
a model or prove model-specific readiness.

**Model-specific runtimes** also lists optional MLX backend installation records, target versions and declared tasks. Health refreshes them when opened; **Refresh backends** checks again after setup. **Installed** does not mean that a model has loaded or passed verification. Other states distinguish an installation in progress, a failed install, an absent installation and an unknown engine state. Base mlx-lm checks remain above this list; Strata is separate.

Each successful check records its time. A failed refresh keeps the last result with an explicit stale label and the error; a successful retry replaces it. Changing the engine checkout clears the previous checkout's result. **Add from Hugging Face…** opens model intake, where missing dependencies keep their existing installation preview and confirmation. Opening Health or refreshing its status starts no installation, model download or generation.

For an existing local model marked **Needs Runtime**, **Library → Repair runtime…** opens a targeted card at the top of Health. It checks the model's declared backend and offers **Review installation…** for an absent or failed optional backend. Review the package, target version, destination and download hosts, then choose **Confirm installation**. Canceling the review installs nothing. A failed attempt keeps the model selected and requires a fresh preview before retrying; unknown states require a status refresh. Built-in backends use the base runtime setup instead.

**Return to model** rescans the library and reveals the original model with its refreshed readiness. A failed scan or changed model keeps the recovery card open with an error. Installing a backend does not verify or start the model, and this repair does not download model weights. Run and verification retain their separate checks and confirmation steps.

When the engine reports an installation log, **View installation log…** opens a read-only excerpt with the recorded path and start time. It reads up to the last 64 KiB and shows up to 80 lines, with a label when output is shortened. Empty and unreadable logs have explicit messages; links and special files are refused. Viewing a log never retries an installation. Close the log and choose **Review installation…** for a fresh preview before another attempt. Changing the model or engine discards the previous excerpt.

It also counts verified models whose verification still matches this environment, and lists model health findings from the engine's `doctor models` scan:

| Finding | Meaning |
|---|---|
| Incomplete download | A Hugging Face cache entry that never finished; reclaim it in [Reclaim](reclaim.md) |
| Client config names a missing model | A wired client points at a model that is gone |
| Wired file changed after wiring | A client config differs from what the wiring wrote |
| Wired file missing | A client config the wiring wrote no longer exists |
| Port claimed by two runtimes | Two servers report the same port |

**Setup Assistant…** reopens the first-launch assistant: a four-step sheet over the same engine, runtime and model-folder checks. **Review setup** summarizes the current base checks and links back to any engine or runtime step that needs attention. **Scan my library** is offered when those checks pass; otherwise **Finish for now** closes the review without claiming readiness or starting a scan. Finishing either way is remembered. **Skip setup** leaves it unfinished, so it returns on the next launch. Model-specific readiness remains separate from these base checks.

## Activity recovery

When Activity cannot read conversion, study, training, queue or server status,
the error offers **Retry status** and **Open Health**. Retry refreshes the existing
records without resubmitting jobs. Normal conversion-completion reconciliation,
including its fresh scan and verification gate, still applies. Repeated retries are disabled while
the read is in progress. Health opens the existing engine and runtime checks;
installation still requires its separate confirmation.

Previously loaded jobs remain visible when a status read fails. Those records
may have changed since the last successful read. A successful retry replaces
the relevant status and clears its read error; it does not turn a failed job
into a successful one.

Failed training jobs offer **View log** when a log path was recorded, alongside
**Review training setup**. The latter opens Training without changing its draft
or submitting a job. Correct the inputs, use **Check setup**, then preview and
confirm a new run explicitly. Study jobs retain their existing Studies controls;
conversion retry retains its preview and confirmation boundary.

Activity's log window reads only a bounded tail of a regular file in the
background: at most 64 KiB and 80 lines. Larger logs are labeled truncated.
Empty, missing, linked or non-regular log files are reported separately from job
status. Opening a log never restarts work.

## Watch alerts

With **Settings → Advisors → Watch & regression alerts** on, the app checks two kinds of change and shows them under **Watch alerts** on Overview:

- **Upstream changes.** The engine's `watch diff` digests changes to the Hugging Face repositories your models came from. The first check sets a baseline silently, and network failures stay silent.
- **Environment drift.** A macOS or MLX change makes verified models stale. The alert offers **Re-verify** to run the quality gate again for those models.

Alerts are deduplicated. **Snooze**, **Snooze 7 days** and **Mute** persist across launches.
New alerts appear and send notifications after their batch is saved. Saving runs
in the background; a failed save keeps the previous alerts and shows a storage
error. A later check retries unsaved findings.
