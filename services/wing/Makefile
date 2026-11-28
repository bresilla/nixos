SHELL := /bin/sh

.PHONY: check run ui py

# The shared page package, and the Python with markdown and pygments, as the container gets them.
ui:
	nix-build -E 'import ../ui { pkgs = import <nixpkgs> {}; }' --out-link ui

py:
	nix-build -E 'with import <nixpkgs> {}; python3.withPackages (p: [ p.markdown p.pygments p.pyyaml ])' --out-link py

check: ui py
	PYTHONPATH=$(CURDIR)/ui py/bin/python3 -W error::ResourceWarning test_wing.py

# The page on 127.0.0.1:8098 with a scratch database; git and build are the live ones.
run: ui py
	WING_DATABASE=$${WING_DATABASE:-$$(mktemp -d)/wing.db} PYTHONPATH=$(CURDIR)/ui py/bin/python3 wing.py
