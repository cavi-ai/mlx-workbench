# Contributing

## Setup (Apple Silicon Mac)

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
make install   # submodule + .venv + ML packages
make test
make start
```

mlx-agent is vendored at `vendor/mlx-agent`. Prefer bumping the submodule to a tagged release rather than tracking `main`.

## Layout

- `mlx_workbench/` — stdlib server, bridge, UI
- `vendor/mlx-agent/` — git submodule (CLI source of truth)
- `.venv/` — local Python 3.12 + convert/serve packages (gitignored)
- `tests/` — unittest, fake subprocess runner (no live Hub)
- `Makefile` — `install` / `start` / `stop` / `test` / …

## Boundaries

Do not import `mlx_agent` into this package. All agent work goes through `scripts/mlx-agent … --json`.
