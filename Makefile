# dockma build entry points. `swift build` alone is not enough to run the VM:
# Virtualization.framework requires the com.apple.security.virtualization
# entitlement, so the binary is ad-hoc signed after every build.

CONFIGURATION ?= debug
DOCKER ?= docker
PREFIX ?= $(HOME)/.local
BIN = $(shell swift build -c $(CONFIGURATION) --show-bin-path 2>/dev/null)/dockma
# The state directory `dockma` uses: DOCKMA_HOME, or ~/.dockma.
STATE_DIR = $(or $(DOCKMA_HOME),$(HOME)/.dockma)
GUEST_DIR = $(STATE_DIR)/guest
# make e2e runs its own VM in this state directory, beside the user's.
E2E_HOME ?= $(HOME)/.dockma-e2e
# Extra `docker buildx build` flags for `make guest`; CI passes its build cache.
BUILDX_FLAGS ?=
# DEBUG=1: the debug guest (docs/debugging.md), built into its own directory.
DEBUG ?= 0
GUEST_OUT = $(if $(filter 1,$(DEBUG)),vm/out-debug,vm/out)
# make debug-vm installs the debug guest into this state directory.
DEBUG_HOME ?= $(HOME)/.dockma-debug

.PHONY: build install test guest install-guest debug-vm e2e site site-serve clean

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
	$(DOCKER) buildx build --platform linux/arm64 --build-arg DEBUG=$(DEBUG) $(BUILDX_FLAGS) --output type=local,dest=$(GUEST_OUT) vm

install-guest: $(GUEST_OUT)/dockma-kernel $(GUEST_OUT)/dockma-initrd.img $(GUEST_OUT)/guest-protocol
	mkdir -p $(GUEST_DIR)
	cp $^ $(GUEST_DIR)/
	echo local >$(GUEST_DIR)/origin

# A signed debug build plus the debug guest in DEBUG_HOME; docs/debugging.md.
debug-vm: build
	$(MAKE) guest DEBUG=1
	$(MAKE) install-guest DEBUG=1 DOCKMA_HOME=$(DEBUG_HOME)

# The e2e VM needs a guest: `make install-guest DOCKMA_HOME=$(E2E_HOME)`
# installs a fresh build, or the script copies the one in ~/.dockma/guest.
e2e: build
	DOCKMA=$(BIN) DOCKMA_HOME=$(E2E_HOME) scripts/e2e.sh

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
	rm -rf vm/out vm/out-debug site/public site/resources
