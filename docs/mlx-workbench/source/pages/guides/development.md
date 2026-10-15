# Development

## Layout

| Path | Contents |
|---|---|
| `mlx-mac/` | The native SwiftUI app. The Xcode project lists every source file explicitly; register new files in `project.pbxproj`. |
| `mlx_workbench/` | Python configuration and compatibility utilities, and the single version source (`__version__`) |
| `vendor/mlx-agent/` | The engine, as a git submodule pinned to a tested revision |
| `tests/` | Python unit and contract tests; `tests/fixtures/` is shared with the XCTest suite |
| `docs/mlx-workbench/source/` | These docs |
| `scripts/` | Launcher, docs build and Strata preparation scripts |

## Build and test

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
make install
make test
make test-swift
make start
```

`make test-swift` runs the XCTest suite hosted in the app. Hosted unit tests never start live services or touch real state: launch-time live work is skipped under XCTest, and default state paths resolve into a fresh temporary directory per test. UI tests run a separate app process.

`tests/fixtures/` is consumed by both the Python suite and the XCTest suite. A fixture change must keep both green.

## Engine boundary

The app reaches the engine only through `scripts/mlx-agent … --json`, with argv tokens and never a shell string. Every engine call runs off the main actor, so a long call never blocks serving status. Each engine child leads its own process group; on timeout or app quit the whole group gets SIGTERM, then SIGKILL after two seconds. Work the engine detaches, such as conversion jobs and servers, runs in its own session and is not stopped.

Never start a process from view evaluation. Launch-time live work belongs in `AppHost.startLiveServices()`.

Bump the engine to a tagged release rather than tracking its `main`:

```bash
cd vendor/mlx-agent
git fetch --tags
git checkout <tag>
cd ../..
git add vendor/mlx-agent
```

An engine bump is a product change and gets its own changelog entry.

## Docs

Pages live in `docs/mlx-workbench/source/pages/`, ordered by `navigation.json`. The build stamps the product version, release tag and release commit into placeholder tokens (see `scripts/docs/lib.mjs`) and fails on any unresolved token.

```bash
make docs-test
make docs-build
make docs-verify
```

`docs/mlx-workbench/v<version>/` is a generated, ignored build output. `make docs-build` regenerates a stale tree in place and refuses a tree with unexpected files; delete it and rebuild in that case.

On a published release, `publish-docs.yml` checks that the tag matches `__version__`, runs the tests, builds and verifies the docs, attaches `mlx-workbench-docs-v<version>.tar.gz` and its checksum to the release, and dispatches the release to cavi-ai.xyz. See `docs/mlx-workbench/CONSUMER.md` for the artifact contract.

## Releases

1. Record user-facing changes under `## [Unreleased]` in `CHANGELOG.md` as they land.
2. `make version-bump V=x.y.z` updates `__version__`, the app's `MARKETING_VERSION`, the docs test constants and the changelog. `tests/test_version_sync.py` enforces the sync.
3. Run `make test`, `make docs-test`, `make pip-audit` and `make test-swift`, plus the acceptance harnesses for changed native workflows.
4. Build and check the signed, notarized candidate, tag the commit and publish the release. `signed-dmg.yml` attaches the DMG and `publish-docs.yml` attaches the docs.

Nightly DMGs are built only when started by hand, and skip when `mlx-mac/`, `vendor/mlx-agent` and the `Makefile` are unchanged since the last nightly.
