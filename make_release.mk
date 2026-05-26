# ---------------------------------------------------------------------------
# Release / packaging variables
# ---------------------------------------------------------------------------
_UNAME_S := $(shell uname -s)
_UNAME_M := $(shell uname -m)

ORT_VERSION := 1.22.0

ifeq ($(_UNAME_S),Darwin)
  RELEASE_OS   := macos
  ORT_OS       := osx
  ORT_LIB_NAME := libonnxruntime.$(ORT_VERSION).dylib
else ifeq ($(_UNAME_S),Linux)
  RELEASE_OS   := linux
  ORT_OS       := linux
  ORT_LIB_NAME := libonnxruntime.so.$(ORT_VERSION)
else
  $(error Unsupported OS for release targets: $(_UNAME_S))
endif

ifeq ($(_UNAME_M),arm64)
  RELEASE_ARCH := arm64
  ORT_ARCH     := arm64
else ifeq ($(_UNAME_M),aarch64)
  RELEASE_ARCH := arm64
  ORT_ARCH     := arm64
else
  RELEASE_ARCH := x64
  ORT_ARCH     := x64
endif

KMDB_CLI_PKG     :=packages/kmdb_cli
RELEASE_PLATFORM := $(RELEASE_OS)-$(RELEASE_ARCH)
ORT_PLATFORM     := $(ORT_OS)-$(ORT_ARCH)
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

## Download the ONNX Runtime dylib for the current platform into the local
## cache (packages/kmdb_inferencing/assets/native/). No-op if already present.
fetch_ort:
	bash scripts/download_ort.sh $(ORT_VERSION) $(ORT_PLATFORM)
.PHONY: fetch_ort

## Build a self-contained CLI archive for the current platform.
## Output: dist/cli/{os}-{arch}/kmdb-{version}-{os}-{arch}.tar.gz
## Requires: git lfs pull (to materialise bge_small.onnx before running)
release: release_clean fetch_ort
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
	@echo "==> Copying ONNX Runtime from cache..."
	cp packages/kmdb_inferencing/assets/native/$(ORT_PLATFORM)/$(ORT_LIB_NAME) \
	   $(DIST_DIR)/$(RELEASE_NAME)/bin/
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
