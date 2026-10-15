# mlx-workbench Documentation Consumer Contract

This contract describes how a documentation host consumes the immutable
documentation artifact built for an mlx-workbench release.

```text
source: GitHub Release asset mlx-workbench-docs-v<version>.tar.gz
checksum: GitHub Release asset mlx-workbench-docs-v<version>.tar.gz.sha256
publicBasePath: /docs/mlx-workbench/v<version>
stableAlias: /docs/mlx-workbench
entrypoints: manifest.json, navigation.json
identity: manifest.package / manifest.product
contentIntegrity: manifest.contentSha256
releaseIntegrity: envelope.artifact.sha256
releaseProvenance: manifest.release.tag / manifest.release.commit
```

## Archive layout

```text
cavi-release.json
docs/mlx-workbench/v<version>/manifest.json
docs/mlx-workbench/v<version>/navigation.json
docs/mlx-workbench/v<version>/<section>/<page>.md
```

`cavi-release.json` carries the slug `mlx-workbench`, the repository
`cavi-ai/mlx-workbench`, the version, tag and full release commit.

## Copy and install

Validate the schema-v1 `cavi-oss-release` envelope and the archive SHA-256,
then extract the complete `docs/mlx-workbench/v<version>/` directory to the
host's `/docs/mlx-workbench/v<version>` public base path. Serve
`/docs/mlx-workbench` as an alias to that version only after validation
succeeds. Do not merge files from another version into this directory.

Use `manifest.json` to validate the artifact and `navigation.json` as the
navigation entry point. Page paths in `navigation.json` are relative to the
version directory.

## Integrity and immutability

The manifest version must equal the documented version, and
`manifest.package` / `manifest.product` must be `mlx-workbench`.

Verify `manifest.contentSha256` by hashing every artifact file except
`manifest.json`, in lexical path order, as `path`, NUL, bytes, NUL.

Consumers must fail ingestion on a version, tag, commit, repository or digest
mismatch. Consumers must not edit generated pages; replace the complete
versioned directory with a newly validated artifact when upgrading.

## Build and verify in this repository

```bash
make docs-test
make docs-build
make docs-verify
make docs-release
```

Published releases require `CONSUMER_DISPATCH_TOKEN` and dispatch the
verified artifact envelope to cavi-home. `make docs-release` builds the same
archive locally and never uploads or dispatches.
