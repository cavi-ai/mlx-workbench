# State and files

## App state

The app keeps its records in `~/Library/Application Support/mlx-workbench`. JSON stores replace their files atomically. Workflow, verification and comparison archives use transactional SQLite records. Stores refuse a symbolic link in place of the file.

History loads and saves run in the background. The toolbar shows workflow history progress; conversion and verification wait for their required state to be saved before proceeding.
Usage stamps and Watch state also load and save in the background. Usage updates
retain the last serving timestamp when a later verification or comparison records
use. Failed writes preserve the saved file. Current usage observations remain
available until quit, with a warning in Overview and Reclaim when they could not
be saved.

| File | Holds |
|---|---|
| `model-workflows.json.sqlite` | Conversion workflows and their lifecycle state |
| `verification-reports.json.sqlite` | Quality gate verdicts |
| `comparison-runs.json.sqlite` | Native comparison runs, indexed history entries, prompt snapshots, samples and quality reviews |
| `hosted-comparison-runs.json.sqlite` | Hosted comparison runs, captured conditions and submitted workflow evidence |
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
| `runtimes/<manifest-sha256>/` | Prepared bundled engine sources and their explicitly installed Python environment; existing versions are retained |

Existing `model-workflows.json`, `verification-reports.json`, `comparison-runs.json` and `hosted-comparison-runs.json` arrays migrate once into their SQLite archives. Migration validates every record in one transaction and leaves the original JSON files untouched as backups. Later edits use the archives; editing a backup does not update current history. Preserve the archives when backing up or moving app state.

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
