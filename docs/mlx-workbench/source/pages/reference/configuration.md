# Configuration

## The config file

The app reads `~/.config/mlx-workbench/config.json`. A missing or unreadable file loads as defaults; **Settings** writes the file when you save.

| Variable | Effect |
|---|---|
| `MLX_WORKBENCH_CONFIG` | Path of an explicit config file |
| `XDG_CONFIG_HOME` | Changes the base directory from `~/.config` |
| `XDG_DATA_HOME` | Changes the base of the default quarantine directory from `~/.local/share` |
| `MLX_AGENT_HOME` | Engine checkout used when the config names none; must contain `scripts/mlx-agent` |
| `MLX_WORKBENCH_PYTHON`, `PYTHON` | Python interpreter for engine commands |

```json
{
  "schema_version": "1.0",
  "gguf_roots": ["/Users/you/.lmstudio/models"],
  "mlx_roots": ["/Users/you/models/mlx-extra"],
  "output_dir": "/Users/you/models/mlx",
  "mlx_agent_path": "/Users/you/mlx-workbench/vendor/mlx-agent",
  "quarantine_dir": "/Users/you/.local/share/mlx-workbench/quarantine",
  "q_bits": 4,
  "signatures": true,
  "verification_enabled": true,
  "watch_enabled": true,
  "fit_reserve_gb": 4,
  "reclaim_stale_days": 60,
  "comparison_max_tokens": 512
}
```

## Keys

| Key | Settings | Default | Meaning |
|---|---|---|---|
| `gguf_roots` | Model locations → GGUF roots | Discovered | Folders scanned for GGUF files, up to 32 |
| `mlx_roots` | Model locations → MLX roots | `[]` | Folders scanned for MLX models, up to 32 |
| `output_dir` | Storage → Output directory | `~/models/mlx` | Where conversions are written; also scanned as an MLX root |
| `mlx_agent_path` | Engine → mlx-agent checkout | Discovered | Engine checkout containing `scripts/mlx-agent`, not the script itself |
| `quarantine_dir` | Storage → Quarantine directory | `~/.local/share/mlx-workbench/quarantine` | Where Reclaim moves quarantined files |
| `q_bits` | Conversion defaults → Default bits | `4` | Default quantization for new previews: 4 or 8 |
| `signatures` | Conversion defaults → Sign converted outputs | `true` | When off, scans pass `--no-signature` |
| `verification_enabled` | Advisors → Verify conversions | `true` | Runs the conversion quality gate |
| `watch_enabled` | Advisors → Watch & regression alerts | `true` | Upstream and environment-drift alerts |
| `fit_reserve_gb` | Advisors → Fit reserve | `4` | Memory kept free for the system when judging fit, 0–16 |
| `reclaim_stale_days` | Advisors → Stale after | `60` | Days without use before Reclaim flags a model, 2–365 |
| `comparison_max_tokens` | Advisors → Comparison max tokens | `512` | Per-prompt cap during measured comparisons, 64–4096 |

Values outside a key's range fall back to its default. Saving from Settings merges the fields it manages into the existing file and keeps every other key, then replaces the file atomically through a temporary file. Valid legacy `host` and `port` values are preserved from the stored file, including edits made after opening the form. The native app has no Workbench API server; manage model servers and endpoint ports in **Run**, also reachable through **Settings → Serving → Open Run**.

## Discovery

With no `gguf_roots` stored, the app uses whichever of these exist: `~/.cache/huggingface/hub`, `~/.cache/lm-studio/models`, `~/.lmstudio/models`, `~/.models`, `~/models`, `~/Models`, then LM Studio's configured downloads folder. A folder inside an earlier one is skipped.

With no `mlx_agent_path`, the engine is found in this order: `MLX_AGENT_HOME`, the checkout's `vendor/mlx-agent`, then a sibling `mlx-agent` checkout. Source builds find their own vendored engine; distribution builds contain no source path and need the setting.

**Settings → Engine → Detect** searches these locations and checks for an already
prepared copy of the app's bundled engine. Detection runs without blocking the
form and shows its progress and result beside the path and in the pinned status
bar. If nothing is found or a check fails, your current path stays in place;
**Choose…** selects a checkout and **Open Health** leads to bundled engine setup.
Detection never prepares, installs or saves an engine. Review a detected path
and use **Save** to apply it. Saving shows progress, followed by a saved or failed
result; editing again shows **Unsaved changes**.

## Python

The app resolves the engine's Python in this order: `MLX_WORKBENCH_PYTHON` or `PYTHON`, the Workbench checkout's `.venv`, then `PATH`. For an installed app, the Workbench checkout is the one whose `vendor/mlx-agent` is the configured engine. Python 3.12 is supported.
