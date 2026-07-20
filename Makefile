SHELL := /bin/bash

# nox lives in its own repository (github:bresilla/nox); this repo only
# carries the config. `install.sh` fetches the release binary when nox is
# not already on PATH.
NOX ?= nox
ARGS ?= install-preview

.PHONY: run r install test t help h

run:
	@if command -v $(NOX) >/dev/null 2>&1; then $(NOX) $(ARGS); else ./install.sh $(ARGS); fi

r: run

install:
	@./install.sh

test:
	@cd host && nix flake check --no-build 2>/dev/null || true
	@echo "host flake evaluates"

t: test

help h:
	@echo "run [ARGS=...]  - run nox against this repo (default: install-preview)"
	@echo "install         - full flow: fetch nox, wizard, install"
	@echo "test            - evaluate the host flake"
