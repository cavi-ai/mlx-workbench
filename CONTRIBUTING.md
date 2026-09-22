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
- `mlx-mac/` — native SwiftUI app; `mlx-mac/assets/app-icon.svg` is the icon
  master (regenerate `AppIcon.appiconset` PNGs from it with ImageMagick)
- `tests/` — unittest, fake subprocess runner (no live Hub)
- `Makefile` — `install` / `start` / `stop` / `test` / `dmg` / …

## App icon and DMG

The app icon lives in `mlx-mac/assets/app-icon.svg` (1024×1024 squircle) and
is compiled into the app from `AppIcon.appiconset` at build time. After
changing the SVG, re-render the PNGs into the appiconset (16–1024 px, the
standard macOS ladder) and commit both.

`make dmg` builds the Release app and packages it as a compressed DMG with
an `/Applications` symlink, ad-hoc signed. For distribution signing:

```bash
make dmg CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Notarization (`notarytool` + `stapler`) is a separate manual step after
signing with a Developer ID. DMGs land in `.release/` (gitignored).

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

### Versioned docs rebuilds

`docs/mlx-workbench/v*/` is a gitignored build artifact of
`make docs-build`, not source. After editing anything under
`docs/mlx-workbench/source/`, just re-run `make docs-build`: a versioned
tree with the same file set but stale content is regenerated in place, and
`make docs-verify` then re-checks the manifest. A versioned tree holding
*unexpected files* (stray writes, a different schema) still refuses with
`dirty output` — delete `docs/mlx-workbench/v<current>/` and rebuild in that
case, which is always safe because the directory is generated.

Patch releases may correct behavior and docs without changing the subprocess
contract; bumping `vendor/mlx-agent` is a product change and gets its own
release note.
