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

`make test-swift` runs the XCTest suite hosted in the app. By default, hosted tests skip launch-time live work and resolve state paths into a fresh temporary directory per test. Explicit real-runtime acceptance tests require their opt-in environment variables. UI tests run a separate app process.

`tests/fixtures/` is consumed by both the Python suite and the XCTest suite. A fixture change must keep both green.

### Trained adapter acceptance

Use a completed LoRA receipt and an existing MLX-LM runtime to check Run against
real local artifacts. This bounded test accepts a base smaller than 1 GB, starts
an owned loopback server, requests a short response and stops the server. It
leaves the training receipt unchanged and writes results beneath `.run/`.
It does not train a new adapter or measure quality improvement.

```bash
TEST_RUNNER_MLX_WORKBENCH_REAL_ADAPTER_RECEIPT=/absolute/path/to/completed-receipt.json \
TEST_RUNNER_MLX_WORKBENCH_PYTHON=/absolute/path/to/runtime/bin/python \
TEST_RUNNER_HF_HUB_OFFLINE=1 TEST_RUNNER_TRANSFORMERS_OFFLINE=1 \
xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
  -destination 'platform=macOS' \
  -only-testing:mlx-workbenchTests/TrainedAdapterRuntimeTests/testCompletedLocalAdapterServesThroughRunAndStops test
```

To check Training evaluation with the same receipt and runtime, select
`-only-testing:mlx-workbenchTests/TrainedAdapterRuntimeTests/testCompletedLocalAdapterEvaluationRetainsAndReopensRealOutputs`
instead. It previews and confirms the native base-versus-adapter comparison,
retains its outputs in an isolated workspace beneath `.run/`, and reopens the
report from evaluation history. The training receipt stays unchanged and the
report records no quality judgment.

To exercise training with a blank output field, provide a cached base smaller
than 1 GB and a dataset containing one example in each of `train.jsonl` and
`valid.jsonl`. This opt-in test previews and confirms one iteration with batch
size 1, checks the completed receipt and adapter identity, and retains its
isolated application-data tree beneath `.run/`.

```bash
TEST_RUNNER_MLX_WORKBENCH_REAL_TRAINING_REPO=publisher/model \
TEST_RUNNER_MLX_WORKBENCH_REAL_TRAINING_DATA=/absolute/path/to/dataset \
TEST_RUNNER_MLX_WORKBENCH_PYTHON=/absolute/path/to/runtime/bin/python \
TEST_RUNNER_HF_HUB_OFFLINE=1 TEST_RUNNER_TRANSFORMERS_OFFLINE=1 \
xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
  -destination 'platform=macOS' \
  -only-testing:mlx-workbenchTests/TrainedAdapterRuntimeTests/testBlankOutputTrainingCreatesARealAdapterInApplicationSupport test
```

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

## Signed release candidates

Fresh CI builds require `DEVELOPER_ID_P12_BASE64` (a base64-encoded, password-encrypted PKCS#12 export containing the Developer ID Application certificate and private key) and `DEVELOPER_ID_P12_PASSWORD`. The workflow imports this identity into a temporary keychain, checks that it belongs to the configured team, and removes the keychain and credential files on exit. `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` authenticate notarization. A signed-in local Xcode account does not provide credentials to GitHub runners.

The Signed DMG workflow can build an unpublished **candidate** from a full commit SHA. It retains the disk image and acceptance receipt as a workflow artifact, without changing a release or tag. Release and nightly disk images pass the same acceptance check before upload.

From a clean checkout matching the candidate commit, run:

```bash
make accept-release-candidate RELEASE_DMG=/absolute/path/to/candidate.dmg
```

This uses the real download, digest, signature, disk-image mount and bundle-replacement path in an isolated directory, then prepares and reopens the packaged runtime source payload. The gate refuses skipped tests and records the candidate digest and source commit under `.run/release-candidate/`. It does not launch model inference or install Python packages.

Before a version release, also run the existing packaged-runtime installation UI test in an isolated VM with the candidate disk image, and the model-specific native acceptance routes above. These cover setup and inference beyond the signed-image installation gate.
