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

RUN_DIR := .run
LAUNCHER := scripts/mlx-workbench
# transformers 5 writes nested rope_parameters; mlx-lm 0.31 expects the
# top-level rope_theta key in GGUF→HF intermediates. Pin transformers 4.
# Exact pins live in requirements.txt (versions validated together on
# Apple Silicon); `make install` installs from that file plus the agent's
# lab requirements, which the native app's Training and lab operations import.
LAB_REQUIREMENTS := vendor/mlx-agent/requirements-lab.txt
CONVERT_PKGS := -r requirements.txt -r $(LAB_REQUIREMENTS)
CONVERT_PKGS_LOOSE := torch 'transformers<5' gguf mlx-lm accelerate
DOCS_VERSION := $(shell $(PYTHON) -c 'from mlx_workbench import __version__; print(__version__)')
DOCS_TAG     := v$(DOCS_VERSION)
DOCS_COMMIT  ?= $(shell git rev-parse HEAD)
DOCS_EPOCH   ?= $(shell git show -s --format=%ct $(DOCS_COMMIT))
DOCS_RELEASE_DIR ?= .release

.PHONY: help mac-only install setup agent-bootstrap venv _pkgs install-convert pip-audit _audit_pkgs deps \
	start run test test-live-scan test-swift test-native-ui test-swift-live-scan render-clients render-discover render-lmstudio render-settings accept-native-gguf accept-native-mlx accept-native-training open check check-convert doctor clean clean-venv \
	docs-test docs-build docs-verify docs-release version-bump dmg build-swift-dist build-swift-devid

help:
	@B=''; C=''; D=''; G=''; N=''; \
	if [ -t 1 ] && [ -z "$$NO_COLOR" ]; then \
		B='\033[1m'; C='\033[36m'; D='\033[2m'; G='\033[33m'; N='\033[0m'; \
	fi; \
	hdr() { printf "$${G}%s$${N}\n" "$$1"; }; \
	row() { printf "  $${C}%-24s$${N} $${D}%s$${N}\n" "$$1" "$$2"; }; \
	printf "$${B}%s$${N} $${D}%s$${N}\n" "mlx-workbench" "— macOS Apple Silicon only."; \
	hdr "Setup"; \
	row "make install" "submodule + .venv + torch/transformers/gguf/mlx-lm/accelerate"; \
	row "make check" "verify mlx-agent + .venv"; \
	hdr "Run"; \
	row "make start" "build and open the SwiftUI application"; \
	row "make run" "build and open the SwiftUI application"; \
	hdr "Test"; \
	row "make test" "Python compatibility and contract tests"; \
	row "make test-swift" "unit tests for Swift app"; \
	row "make test-native-ui" "isolated macOS VM UI tests; NATIVE_UI_BASE_VM names a prepared Tart VM"; \
	row "make test-live-scan" "validate live model bytes against configured filesystem paths"; \
	row "make test-swift-live-scan" "validate native app scan bytes against configured filesystem paths"; \
	row "make render-clients" "render the Clients states into an xcresult bundle"; \
	row "make render-discover" "render the Discover states into an xcresult bundle"; \
	row "make render-lmstudio" "render the LM Studio states into an xcresult bundle"; \
	row "make render-settings" "render the Settings states into an xcresult bundle"; \
	row "make accept-native-gguf" "RUNTIME_MANIFEST=/absolute/path/runtime.json — opt-in native GGUF-to-Run acceptance"; \
	row "make accept-native-mlx" "RUNTIME_MANIFEST=/absolute/path/runtime.json — opt-in ready-MLX verification and serving acceptance"; \
	row "make accept-native-training" "RUNTIME_MANIFEST=/absolute/path/runtime.json — opt-in native LoRA training and evaluation acceptance"; \
	row "make pip-audit" "audit .venv convert/serve deps against the OSV DB"; \
	row "make dmg" "build the Release .app and package it as a DMG"; \
	hdr "Docs & release"; \
	row "make docs-test" "release documentation contract tests"; \
	row "make accept-release-candidate" "RELEASE_DMG=/absolute/path/candidate.dmg — validate signed installation and runtime sources"; \
	row "make docs-build" "build deterministic versioned documentation"; \
	row "make docs-verify" "verify the versioned documentation"; \
	row "make docs-release" "create the release archive and checksum"; \
	row "make version-bump" "V=x.y.z — bump version + CHANGELOG everywhere"; \
	hdr "Manage"; \
	row "make clean" "remove .run/"; \
	row "make clean-venv" "remove .venv"

