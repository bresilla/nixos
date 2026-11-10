SHELL := /bin/sh
REFERENCE_REV ?= b3358a3cf3a75a917dece1d62e826d0455cca680
ROOT := $(abspath ../../../..)
ARTIFACTS := $(CURDIR)/artifacts
HIVE ?= hive.netbird
HIVE_ROOT ?= /home/bresilla/shared-ui

.PHONY: build reference unit browser behavior check capture public-check live-check hive-stage hive-build hive-assets hive-template-check

build:
	nix-build tests/package.nix --out-link result

reference:
	mkdir -p $(ARTIFACTS)/reference
	git -C $(ROOT) archive $(REFERENCE_REV) shared/services/server configs/assets/bresilla.svg | tar -x -C $(ARTIFACTS)/reference

unit: build reference
	nix-shell tests/shell.nix --run 'PYTHONPATH=$(CURDIR)/result SITE_REFERENCE=$(ARTIFACTS)/reference python tests/test_ui.py'

browser: unit
	nix-shell tests/shell.nix --run 'SITE_UI=$(CURDIR)/result SITE_REFERENCE=$(ARTIFACTS)/reference node tests/browser.cjs'

behavior: unit
	nix-shell tests/shell.nix --run 'node tests/behavior.cjs'

check: browser behavior

capture:
	nix-shell tests/shell.nix --run 'node tests/public.cjs capture'

public-check: unit
	nix-shell tests/shell.nix --run 'SITE_UI=$(CURDIR)/result node tests/public.cjs compare'

live-check:
	nix-shell tests/shell.nix --run 'node tests/live.cjs'

hive-stage:
	ssh $(HIVE) 'test -f $(HIVE_ROOT)/candidate/flake.lock'
	set -e; for service in cache ci gitea id ui; do rsync -a --delete --exclude artifacts --exclude result --exclude 'result-*' --exclude __pycache__ ../$$service $(HIVE):$(HIVE_ROOT)/candidate/shared/services/server/; done

hive-build: hive-stage
	ssh $(HIVE) 'nix build path:$(HIVE_ROOT)/candidate\#nixosConfigurations.minisforum-hm90.config.system.build.toplevel --no-update-lock-file --no-write-lock-file --out-link $(HIVE_ROOT)/result --print-out-paths'

hive-assets: hive-template-check
	mkdir -p $(ARTIFACTS)/generated/id $(ARTIFACTS)/generated/gitea
	ssh $(HIVE) 'nix-store -qR $(HIVE_ROOT)/result | grep -- "-id-theme$$"' > $(ARTIFACTS)/generated/id-path
	ssh $(HIVE) 'nix-store -qR $(HIVE_ROOT)/result | grep -- "-gitea-custom$$"' > $(ARTIFACTS)/generated/gitea-path
	rsync -a $(HIVE):$$(cat $(ARTIFACTS)/generated/id-path)/ $(ARTIFACTS)/generated/id/
	rsync -a $(HIVE):$$(cat $(ARTIFACTS)/generated/gitea-path)/templates/custom/header.tmpl $(ARTIFACTS)/generated/gitea/
	ssh $(HIVE) 'cat $(HIVE_ROOT)/gitea-fixture-latest' > $(ARTIFACTS)/generated/gitea-fixture-path
	rsync -a $(HIVE):$$(cat $(ARTIFACTS)/generated/gitea-fixture-path)/explore-repos.html $(ARTIFACTS)/generated/gitea/page.html
	nix-shell tests/shell.nix --run 'node --check artifacts/generated/id/style.js'

hive-template-check:
	ssh $(HIVE) 'bash -s -- "$$(nix-store -qR $(HIVE_ROOT)/result | grep -E -- "-gitea-[0-9.]+$$")/bin/gitea" "$$(nix-store -qR $(HIVE_ROOT)/result | grep -- "-gitea-custom$$")" $(HIVE_ROOT)' < tests/gitea-fixture.sh
