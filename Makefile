# mlx-workbench — macOS Apple Silicon only
#
#   make install   → submodule + .venv (Python 3.12) + convert/serve packages
#   make start     → run the UI

SHELL := /bin/bash

VENV     := .venv
VENV_PY  := $(VENV)/bin/python
PYTHON   := $(shell if [ -x "$(VENV_PY)" ]; then echo "$(VENV_PY)"; else echo python3; fi)

# Homebrew python3 is often 3.14; torch needs 3.12 on Mac right now.
VENV_PYTHON ?= 3.12

HOST     ?= 127.0.0.1
PORT     ?= 8765
RUN_DIR  := .run
PID_FILE := $(RUN_DIR)/mlx-workbench.pid
LOG_FILE := $(RUN_DIR)/mlx-workbench.log
LAUNCHER := scripts/mlx-workbench
URL      := http://$(HOST):$(PORT)/
CONVERT_PKGS := torch transformers gguf mlx-lm

.PHONY: help mac-only install setup venv _pkgs install-convert deps \
	start stop restart status run test test-swift open check check-convert doctor clean clean-venv

help:
	@printf '%s\n' \
		'macOS Apple Silicon only.' \
		'' \
		'make install  - submodule + .venv + torch/transformers/gguf/mlx-lm' \
		'make start    - background UI' \
		'make stop     - stop background UI' \
		'make restart  - stop then start' \
		'make status   - running?' \
		'make run      - foreground UI' \
		'make test     - unittest suite' \
		'make test-swift - unit tests for Swift app' \
		'make open     - open $(URL)' \
		'make check    - verify mlx-agent + .venv' \
		'make clean    - remove .run/' \
		'make clean-venv - remove .venv'

mac-only:
	@sys=$$(uname -s); arch=$$(uname -m); \
	if [ "$$sys" != "Darwin" ] || [ "$$arch" != "arm64" ]; then \
		echo "mlx-workbench targets Apple Silicon Macs only (got $$sys/$$arch)." >&2; \
		exit 1; \
	fi

install setup: mac-only
	git submodule update --init --recursive
	@$(MAKE) --no-print-directory venv
	@$(MAKE) --no-print-directory _pkgs
	@$(MAKE) --no-print-directory check
	@$(MAKE) --no-print-directory check-convert
	@echo ""
	@echo "Install complete. Next:  make start"

venv: mac-only
	@if [ -x "$(VENV_PY)" ]; then \
		echo "venv OK: $$($(VENV_PY) -c 'import sys; print(sys.executable + \" (\" + sys.version.split()[0] + \")\")')"; \
		exit 0; \
	fi
	@echo "Creating $(VENV) with Python $(VENV_PYTHON) (Apple Silicon)…"
	@if command -v uv >/dev/null 2>&1; then \
		uv venv "$(VENV)" --python "$(VENV_PYTHON)"; \
	elif command -v python$(VENV_PYTHON) >/dev/null 2>&1; then \
		python$(VENV_PYTHON) -m venv "$(VENV)"; \
	else \
		echo "Need Python $(VENV_PYTHON) on this Mac." >&2; \
		echo "  brew install python@$(VENV_PYTHON)" >&2; \
		echo "  # or: uv python install $(VENV_PYTHON)" >&2; \
		exit 1; \
	fi
	@echo "venv created: $$($(VENV_PY) -c 'import sys; print(sys.executable)')"

_pkgs:
	@echo "Installing into $$($(VENV_PY) -c 'import sys; print(sys.executable)')"
	@echo "Packages: $(CONVERT_PKGS)"
	@if command -v uv >/dev/null 2>&1; then \
		uv pip install --python "$(VENV_PY)" $(CONVERT_PKGS); \
	else \
		"$(VENV_PY)" -m pip install --upgrade pip; \
		"$(VENV_PY)" -m pip install $(CONVERT_PKGS); \
	fi

install-convert deps: mac-only venv
	@$(MAKE) --no-print-directory _pkgs
	@$(MAKE) --no-print-directory check-convert

check: mac-only
	@if [ ! -f vendor/mlx-agent/scripts/mlx-agent ]; then \
		echo "mlx-agent CLI missing. Run: make install" >&2; \
		exit 1; \
	fi
	@echo "mlx-agent OK: vendor/mlx-agent ($$(cd vendor/mlx-agent && git describe --tags --always 2>/dev/null || echo unknown))"
	@if [ ! -x "$(VENV_PY)" ]; then \
		echo "No .venv yet. Run: make install" >&2; \
	else \
		echo "python: $$($(VENV_PY) -c 'import sys; print(sys.version.split()[0])')  ($$($(VENV_PY) -c 'import sys; print(sys.executable)'))"; \
	fi