mac-only:
	@sys=$$(uname -s); arch=$$(uname -m); \
	if [ "$$sys" != "Darwin" ] || [ "$$arch" != "arm64" ]; then \
		echo "mlx-workbench targets Apple Silicon Macs only (got $$sys/$$arch)." >&2; \
		exit 1; \
	fi

install setup: mac-only agent-bootstrap
	@$(MAKE) --no-print-directory venv
	@$(MAKE) --no-print-directory _pkgs
	@$(MAKE) --no-print-directory check
	@$(MAKE) --no-print-directory check-convert
	@echo ""
	@echo "Install complete. Next:  make start"

agent-bootstrap:
	@agent_path="$$($(PYTHON) -c 'from mlx_workbench import config; print(config.load()["mlx_agent_path"])')"; \
	if [ -n "$$agent_path" ] && [ -f "$$agent_path/scripts/mlx-agent" ]; then \
		echo "mlx-agent already configured: $$agent_path"; \
	elif [ -n "$$agent_path" ]; then \
		echo "configured mlx_agent_path has no scripts/mlx-agent: $$agent_path" >&2; \
		exit 1; \
	else \
		git submodule update --init --recursive; \
	fi

venv: mac-only
	@set -e; \
	if [ -x "$(VENV_PY)" ]; then \
		echo "venv OK: $$($(VENV_PY) -c 'import sys; print(sys.executable + " (" + sys.version.split()[0] + ")")')"; \
	else \
		echo "Creating $(VENV) with Python $(VENV_PYTHON) (Apple Silicon)…"; \
		if command -v uv >/dev/null 2>&1; then \
			uv venv "$(VENV)" --python "$(VENV_PYTHON)"; \
		elif command -v python$(VENV_PYTHON) >/dev/null 2>&1; then \
			python$(VENV_PYTHON) -m venv "$(VENV)"; \
		else \
			echo "Need Python $(VENV_PYTHON) on this Mac." >&2; \
			echo "  brew install python@$(VENV_PYTHON)" >&2; \
			echo "  # or: uv python install $(VENV_PYTHON)" >&2; \
			exit 1; \
		fi; \
		echo "venv created: $$($(VENV_PY) -c 'import sys; print(sys.executable)')"; \
	fi

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

