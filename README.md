# mlx-workbench

Local UI for the [mlx-agent](https://github.com/cavi-ai/mlx-agent) model lifecycle on Apple Silicon.

This app is a browser front end. Conversion, discovery, doctor, and serve logic live in mlx-agent; workbench shells out to `scripts/mlx-agent` with `--json` and renders what comes back. The two repositories stay independently versioned: no Python imports from mlx-agent, one subprocess boundary.

The workbench package itself is stdlib-only (no pip deps for the UI server). `make install` creates a local `.venv` and adds convert/serve packages (`torch`, `transformers`, `gguf`, `mlx-lm`). The HTTP server binds loopback only. Child mlx-agent commands may contact the Hugging Face Hub (Scout / Doctor).

## Requirements

- macOS on Apple Silicon
- Git
- [uv](https://github.com/astral-sh/uv) recommended (or Python 3.12 via Homebrew)

## Install

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
make install    # submodule + .venv (Python 3.12) + torch/transformers/gguf/mlx-lm
make start
```

That is the whole setup. `make install` creates a project `.venv` (not Homebrew system Python) and installs convert/serve packages there. Re-run `make install` anytime to refresh.

The default agent path is `vendor/mlx-agent` (pinned release). Override with Settings, or `$MLX_AGENT_HOME`, for a local mlx-agent checkout.

## Run

```bash
make start     # background; logs in .run/mlx-workbench.log
make status
make open      # browser → http://127.0.0.1:8765/
make stop

# foreground (dev)
make run
# launcher prefers .venv when present
python3 scripts/mlx-workbench
```

`make start` / `make run` accept `PORT=9876` and `HOST=127.0.0.1`. The server prints its URL and the resolved mlx-agent path. `--config` and `--no-open` are available on the Python launcher.

## What it shows

| Tab | Role |
| --- | --- |
| **Models** | Local `.gguf` inventory via `convert scan`: pending, converted, companion, shard; multi-select queue |
| **Convert** | HF-cache convert via `convert start --repo` (local cache only; never downloads) |
| **Duplicates** | Exact vs variant groups; quarantine moves (never deletes) |
| **Scout** | `discover` — Hub candidates by role (table + Serve/Wire shortcuts) |
| **Adopt** | `adopt start` — durable role handoff |
| **Wire** | `wire apply` — preview/confirm config transaction |
| **Doctor** | `doctor models` — findings + incomplete-cache prune |
| **Serve** | Preview/confirm `serve start`; servers table with Stop |
| **Train** | LoRA train + fuse (preview/confirm) |
| **Jobs** | Convert / serve / lora / fuse receipts + log tail; workbench convert queue |
| **Advanced** | Any mlx-agent argv (tokens only; `--json` added for you) |
| **Settings** | Scan roots, output dir, agent path, quarantine, quantization |

## Converting

Every conversion is previewed before it runs: command, output path, and preview hash. Only a reviewed plan can be confirmed. The job runs detached under mlx-agent receipts; open **Jobs** for state and log tail.

mlx-agent allows one live convert at a time. Every confirmed plan is persisted before launch; extra plans remain FIFO in the workbench **queue**, auto-start when the live job finishes, and resume automatically after a server restart. Once launched, mlx-agent receipts remain the authority for process state and handoff recovery.

By default the queue is stored at `$XDG_STATE_HOME/mlx-workbench/convert-queue.json`, or `~/.local/state/mlx-workbench/convert-queue.json` when `XDG_STATE_HOME` is unset. An explicitly selected config profile keeps `convert-queue.json` beside that config. Invalid saved state is preserved as a numbered `convert-queue.json.N.corrupt` file and reported in **Jobs** instead of being overwritten silently.

**GGUF** sources come from **Models** (single Convert or multi-select Queue selected). **HF-cache** sources use the **Convert** tab (`publisher/model` already present under the local Hugging Face cache). Convert never downloads from the Hub.

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
make test
# or
python3 -m unittest discover -s tests -t .
```

## Make targets

| Target | Action |
| --- | --- |
| `make install` | Submodule + `.venv` + convert/serve packages |
| `make start` | Background UI (pid/log under `.run/`) |
| `make stop` | Stop background UI |
| `make restart` | `stop` then `start` |
| `make status` | Running? |
| `make run` | Foreground UI |
| `make open` | Open the loopback URL |
| `make test` | Unittest suite |
| `make check` / `make doctor` | Verify mlx-agent + convert deps |

## License

MIT — see [LICENSE](LICENSE). mlx-agent is also MIT; see that repository for its terms.