check-convert: mac-only
	@if [ ! -x "$(VENV_PY)" ]; then \
		echo "No .venv. Run: make install" >&2; \
		exit 1; \
	fi
	@"$(VENV_PY)" -c "from mlx_workbench import deps; r=deps.runtime_report(); print(r['convert']['message']); print(r['serve']['message']); raise SystemExit(0 if r['convert']['ok'] else 1)"

start: check
	@mkdir -p $(RUN_DIR); \
	if [ -f $(PID_FILE) ] && kill -0 $$(tr -d '[:space:]' < $(PID_FILE)) 2>/dev/null; then \
		echo "already running (pid $$(tr -d '[:space:]' < $(PID_FILE))) → $(URL)"; \
		exit 0; \
	fi; \
	rm -f $(PID_FILE); \
	$(PYTHON) $(LAUNCHER) --host $(HOST) --port $(PORT) --no-open --pid-file $(PID_FILE) \
		>> $(LOG_FILE) 2>&1 & \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		if [ -f $(PID_FILE) ] && kill -0 $$(tr -d '[:space:]' < $(PID_FILE)) 2>/dev/null; then \
			echo "mlx-workbench started (pid $$(tr -d '[:space:]' < $(PID_FILE))) → $(URL)"; \
			echo "log: $(LOG_FILE)"; \
			exit 0; \
		fi; \
		sleep 0.2; \
	done; \
	echo "failed to start; see $(LOG_FILE)" >&2; \
	tail -n 40 $(LOG_FILE) >&2 || true; \
	exit 1

stop:
	@stopped=0; \
	if [ -f $(PID_FILE) ]; then \
		pid=$$(tr -d '[:space:]' < $(PID_FILE)); \
		if [ -z "$$pid" ]; then \
			echo "stale empty pid file; removing"; \
		elif kill -0 $$pid 2>/dev/null; then \
			kill $$pid; \
			for i in 1 2 3 4 5 6 7 8 9 10; do \
				kill -0 $$pid 2>/dev/null || break; \
				sleep 0.2; \
			done; \
			if kill -0 $$pid 2>/dev/null; then \
				kill -9 $$pid 2>/dev/null || true; \
			fi; \
			echo "stopped pid $$pid"; \
			stopped=1; \
		else \
			echo "stale pid file ($$pid); removing"; \
		fi; \
		rm -f $(PID_FILE); \
	fi; \
	listeners=$$(lsof -nP -t -iTCP:$(PORT) -sTCP:LISTEN 2>/dev/null || true); \
	if [ -n "$$listeners" ]; then \
		echo "refusing to stop unowned listener(s) on :$(PORT): $$listeners" >&2; \
		exit 1; \
	fi; \
	if [ "$$stopped" -eq 0 ]; then \
		echo "not running"; \
	fi

restart: stop start

status:
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "running (pid $$(cat $(PID_FILE))) → $(URL)"; \
	else \
		echo "not running"; \
		[ -f $(PID_FILE) ] && echo "stale pid file: $(PID_FILE)"; \
		exit 1; \
	fi

run: check
	$(PYTHON) $(LAUNCHER) --host $(HOST) --port $(PORT)

test:
	$(PYTHON) -m unittest discover -s tests -t .

test-swift:
	@xcodebuild -project mlx-mac/mlx-mac.xcodeproj -target mlx-workbenchTests \
		-configuration Debug -arch arm64 -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) test

open:
	@$(PYTHON) -c "import webbrowser; webbrowser.open('$(URL)')"
	@echo $(URL)

doctor: check
	@$(MAKE) --no-print-directory check-convert || true

clean:
	rm -rf $(RUN_DIR)

clean-venv:
	rm -rf $(VENV)

# Swift build targets (mlx-mac sibling project)

MLX_SWIFT_DD ?= /tmp/mlx-mac-build
MLX_SWIFT_APP = $(MLX_SWIFT_DD)/Build/Products/Release/mlx-workbench.app

build-swift:
	@echo "Building mlx-workbench (Swift)..."
	@xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Release -arch arm64 \
		-derivedDataPath $(MLX_SWIFT_DD) build

run-swift: build-swift
	@open $(MLX_SWIFT_APP)

clean-swift:
	@rm -rf $(MLX_SWIFT_DD)

# Users can run: make build-swift && make run-swift
# Existing targets (make start, make run, make test) continue to work
