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

## Versioning and releases

`mlx_workbench/__init__.py` (`__version__`) is the single version source of
truth. The Swift app's `MARKETING_VERSION`, the release-docs test constants,
and `CHANGELOG.md` headings are derived from it and checked by
`tests/test_version_sync.py` — never edit them by hand.

Cutting a release:

1. Record user-facing changes under `## [Unreleased]` in `CHANGELOG.md` as
   PRs land (Added / Changed / Fixed / Security).
2. `make version-bump V=x.y.z` — bumps the version everywhere and promotes
   the Unreleased section to the dated release section.
3. `make test && make docs-test && make test-swift` — all gates green.
4. Commit the bump, `git tag vx.y.z`, push the commit and tag.
5. Publish the GitHub release for the tag. `publish-docs.yml` verifies the
   tag matches `__version__`, re-runs the test gates, and attaches the
   immutable docs archive to the release.

Patch releases may correct behavior and docs without changing the subprocess
contract; bumping `vendor/mlx-agent` is a product change and gets its own
release note.
