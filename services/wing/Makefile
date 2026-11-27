SHELL := /bin/sh

.PHONY: check run

# The shared page package, as the container gets it.
ui:
	nix-build -E 'import ../ui { pkgs = import <nixpkgs> {}; }' --out-link ui

check: ui
	PYTHONPATH=$(CURDIR)/ui python3 -W error::ResourceWarning test_wing.py

# The page on 127.0.0.1:8098 with a scratch database; git and build are the live ones.
run: ui
	WING_DATABASE=$${WING_DATABASE:-$$(mktemp -d)/wing.db} PYTHONPATH=$(CURDIR)/ui python3 wing.py
