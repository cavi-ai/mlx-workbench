# mlx-workbench

Local UI for the [mlx-agent](https://github.com/cavi-ai/mlx-agent) model lifecycle on Apple Silicon.

This app is a browser front end. Conversion, discovery, doctor, and serve logic live in mlx-agent; workbench shells out to `scripts/mlx-agent` with `--json` and renders what comes back. The two repositories stay independently versioned: no Python imports from mlx-agent, one subprocess boundary.

Standard library only. No third-party dependencies, no build step. The HTTP server binds loopback only. Child mlx-agent commands may contact the Hugging Face Hub (Scout / Doctor).

## Requirements

- macOS on Apple Silicon
- Python 3.9+
- Git (to clone with the mlx-agent submodule)

Conversion and serve still need the usual mlx-agent runtimes on the machine (`mlx-lm`, and for GGUF: `torch`, `transformers`, `gguf`). Nothing is installed for you.

## Install

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

The default agent path is `vendor/mlx-agent` (pinned release). Override with Settings, or `$MLX_AGENT_HOME`, for a local mlx-agent checkout.

## Run

```bash
python3 -m mlx_workbench
# or
python3 scripts/mlx-workbench
```

It binds `127.0.0.1`, prints its URL, reports the resolved mlx-agent path, and opens a browser. `--port`, `--host`, `--config`, and `--no-open` are available.

## What it shows

| Tab | Role |
| --- | --- |
| **Models** | Local `.gguf` inventory via `convert scan`: pending, converted, companion, shard |
| **Duplicates** | Exact vs variant groups; quarantine moves (never deletes) |
| **Scout** | `discover` — Hub models suited to this host (optional `--fast`) |
| **Doctor** | `doctor models` — wired configs, cache drift, endpoint health |
| **Serve** | Preview/confirm `serve start`, list/stop owned servers |
| **Jobs** | Convert + serve receipts; click a row to tail its log |
| **Advanced** | Any mlx-agent argv (tokens only; `--json` added for you) |
| **Settings** | Scan roots, output dir, agent path, quarantine, quantization |

## Converting

Every conversion is previewed before it runs: command, output path, and preview hash. Only a reviewed plan can be confirmed. The job runs detached under mlx-agent receipts; open **Jobs** for state and log tail.

Quality is capped by the source: a Q4 GGUF converted to MLX 4-bit has been quantized twice. Prefer original fp16 weights when you have them.

## Configuration

`~/.config/mlx-workbench/config.json`, editable from Settings. `MLX_WORKBENCH_CONFIG` overrides the location. `MLX_AGENT_HOME` overrides agent discovery when it points at a checkout that contains `scripts/mlx-agent`.

```json
{
  "gguf_roots": ["/Users/you/.lmstudio/models"],
  "mlx_roots": [],
  "output_dir": "/Users/you/models/mlx",
  "mlx_agent_path": "",
  "quarantine_dir": "/Users/you/.local/share/mlx-workbench/quarantine",
  "q_bits": 4,
  "signatures": true,
  "host": "127.0.0.1",
  "port": 8765
}
```

Leave `mlx_agent_path` empty to use the vendored submodule (or env / sibling discovery).

## Security

Loopback bind only, same-origin checks, and a per-process session token on every API call. The server refuses a non-loopback bind. Quarantine moves are restricted to `.gguf` files inside a configured root. Agent arguments are argv tokens — never a shell string. Job logs are readable only when advertised by convert/serve status.

## Updating the mlx-agent pin

```bash
cd vendor/mlx-agent
git fetch --tags
git checkout v0.5.0   # or a newer release tag
cd ../..
git add vendor/mlx-agent
```

## Tests

```bash
python3 -m unittest discover -s tests -t .
```

## License

MIT — see [LICENSE](LICENSE). mlx-agent is also MIT; see that repository for its terms.
