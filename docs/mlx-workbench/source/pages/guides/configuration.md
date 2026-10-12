# Configuration

The native application reads `~/.config/mlx-workbench/config.json`.
`XDG_CONFIG_HOME` changes the configuration base;
`MLX_WORKBENCH_CONFIG` selects an explicit file. Settings manages model
roots, output and quarantine paths, runtime, and native options. Saving
overlays managed values while preserving other persisted keys.

Common fields:

```json
{
  "gguf_roots": ["/Users/you/models/gguf"],
  "mlx_roots": ["/Users/you/models/mlx"],
  "output_dir": "/Users/you/models/mlx",
  "mlx_agent_path": "/Users/you/mlx-workbench/vendor/mlx-agent",
  "quarantine_dir": "/Users/you/.local/share/mlx-workbench/quarantine",
  "q_bits": 4,
  "signatures": true
}
```

An engine path is a checkout containing `scripts/mlx-agent`, not the script
itself. `MLX_AGENT_HOME` supplies discovery for an unconfigured app.
Source builds can discover their vendor checkout; distribution builds
have no embedded checkout path and need explicit configuration.

Native JSON state and receipts use
`~/Library/Application Support/mlx-workbench`. Controlled experiments
default to `~/Library/Application Support/mlx-agent/lab`;
**Workspace…** previews adoption into another destination.

Earlier `convert-queue.json` files remain explicit import sources. They may
be beside a former configuration profile or under
`$XDG_STATE_HOME/mlx-workbench` (default `~/.local/state/mlx-workbench`).
The engine owns the shared conversion queue. Stop the former server before
importing; the source and an exact backup are preserved.
