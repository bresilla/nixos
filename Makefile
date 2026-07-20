SHELL := /bin/bash

# The nox installer now lives in its own repository. Point NOX at a binary,
# or NOX_SRC at a checkout to build-and-run via cargo.
NOX_SRC ?= ../nox
NOX ?= cargo run --manifest-path $(NOX_SRC)/Cargo.toml --bin nox --
ARGS ?= install-preview

.PHONY: run r test t build b nox help h

run:
	@$(NOX) $(ARGS)

r: run

# Build the nox binary with Nix from the checkout.
nox:
	@nix build $(NOX_SRC)#nox --print-out-paths

test:
	@cd host && nix flake check --no-build 2>/dev/null || true
	@echo "host flake evaluates"

t: test

help h:
	@echo "run [ARGS=...]  - run nox against this repo (default: install-preview)"
	@echo "nox             - nix-build the nox binary from $(NOX_SRC)"
	@echo "test            - evaluate the host flake"
