# Installation

## Requirements

- macOS on Apple Silicon
- Git with submodule support
- Python 3.12; `uv` is recommended, and Homebrew Python 3.12 is supported
- Enough local storage for source weights, converted models, and quarantine

Clone the pinned MLX Agent submodule and install the project environment:

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
make install
```

`make install` verifies the platform, initializes `vendor/mlx-agent`, creates
`.venv`, and installs the conversion and serving packages from the pinned
`requirements.txt`. The UI server itself uses only the Python standard
library. Re-run the target after changing the pinned submodule or local
environment. `make pip-audit` checks the installed packages against the OSV
vulnerability database.

If the submodule was omitted during clone, recover it with:

```bash
git submodule update --init --recursive
make install
```
