# Version and support

These docs describe MLX Workbench {{PRODUCT_VERSION}}, release
{{RELEASE_TAG}}, built from commit `{{RELEASE_COMMIT}}`.

MLX Workbench and MLX Agent are independently versioned. This release expects
the pinned `vendor/mlx-agent` checkout shipped by the repository. Updating the
submodule changes the CLI boundary and should be tested as a separate product
change.

The supported environment is macOS on Apple Silicon with Python 3.12. Patch
releases may correct behavior and documentation without changing the product's
basic subprocess contract. Upgrade by checking out the desired release tag,
updating submodules, and running `make install` again.

For diagnostics, include the workbench version, macOS and chip details, Python
version, the pinned MLX Agent tag or commit, the failing tab and command, and a
redacted error envelope. Do not include session tokens, private model paths,
Hub credentials, or proprietary model data.
