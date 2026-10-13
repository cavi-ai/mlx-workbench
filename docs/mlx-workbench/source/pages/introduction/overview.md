# MLX Workbench overview

MLX Workbench {{PRODUCT_VERSION}} is a native SwiftUI application for the
MLX model lifecycle on Apple Silicon. It inventories local weights, previews
conversions and serving plans, follows jobs, and compares recorded outputs.

The native application invokes the selected MLX Agent `scripts/mlx-agent`
with argv tokens and `--json`. The engine owns execution, the shared
conversion queue, experiments, and training receipts. The Python package
retains configuration and compatibility utilities; the application has no
web server.

Library, Prepare, Run, Compare, Activity, Reclaim, Clients, Discover, Health,
Training, and Settings provide the native workflows. Controlled studies
retain frozen recipes, blind reviews, and durable artifacts separately from
measured comparisons. Speed does not establish output quality.

Serving endpoints bind to loopback, such as `127.0.0.1`. Hugging Face Hub
discovery and downloads can contact the network; loopback binding is
not a promise of network isolation.

These pages describe release {{RELEASE_TAG}} from commit
`{{RELEASE_COMMIT}}`.
