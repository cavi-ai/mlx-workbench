# State and files

## App state

The app keeps its records as JSON files in `~/Library/Application Support/mlx-workbench`. Each store replaces its file atomically and refuses a symbolic link in place of the file.

| File | Holds |
|---|---|
| `model-workflows.json` | Conversion workflows and their lifecycle state |
| `verification-reports.json` | Quality gate verdicts |
| `comparison-runs.json` | Comparison runs, prompt snapshots, samples and quality reviews |
| `prompt-sets.json` | Saved prompt sets |
| `serving-profiles.json` | Saved serving profiles and their verification |
| `endpoint-fleet.json` | Always-on endpoints and their memory policies |
| `recommendation-preferences.json` | Preferred model per use case |
| `usage-stamps.json` | When each model was last served, verified or benchmarked |
| `wiring-transactions.json` | Client wiring transactions, with the backup locations used for rollback |
| `source-cleanup.json` | Original sources moved to the Trash after verification, with restore metadata |
| `watch-state.json`, `watch-alerts.json` | Watch baselines, alerts, snooze and mute state |
| `workflow-evidence.json` | Imported workflow reports |

| Folder | Holds |
|---|---|
| `comparison-outputs/<run-id>/` | Comparison inputs and outputs; the 10 newest media runs keep their files |
| `prompt-set-inputs/<uuid>/` | Input files owned by saved prompt sets |

`endpoint-config.json` from earlier releases is migrated once into `endpoint-fleet.json` and then only read.

## Other locations

| Location | Holds | Owner |
|---|---|---|
| `~/.config/mlx-workbench/config.json` | Configuration; see [Configuration](configuration.md) | App |
| `<quarantine_dir>/quarantine-ledger.jsonl` | Quarantine and Trash history | App |
| `~/Library/Application Support/mlx-agent/lab` | Experiment database and artifacts | Engine |
| `~/Library/LaunchAgents/ai.cavi.mlxworkbench.endpoint.plist` | Optional endpoint login item | App |
| `~/.cache/mlx-agent/strata` | Optional Strata runtime | Engine |

Conversion jobs, their queue, serving processes and training runs leave receipts in the engine's own state; the app reads them and never treats its own records as the authority on what is running.

## Earlier queue files

Before the engine owned the conversion queue, Workbench kept `convert-queue.json` beside its configuration or under `$XDG_STATE_HOME/mlx-workbench` (default `~/.local/state/mlx-workbench`). Those files remain explicit import sources in Activity. Stop the former server before importing; the source and an exact backup are preserved.

## Model files

The app never moves model files on its own. Conversions write to the output directory. Deletion, quarantine, Trash and source cleanup happen only through their reviewed actions in Library and Reclaim.
