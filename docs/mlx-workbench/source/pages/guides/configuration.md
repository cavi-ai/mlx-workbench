# Configuration

The default configuration file is:

```text
~/.config/mlx-workbench/config.json
```

Set `MLX_WORKBENCH_CONFIG` to select another configuration file. Set
`MLX_AGENT_HOME` to override agent discovery with a checkout containing
`scripts/mlx-agent`. The Settings tab writes the same schema.

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

An empty `mlx_agent_path` selects `MLX_AGENT_HOME`, the pinned vendor
submodule, or a recognized sibling checkout in that order. Host values are
limited to `127.0.0.1`, `localhost`, or `::1`.

The default durable queue is
`$XDG_STATE_HOME/mlx-workbench/convert-queue.json`, falling back to
`~/.local/state/mlx-workbench/convert-queue.json`. When `--config` selects a
profile, `convert-queue.json` is stored beside that profile. The quarantine
default follows `XDG_DATA_HOME` or `~/.local/share/mlx-workbench/quarantine`.
