# Installation

## Requirements

- macOS on Apple Silicon
- Git with submodule support
- Python 3.12; `uv` is recommended
- Xcode for source builds
- Storage for source weights, outputs, experiments, and quarantine

## Install the release application

Download the release DMG and drag **MLX Workbench** into **Applications**.
The application still needs a local engine checkout and Python runtime:

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
git checkout {{RELEASE_TAG}}
git submodule update --init --recursive
make install
```

Set **Settings → mlx-agent checkout** to this checkout's
`vendor/mlx-agent`. The distribution app uses the enclosing Workbench
checkout's `.venv`; it contains no build-machine source path.
**Install Runtime…** uses that checkout.

`make install` installs `requirements.txt` and the engine's
`requirements-lab.txt` into a Python 3.12 environment. Optional controlled
study inference uses `requirements-lab-inference.txt` through
**Controlled studies → Install runtime…**. Optional model backends have
separate isolated installation flows. `make pip-audit` audits pinned runtime
dependencies.

## Build from source

After installing the runtime in the tagged checkout:

```bash
make build-swift
make start
```

`make start`, `make run`, and `make open` build and open the native
application. There is no browser URL or background UI service.
