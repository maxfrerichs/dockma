# dockma build entry points. `swift build` alone is not enough to run the VM:
# Virtualization.framework requires the com.apple.security.virtualization
# entitlement, so the binary is ad-hoc signed after every build.

CONFIGURATION ?= debug
DOCKER ?= docker
PREFIX ?= $(HOME)/.local
BIN = $(shell swift build -c $(CONFIGURATION) --show-bin-path 2>/dev/null)/dockma
GUEST_DIR := $(HOME)/.dockma/guest

.PHONY: build install test guest install-guest e2e site site-serve clean

build:
	swift build -c $(CONFIGURATION) --product dockma
	codesign --force --sign - --entitlements dockma.entitlements $(BIN)
	@echo "built $(BIN)"

# launchd runs the binary from wherever `dockma start` was invoked, and any
# later `swift build` relinks .build/ unsigned. A stable installed copy
# avoids that.
install: CONFIGURATION = release
install: build
	mkdir -p $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/dockma
	@echo "installed $(PREFIX)/bin/dockma"

# swift test relinks the dockma binary without the entitlement, like swift
# build; re-sign it whether or not the tests pass.
test:
	swift test; status=$$?; codesign --force --sign - --entitlements dockma.entitlements $(BIN); exit $$status

# Builds kernel + initramfs in a Linux container (any arm64 Docker works,
# including dockma itself once it is running).
guest:
	$(DOCKER) buildx build --platform linux/arm64 --output type=local,dest=vm/out vm

install-guest: vm/out/Image vm/out/initramfs.cpio.lz4 vm/out/guest-protocol
	mkdir -p $(GUEST_DIR)
	cp vm/out/Image vm/out/initramfs.cpio.lz4 vm/out/guest-protocol $(GUEST_DIR)/

e2e: build
	DOCKMA=$(BIN) scripts/e2e.sh

# The website: scripts/site-prepare.py derives site/data/facts.json and the
# command reference pages, then Hugo builds site/public.
site:
	python3 -I scripts/site-prepare.py .
	hugo --source site --gc --minify

site-serve:
	python3 -I scripts/site-prepare.py .
	hugo server --source site

clean:
	swift package clean
	rm -rf vm/out site/public site/resources