BACKEND_LOCKS := $(wildcard vendor/mlx-agent/src/mlx_agent/resources/backends/*.lock)
PIP_AUDIT_PIN := $(shell grep -E '^pip-audit==' requirements.txt)
PIP_AUDIT_VERSION := $(patsubst pip-audit==%,%,$(PIP_AUDIT_PIN))

pip-audit: venv
	@command -v uv >/dev/null 2>&1 && echo "uv found; using uv pip install" || true
	@if [ "$$("$(VENV_PY)" -m pip_audit --version 2>/dev/null)" != "pip-audit $(PIP_AUDIT_VERSION)" ]; then \
		$(MAKE) --no-print-directory _audit_pkgs; \
	fi
	@"$(VENV_PY)" -m pip_audit --version
	@"$(VENV_PY)" -m pip_audit --no-deps -r requirements.txt -r $(LAB_REQUIREMENTS) --progress-spinner off \
		$(PIP_AUDIT_IGNORES)
	@status=0; for lock in $(BACKEND_LOCKS); do \
		echo "pip-audit $$lock"; \
		"$(VENV_PY)" -m pip_audit --no-deps --disable-pip --require-hashes -r "$$lock" --progress-spinner off || status=1; \
	done; exit $$status

# Accepted risk: the transformers 4.x pin is required by mlx-lm's GGUF→HF
# path (transformers 5 writes incompatible rope keys). These advisories have
# no 4.x fix; drop the ignores and re-run `make pip-audit` when the pin moves.
PIP_AUDIT_IGNORES := --ignore-vuln PYSEC-2025-217 --ignore-vuln PYSEC-2026-2290 \
	--ignore-vuln PYSEC-2026-2288 --ignore-vuln PYSEC-2026-2289 \
	--ignore-vuln PYSEC-2026-3929 --ignore-vuln PYSEC-2026-4174

_audit_pkgs:
	@if command -v uv >/dev/null 2>&1; then \
		uv pip install --python "$(VENV_PY)" "$(PIP_AUDIT_PIN)"; \
	else \
		"$(VENV_PY)" -m pip install "$(PIP_AUDIT_PIN)"; \
	fi

check: mac-only
	@agent_path="$$($(PYTHON) -c 'from mlx_workbench import config; print(config.load()["mlx_agent_path"])')"; \
	if [ -z "$$agent_path" ] || [ ! -f "$$agent_path/scripts/mlx-agent" ]; then \
		echo "mlx-agent CLI missing at configured mlx_agent_path. Run: make install, or set mlx_agent_path / MLX_AGENT_HOME." >&2; \
		exit 1; \
	fi; \
	echo "mlx-agent OK: $$agent_path ($$(cd "$$agent_path" && git describe --tags --always 2>/dev/null || echo external))"
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

start run open: run-swift

test:
	$(PYTHON) -m unittest discover -s tests -t .

.PHONY: install-strata
install-strata: mac-only
	$(PYTHON) scripts/install-strata.py

test-live-scan:
	MLX_WORKBENCH_LIVE_SCAN=1 $(PYTHON) -m unittest tests.test_live_scan_e2e -v

test-swift:
	@xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) test

test-native-ui:
	@test -n "$(NATIVE_UI_BASE_VM)" || { echo "NATIVE_UI_BASE_VM must name a prepared local Tart VM" >&2; exit 2; }
	@$(PYTHON) scripts/native_ui_vm.py --base-vm "$(NATIVE_UI_BASE_VM)"

.PHONY: accept-release-candidate
accept-release-candidate: mac-only
	@test -n "$(RELEASE_DMG)" || { echo "RELEASE_DMG must be an absolute path to a signed candidate DMG" >&2; exit 2; }
	@$(PYTHON) scripts/release_candidate.py --dmg "$(RELEASE_DMG)" --derived-data "$(MLX_SWIFT_DD)"

test-swift-live-scan:
	@xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) \
		OTHER_SWIFT_FLAGS='$(OTHER_SWIFT_FLAGS) -DMLX_WORKBENCH_LIVE_SCAN' test

CLIENTS_RENDER_BUNDLE ?= $(RUN_DIR)/clients-render-$(shell git rev-parse --short HEAD).xcresult

render-clients:
	@TEST_RUNNER_MLX_WORKBENCH_RENDERS=1 xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) \
		-only-testing:mlx-workbenchTests/ClientsRenderTests \
		-resultBundlePath $(CLIENTS_RENDER_BUNDLE) test

DISCOVER_RENDER_BUNDLE ?= $(RUN_DIR)/discover-render-$(shell git rev-parse --short HEAD).xcresult

render-discover:
	@TEST_RUNNER_MLX_WORKBENCH_RENDERS=1 xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) \
		-only-testing:mlx-workbenchTests/DiscoverRenderTests \
		-resultBundlePath $(DISCOVER_RENDER_BUNDLE) test

LMSTUDIO_RENDER_BUNDLE ?= $(RUN_DIR)/lmstudio-render-$(shell git rev-parse --short HEAD).xcresult

render-lmstudio:
	@TEST_RUNNER_MLX_WORKBENCH_RENDERS=1 xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) \
		-only-testing:mlx-workbenchTests/LMStudioRenderTests \
		-resultBundlePath $(LMSTUDIO_RENDER_BUNDLE) test

SETTINGS_RENDER_BUNDLE ?= $(RUN_DIR)/settings-render-$(shell git rev-parse --short HEAD).xcresult

render-settings:
	@TEST_RUNNER_MLX_WORKBENCH_RENDERS=1 xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(MLX_SWIFT_DD) \
		-only-testing:mlx-workbenchTests/SettingsRenderTests \
		-resultBundlePath $(SETTINGS_RENDER_BUNDLE) test

accept-native-gguf accept-native-mlx accept-native-training:
	@case "$(RUNTIME_MANIFEST)" in \
		/*) ;; \
		*) echo "RUNTIME_MANIFEST is required and must be an absolute path" >&2; exit 2 ;; \
	esac
	@$(PYTHON) scripts/native_gguf_acceptance.py --manifest "$(RUNTIME_MANIFEST)" --source-format $(if $(filter accept-native-mlx accept-native-training,$@),mlx,gguf) $(if $(filter accept-native-training,$@),--workflow training,)

docs-test:
	$(PYTHON) -m unittest tests.test_release_docs -v

docs-build:
	node scripts/docs/build.mjs --version "$(DOCS_VERSION)" --tag "$(DOCS_TAG)" --commit "$(DOCS_COMMIT)" --source-date-epoch "$(DOCS_EPOCH)"

docs-verify:
	node scripts/docs/verify.mjs --version "$(DOCS_VERSION)" --tag "$(DOCS_TAG)" --commit "$(DOCS_COMMIT)" --source-date-epoch "$(DOCS_EPOCH)"

docs-release: docs-build docs-verify
	node scripts/docs/release-artifact.mjs --docs-root "docs/mlx-workbench/v$(DOCS_VERSION)" --output "$(DOCS_RELEASE_DIR)" --version "$(DOCS_VERSION)" --tag "$(DOCS_TAG)" --repository "cavi-ai/mlx-workbench" --commit "$(DOCS_COMMIT)" --source-date-epoch "$(DOCS_EPOCH)"

version-bump:
	@case "$(V)" in \
		[0-9]*.[0-9]*.[0-9]*) ;; \
		*) echo "V is required and must be semver: make version-bump V=x.y.z" >&2; exit 2 ;; \
	esac
	@$(PYTHON) scripts/version_bump.py "$(V)"



doctor: check
	@$(MAKE) --no-print-directory check-convert || true

clean:
	rm -rf $(RUN_DIR)

clean-venv:
	rm -rf $(VENV)

# Swift build targets (mlx-mac sibling project)

MLX_SWIFT_DD ?= $(RUN_DIR)/swift-build
MLX_SWIFT_APP = $(MLX_SWIFT_DD)/Build/Products/Release/mlx-workbench.app

build-swift:
	@echo "Building mlx-workbench (Swift)..."
	@xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Release -arch arm64 \
		-derivedDataPath $(MLX_SWIFT_DD) build

# Distribution build for the DMG: compiled without the source path, so the
# installed app finds its checkout through the configured agent path.
MLX_DIST_DD ?= $(MLX_SWIFT_DD)-dist
MLX_DIST_APP = $(MLX_DIST_DD)/Build/Products/Release/mlx-workbench.app
# Build identity the in-app updater compares against releases (Info.plist).
DIST_COMMIT   ?= $(shell git rev-parse --short=12 HEAD)
DMG_CHANNEL   ?= release
DIST_IDENTITY  = MLX_WORKBENCH_COMMIT=$(DIST_COMMIT) MLX_WORKBENCH_CHANNEL=$(DMG_CHANNEL)

RUNTIME_BUNDLE_ROOT ?= $(abspath $(RUN_DIR)/bundled-runtime)
RUNTIME_BUNDLE_SETTINGS = MLX_WORKBENCH_RUNTIME_BUNDLE_ROOT="$(RUNTIME_BUNDLE_ROOT)" MLX_WORKBENCH_RUNTIME_INPUTS="$(RUNTIME_BUNDLE_ROOT)/inputs.xcfilelist"

.PHONY: prepare-runtime-bundle
prepare-runtime-bundle:
	@$(PYTHON) scripts/runtime_bundle.py create --repo . --output "$(RUNTIME_BUNDLE_ROOT)"

build-swift-dist: prepare-runtime-bundle
	@echo "Building mlx-workbench (Swift, distribution)..."
	@xcodebuild -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Release -arch arm64 \
		-derivedDataPath $(MLX_DIST_DD) $(DIST_IDENTITY) $(RUNTIME_BUNDLE_SETTINGS) \
		OTHER_SWIFT_FLAGS='$$(inherited) -DMLX_WORKBENCH_DISTRIBUTION' build

# Developer ID build for the DMG: Xcode archives the distribution build,
# exports it with the team's Developer ID certificate (cloud-managed or local),
# notarizes it through the signed-in Xcode account, and staples the ticket.
# CI passes an App Store Connect API key (ASC_KEY_PATH/ID, ASC_ISSUER_ID)
# instead of a signed-in account.
DEVELOPER_TEAM ?=
NOTARY_ATTEMPTS ?= 40
MLX_DIST_ARCHIVE   = $(MLX_DIST_DD)/mlx-workbench.xcarchive
MLX_DIST_NOTARIZED = $(MLX_DIST_DD)/notarized/mlx-workbench.app
ASC_KEY_PATH  ?=
ASC_KEY_ID    ?=
ASC_ISSUER_ID ?=
XCODE_AUTH = $(if $(ASC_KEY_PATH),-authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID "$(ASC_KEY_ID)" -authenticationKeyIssuerID "$(ASC_ISSUER_ID)")

build-swift-devid: prepare-runtime-bundle
	@if [ -z "$(DEVELOPER_TEAM)" ]; then echo "DEVELOPER_TEAM is required" >&2; exit 2; fi
	@case "$(DMG_CHANNEL)" in release|nightly) ;; *) echo "DMG_CHANNEL must be release or nightly" >&2; exit 2 ;; esac
	@rm -rf "$(MLX_DIST_ARCHIVE)" "$(MLX_DIST_DD)/upload" "$(MLX_DIST_DD)/notarized"
	@mkdir -p "$(MLX_DIST_DD)"
	@plutil -create xml1 "$(MLX_DIST_DD)/ExportOptions.plist"
	@plutil -insert method -string developer-id "$(MLX_DIST_DD)/ExportOptions.plist"
	@plutil -insert signingStyle -string automatic "$(MLX_DIST_DD)/ExportOptions.plist"
	@plutil -insert teamID -string "$(DEVELOPER_TEAM)" "$(MLX_DIST_DD)/ExportOptions.plist"
	@plutil -insert destination -string upload "$(MLX_DIST_DD)/ExportOptions.plist"
	@echo "Archiving mlx-workbench (Swift, Developer ID)..."
	@xcodebuild archive -project mlx-mac/mlx-mac.xcodeproj -scheme mlx-workbench \
		-configuration Release -destination 'generic/platform=macOS' ARCHS=arm64 \
		-archivePath "$(MLX_DIST_ARCHIVE)" -derivedDataPath $(MLX_DIST_DD) \
		DEVELOPMENT_TEAM=$(DEVELOPER_TEAM) CODE_SIGN_STYLE=Automatic $(DIST_IDENTITY) $(RUNTIME_BUNDLE_SETTINGS) \
		OTHER_SWIFT_FLAGS='$$(inherited) -DMLX_WORKBENCH_DISTRIBUTION' \
		-allowProvisioningUpdates $(XCODE_AUTH)
	@xcodebuild -exportArchive -archivePath "$(MLX_DIST_ARCHIVE)" \
		-exportOptionsPlist "$(MLX_DIST_DD)/ExportOptions.plist" \
		-exportPath "$(MLX_DIST_DD)/upload" -allowProvisioningUpdates $(XCODE_AUTH)
	@for i in $$(seq 1 $(NOTARY_ATTEMPTS)); do \
		if xcodebuild -exportNotarizedApp -archivePath "$(MLX_DIST_ARCHIVE)" \
			-exportPath "$(MLX_DIST_DD)/notarized" $(XCODE_AUTH) > /dev/null 2>&1; then \
			xcrun stapler validate "$(MLX_DIST_NOTARIZED)" && exit 0; \
			exit 1; \
		fi; \
		sleep 30; \
	done; \
	echo "not notarized after $(NOTARY_ATTEMPTS) attempts" >&2; \
	exit 1

# Package the distribution app into a DMG: ad-hoc signed by default, or the
# notarized Developer ID export with DEVELOPER_TEAM=<team id>.
DMG_DIR       := .release
DMG_VOLUME    := MLX Workbench
DMG_APP       := MLX Workbench.app
DMG_RELEASE_NAME := mlx-workbench-$(shell $(PYTHON) -c 'from mlx_workbench import __version__; print(__version__)')
DMG_OUTPUT     = $(DMG_DIR)/$(if $(filter nightly,$(DMG_CHANNEL)),mlx-workbench-nightly-$(DIST_COMMIT),$(DMG_RELEASE_NAME)).dmg

dmg: $(if $(DEVELOPER_TEAM),build-swift-devid,build-swift-dist)
	@mkdir -p $(DMG_DIR)
	@rm -rf "$(DMG_DIR)/stage" && mkdir -p "$(DMG_DIR)/stage"
	@if [ -n "$(DEVELOPER_TEAM)" ]; then \
		ditto "$(MLX_DIST_NOTARIZED)" "$(DMG_DIR)/stage/$(DMG_APP)"; \
	else \
		ditto "$(MLX_DIST_APP)" "$(DMG_DIR)/stage/$(DMG_APP)" && \
		codesign --force --deep --sign - "$(DMG_DIR)/stage/$(DMG_APP)"; \
	fi
	@ln -s /Applications "$(DMG_DIR)/stage/Applications"
	@hdiutil create -volname "$(DMG_VOLUME)" \
		-srcfolder "$(DMG_DIR)/stage" \
		-format UDZO -ov -fs HFS+J \
		"$(DMG_OUTPUT)"
	@rm -rf "$(DMG_DIR)/stage"
	@echo "DMG ready: $(DMG_OUTPUT)"

run-swift: build-swift
	@open $(MLX_SWIFT_APP)

clean-swift:
	@rm -rf $(MLX_SWIFT_DD)

# Users can run: make build-swift && make run-swift
# Existing targets (make start, make run, make test) continue to work
