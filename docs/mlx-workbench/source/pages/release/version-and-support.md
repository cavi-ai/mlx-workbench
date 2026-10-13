# Version and support

These docs describe MLX Workbench {{PRODUCT_VERSION}}, release
{{RELEASE_TAG}}, built from commit `{{RELEASE_COMMIT}}`.

Workbench and MLX Agent are independently versioned. Use this release's pinned
`vendor/mlx-agent` and matching runtime. Engine updates change the subprocess
contract and require compatibility validation.

macOS on Apple Silicon with Python 3.12 is supported. Xcode is required for
source builds; a release DMG supplies the native application.

## Upgrade from v0.4.0

This release removes the browser UI and HTTP application routes. Use the
native app; previous UI-server commands and browser integrations no longer
apply. Existing model weights do not need to be moved.

Quit a v0.4.0 DMG app and install the new release DMG manually. The v0.4.0
distribution does not contain the new release installer. Update the runtime
checkout:

```bash
git fetch origin --tags
git checkout {{RELEASE_TAG}}
git submodule update --init --recursive
make install
```

Preserve local changes before changing the checkout revision. Confirm the
engine path in Settings. Existing native settings and comparison history
retain their state locations. Missing or pruned media stays labeled.

Stop a former browser server before explicitly importing its
`convert-queue.json` in Activity. Import preserves its source and an exact
backup. Browser serve presets are not native endpoint profiles.

## Later updates

Installed apps use **Settings → Updates** for Releases or the manually
published Nightly channel. Downloads require a published sha256 digest and
a notarized Developer ID build. Source-built apps update their checkout and
require rebuild and relaunch.

For diagnostics, include version and commit, macOS and chip, Python version,
engine tag or commit, failing screen, and redacted error. Exclude credentials
and proprietary model data.
