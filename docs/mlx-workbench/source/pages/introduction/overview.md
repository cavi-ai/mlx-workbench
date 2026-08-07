# MLX Workbench overview

MLX Workbench {{PRODUCT_VERSION}} is a local browser interface for managing the
MLX model lifecycle on an Apple Silicon Mac. It inventories local weights,
previews conversions and serving plans, queues reviewed work, and shows the
receipts and logs returned by MLX Agent.

The workbench does not reimplement MLX Agent. Every agent operation crosses a
single subprocess boundary: the server invokes the pinned
`vendor/mlx-agent/scripts/mlx-agent` command with argv tokens and `--json`, then
renders its result envelope. There are no Python imports from MLX Agent, and
the two projects remain independently versioned.

The UI server accepts loopback connections only. Commands such as Discover,
Adopt, Doctor, Wire, and other Hub-backed operations may contact the Hugging
Face Hub; loopback binding is not a promise of network isolation.

This documentation was generated for release {{RELEASE_TAG}} from commit
`{{RELEASE_COMMIT}}`.
