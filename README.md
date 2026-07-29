# mlx-workbench

A local UI for turning GGUF weights already on your Mac into MLX models, and for
finding the redundant copies eating your disk.

The conversion logic is not here. This app is a browser front end over the
`mlx-converter` skill bundled with [mlx-agent](https://github.com/cavi-ai/mlx-agent);
it shells out to that skill and renders what comes back. The two repositories
stay independently versioned: no imports, no vendored code, one subprocess
boundary.

Standard library only. No dependencies, no build step, no network access.

## Run

```bash
python3 scripts/mlx-workbench
```

It binds `127.0.0.1`, prints its URL, and opens a browser. `--port`, `--host`,
`--config`, and `--no-open` are available.

Point it at an mlx-agent checkout under **Settings** on first run (a sibling
`../mlx-agent` directory or `$MLX_AGENT_HOME` is detected automatically).

## What it shows

**Models** — every `.gguf` under the configured roots, with its architecture,
quantization, size, and one of:

| Status | Meaning |
| --- | --- |
| `pending` | No MLX output found. This is the convert list. |
| `converted` | An MLX output exists. Hover the output column for how it was matched. |
| `companion` | A projector (`mmproj`) sidecar — belongs to a base model, not converted alone. |
| `shard` | A non-first shard of a split model (hidden; convert the first shard). |

**Duplicates** — two kinds, deliberately different in strength:

- `exact` — same bytes, or the same model at the same quantization. Everything
  outside the keeper is redundant, and the reclaimable total is shown.
- `variant` — the same model at different quantization levels. Listed for
  visibility only; which one you keep is a quality decision, not a cleanup one.

**Jobs** — conversion receipts cross-checked against live processes.

**Settings** — scan roots, MLX output roots, output directory, mlx-agent path,
quarantine directory, default quantization, and whether to compute content
signatures (exact duplicate detection, slower on large collections).

## Converting

Every conversion is previewed before it runs: the exact command, output path,
and preview hash are shown, and only a reviewed plan can be confirmed. The job
then runs detached under mlx-agent's receipt machinery.

Conversion requires `mlx-lm` on `PATH` plus `torch`, `transformers`, and `gguf`
importable by the same interpreter. Nothing is installed for you; missing pieces
are reported by name.

Quality is capped by the source: a Q4 GGUF converted to MLX 4-bit has been
quantized twice. Convert the original fp16 weights when you have them.

## Removing duplicates

Nothing is ever deleted. "Move to quarantine" relocates a file into the
quarantine directory and records where it came from; deleting it afterwards is a
deliberate act you take yourself. Only `.gguf` files under a configured scan
root can be moved.

## Configuration

`~/.config/mlx-workbench/config.json`, editable from the Settings tab or by
hand. `MLX_WORKBENCH_CONFIG` overrides the location.

```json
{
  "gguf_roots": ["/Users/you/.lmstudio/models"],
  "mlx_roots": [],
  "output_dir": "/Users/you/models/mlx",
  "mlx_agent_path": "/Users/you/src/mlx-agent",
  "quarantine_dir": "/Users/you/.local/share/mlx-workbench/quarantine",
  "q_bits": 4,
  "signatures": true,
  "host": "127.0.0.1",
  "port": 8765
}
```

## Security

Loopback bind only, same-origin checks, and a per-process session token on every
API call. The server refuses to bind a non-loopback address. Path handling is
bounded: quarantine moves are restricted to `.gguf` files inside a configured
root, and every conversion argument is passed as argv — never through a shell.

## Tests

```bash
python3 -m unittest discover -s tests -t .
```

## License

MIT
