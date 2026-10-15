# Version and support

These docs describe MLX Workbench {{PRODUCT_VERSION}}, release {{RELEASE_TAG}}, built from commit `{{RELEASE_COMMIT}}`.

## Versioning

Workbench and MLX Agent are versioned independently. Each Workbench release pins a tested engine revision in `vendor/mlx-agent`; use that pin and its runtime. An engine update changes the subprocess contract and needs compatibility validation, so engine bumps get their own changelog entry. Release notes are in `CHANGELOG.md` and on the [releases page](https://github.com/cavi-ai/mlx-workbench/releases).

## Supported platform

- macOS on Apple Silicon
- Python 3.12 for the engine runtime
- Xcode for source builds; the release DMG needs none

## Updating

Installed apps update from **Settings → Updates** (Releases or Nightly). A DMG update replaces only the app, so bring the engine checkout to the matching tag:

```bash
git fetch origin --tags
git checkout {{RELEASE_TAG}}
git submodule update --init --recursive
make install
```

Keep local changes safe before changing the checkout. Confirm the engine path in Settings afterwards. Settings, comparison history and model files stay where they are.

Source builds update their own checkout from **Settings → Updates** and rebuild before relaunching.

## Upgrading from v0.4.0

v0.5.0 removed the browser UI and its HTTP routes; use the native app. A v0.4.0 DMG app does not contain the release updater: quit it, install the new DMG by hand, then update the engine checkout as above.

Stop a former browser server before importing its `convert-queue.json` in Activity. Import preserves the source and an exact backup. Browser serve presets are not native endpoint profiles.
