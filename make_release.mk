# ---------------------------------------------------------------------------
# Release / packaging variables
# ---------------------------------------------------------------------------
_UNAME_S := $(shell uname -s)
_UNAME_M := $(shell uname -m)

# The root Makefile includes this file unconditionally, so this $(error ...)
# fires for *every* `make` invocation on an unrecognised OS — not just when a
# release target actually runs. Git Bash's `uname -s` on Windows reports a
# kernel string like `MINGW64_NT-10.0-26100` (version suffix varies by
# build), so Windows needs a substring match rather than exact `ifeq`.
ifeq ($(_UNAME_S),Darwin)
  RELEASE_OS := macos
else ifeq ($(_UNAME_S),Linux)
  RELEASE_OS := linux
else ifneq (,$(findstring MINGW,$(_UNAME_S)))
  RELEASE_OS := windows
else ifneq (,$(findstring MSYS,$(_UNAME_S)))
  RELEASE_OS := windows
else
  $(error Unsupported OS for release targets: $(_UNAME_S))
endif

ifeq ($(_UNAME_M),arm64)
  RELEASE_ARCH := arm64
else ifeq ($(_UNAME_M),aarch64)
  RELEASE_ARCH := arm64
else
  RELEASE_ARCH := x64
endif

KMDB_CLI_PKG     :=packages/kmdb_cli
RELEASE_PLATFORM := $(RELEASE_OS)-$(RELEASE_ARCH)
# dart build cli uses underscores in its output path (e.g. macos_arm64)
DART_PLATFORM    := $(subst -,_,$(RELEASE_PLATFORM))
RELEASE_VERSION  := $(shell grep '^version:' $(KMDB_CLI_PKG)/pubspec.yaml | awk '{print $$2}')
RELEASE_NAME     := kmdb-$(RELEASE_VERSION)-$(RELEASE_PLATFORM)
CLI_BUNDLE_DIR   := $(KMDB_CLI_PKG)/build/cli/$(DART_PLATFORM)/bundle
DIST_DIR         := dist/cli/$(RELEASE_PLATFORM)
RELEASE_ARCHIVE  := $(DIST_DIR)/$(RELEASE_NAME).tar.gz

## Build the CLI binary with native assets (for local development).
## Binary output: packages/kmdb_cli/build/cli/<platform>/bundle/bin/kmdb
build_cli:
	cd $(KMDB_CLI_PKG) && dart build cli
.PHONY: build_cli

## Build a self-contained CLI archive for the current platform.
## Output: dist/cli/{os}-{arch}/kmdb-{version}-{os}-{arch}.tar.gz
## Requires: git lfs pull (to materialise bge_small.onnx before running)
## The ORT dylib is bundled automatically by dart build cli via the
## betto_onnxrt native-assets hook (lands in bundle/lib/).
release: release_clean
	@echo "==> Checking Git LFS model asset..."
	@size=$$(wc -c < packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx); \
	if [ "$$size" -lt 1000000 ]; then \
	  echo "ERROR: bge_small.onnx is $$size bytes — looks like an LFS pointer stub."; \
	  echo "Run: git lfs pull"; \
	  exit 1; \
	fi
	@echo "==> Building CLI bundle for $(RELEASE_PLATFORM)..."
	cd $(KMDB_CLI_PKG) && dart build cli
	@echo "==> Staging into $(DIST_DIR)/$(RELEASE_NAME)/..."
	mkdir -p $(DIST_DIR)/$(RELEASE_NAME)
	cp -r $(CLI_BUNDLE_DIR)/bin $(DIST_DIR)/$(RELEASE_NAME)/
	cp -r $(CLI_BUNDLE_DIR)/lib $(DIST_DIR)/$(RELEASE_NAME)/
	@echo "==> Copying model assets..."
	mkdir -p $(DIST_DIR)/$(RELEASE_NAME)/bin/assets/models/bge-small-en
	cp -r packages/kmdb_inferencing/assets/models/bge-small-en/. \
	      $(DIST_DIR)/$(RELEASE_NAME)/bin/assets/models/bge-small-en/
	@echo "==> Creating archive $(RELEASE_ARCHIVE)..."
	tar -czf $(RELEASE_ARCHIVE) -C $(DIST_DIR) $(RELEASE_NAME)
	rm -rf $(DIST_DIR)/$(RELEASE_NAME)
	@echo "==> Done: $(RELEASE_ARCHIVE)"
.PHONY: release

## Remove the release archive and intermediate CLI build artifacts.
release_clean:
	rm -rf $(DIST_DIR)
	rm -rf $(KMDB_CLI_PKG)/build
.PHONY: release_clean
