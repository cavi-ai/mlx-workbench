# Contributing

## Setup

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
python3 -m unittest discover -s tests -t .
python3 -m mlx_workbench --no-open
```

mlx-agent is vendored at `vendor/mlx-agent`. Prefer bumping the submodule to a tagged release rather than tracking `main`.

## Layout

- `mlx_workbench/` — stdlib server, bridge, UI
- `vendor/mlx-agent/` — git submodule (CLI source of truth)
- `tests/` — unittest, fake subprocess runner (no live Hub)

## Boundaries

Do not import `mlx_agent` into this package. All agent work goes through `scripts/mlx-agent … --json`.
