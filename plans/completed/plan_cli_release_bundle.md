# CLI Release Bundle

**Status**: Complete

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

The `kmdb` CLI (`packages/kmdb_cli`) cannot be distributed to end-users as a
single executable because it has two native dependencies that are not produced
or staged by `dart compile exe`:

1. **`libzstd.dylib`** — the `kmdb_zstd` package has a `hook/build.dart` that
   compiles `libzstd.dylib` from C source via the native-assets pipeline. Only
   `dart build cli` (a Dart preview command) triggers this hook; `dart compile
   exe` does not. Without it the dylib is never produced and the process crashes
   on launch with a missing-library error.

2. **ONNX Runtime dylib + model assets** — `kmdb_inferencing` has no build
   hook. It resolves paths relative to the compiled executable at runtime:
   - Model files are expected at `<executableDir>/assets/models/bge-small-en/`
   - The ORT shared library (`libonnxruntime.1.22.0.dylib` on macOS) is
     downloaded from GitHub on first use if not already present in
     `<executableDir>/`. This is unacceptable for a distribution build — users
     must not need a network connection to run the CLI.
   - Model assets (`*.onnx` and companion files) are tracked with Git LFS and
     must be pulled explicitly before a release build.

3. **`dart compile exe` does not work** for distribution — it produces a single
   binary without triggering native asset hooks, so `libzstd.dylib` is never
   produced and the binary crashes at runtime. `dart run` and `dart build cli`
   both trigger the native-assets pipeline correctly and work for local
   development.

The goal is a `make release` target that assembles a fully self-contained,
offline-capable CLI and packages it as a single `.tar.gz` archive requiring no
further downloads at runtime. Output:

```
dist/cli/{os}-{arch}/
  kmdb-{version}-{os}-{arch}.tar.gz   ← single distributable download
```

When extracted the archive produces:

```
kmdb-{version}-{os}-{arch}/
  bin/
    kmdb
    libonnxruntime.1.22.0.dylib    ← pre-staged; no runtime download needed
    assets/
      models/
        bge-small-en/
          bge_small.onnx
          vocab.txt
          tokenizer.json
          tokenizer_config.json
          special_tokens_map.json
          config.json
  lib/
    libzstd.dylib
```

Platform string format: `{os}-{arch}` where `os` is `macos`/`linux`/`windows`
and `arch` is `arm64`/`x64`, detected from `uname -s` and `uname -m`. Initial
target: macOS (arm64 and x64). Linux support may follow.

No changes to Dart source code are required — this is a pure packaging task.

## Open questions

- [x] **Q1: ORT download — separate script vs inline Makefile?**
  Resolved: a separate `scripts/download_ort.sh` script, called from the
  Makefile. The script caches downloaded dylibs in
  `packages/kmdb_inferencing/assets/native/{platform}/` and skips the download
  if the file is already present. The ORT version is defined in the Makefile as
  the single source of truth. This keeps the Makefile as the central dev tool
  while keeping the download logic independently readable and testable.

- [x] **Q2: Linux/Windows layout.** Resolved: macOS and Linux are both
  supported in this plan. Windows is deferred. Both platforms use `.tar.gz` so
  the archive step is unchanged. The only difference is the ORT library
  filename (`libonnxruntime.{version}.dylib` on macOS vs
  `libonnxruntime.so.{version}` on Linux), handled via an `ORT_LIB_NAME`
  Makefile variable and equivalent logic inside `download_ort.sh`.

- [x] **Q3: LFS guard in `make release`?**
  Resolved: yes. A file-size check on `bge_small.onnx` at the start of
  `make release` catches an LFS pointer stub before any build work begins and
  fails with an actionable message directing the developer to run
  `git lfs pull`.

## Investigation

### `dart build cli` and the native-assets pipeline

`dart build cli` is the correct build command. It must be run from inside
`packages/kmdb_cli/`. Running it triggers `packages/kmdb_zstd/hook/build.dart`
via the Dart native-assets protocol, which compiles `libzstd.dylib` using
`native_toolchain_c`. Verified working on Dart 3.11.4:

```
bundle/
  bin/kmdb          ← compiled executable
  lib/libzstd.dylib ← native asset from hook
```

`dart compile exe` does NOT trigger native build hooks; its verbose output shows
no hook execution whatsoever. This is the root cause of the original error.

The `kmdb_zstd` hook uses `LinkModePreference.dynamic` and
`routing: [const ToAppBundle()]`, which directs the dylib into `bundle/lib/`.
No hook changes are needed.

### ORT library path resolution

`packages/kmdb_inferencing/lib/src/ort_library.dart` caches the ORT dylib at:

```dart
File(Platform.resolvedExecutable).parent.path + '/libonnxruntime.1.22.0.dylib'
```

In the `dart build cli` bundle, `Platform.resolvedExecutable` is
`bundle/bin/kmdb`, so the required path is `bundle/bin/libonnxruntime.1.22.0.dylib`.

Download URL pattern (already in source):
- macOS arm64: `https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-osx-arm64-1.22.0.tgz`
- macOS x64:   `https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-osx-x64-1.22.0.tgz`

Inside the `.tgz` the dylib lives at:
`onnxruntime-osx-{arch}-1.22.0/lib/libonnxruntime.1.22.0.dylib`

Architecture detection in the Makefile uses `uname -m`. ORT archives use `arm64`
for Apple Silicon and `x64` for Intel, requiring a mapping from `x86_64` → `x64`.

### Model asset path resolution

`packages/kmdb_inferencing/lib/src/embedding_model.dart` resolves:

```dart
File(Platform.resolvedExecutable).parent.path
  + '/assets/models/bge-small-en/bge_small.onnx'
```

In the bundle: `bundle/bin/assets/models/bge-small-en/bge_small.onnx`.

Source directory: `packages/kmdb_inferencing/assets/models/bge-small-en/`

Files to copy: `bge_small.onnx`, `vocab.txt`, `tokenizer.json`,
`tokenizer_config.json`, `special_tokens_map.json`, `config.json`.

`*.onnx` files are Git LFS tracked (`.gitattributes`). `git lfs pull` must be
run before `make release`.

### Existing Makefile

`Makefile` has targets: `default`, `analyze`, `format`, `test`, `e2e_test`,
`tests_all`, `checks`, `coverage`, `clean`, `prepare`, `site`, `cicd`. No
build or release targets exist. The new targets will not use melos — they are
packaging steps, not package-level operations.

## Implementation plan

### 1. Add `dist/` to `.gitignore`

- [x] Append `dist/` to `.gitignore`.

### 2. Create `scripts/download_ort.sh`

- [x] Create `scripts/download_ort.sh` (executable).
- [x] Add `packages/kmdb_inferencing/assets/native/` to `.gitignore`.

The script takes two positional arguments:
- `$1` — `ORT_VERSION` (e.g. `1.22.0`)
- `$2` — `ORT_PLATFORM` (ORT archive naming, e.g. `osx-arm64`)

The cache destination is derived internally from the OS (detected via `uname -s`):
- macOS: `packages/kmdb_inferencing/assets/native/${2}/libonnxruntime.${1}.dylib`
- Linux: `packages/kmdb_inferencing/assets/native/${2}/libonnxruntime.so.${1}`

Behaviour:
- If the target file already exists, print a message and exit 0 (idempotent).
- Otherwise, construct the URL:
  `https://github.com/microsoft/onnxruntime/releases/download/v${1}/onnxruntime-${2}-${1}.tgz`
- Download to a temp file using `curl -fSL --progress-bar`.
- Extract only the dylib from the `.tgz` using `tar` with `--strip-components`.
- Place the dylib in the cache directory, creating it if necessary.
- Clean up the temp file on exit (`trap` on EXIT).
- Use `set -euo pipefail`.
- Print progress to stderr so Makefile output is clean.

### 3. Add platform detection variables to Makefile

- [x] Add at the top of `Makefile` (before existing targets):

```makefile
_UNAME_S        := $(shell uname -s)
_UNAME_M        := $(shell uname -m)

ORT_VERSION     := 1.22.0

ifeq ($(_UNAME_S),Darwin)
  RELEASE_OS    := macos
  ORT_OS        := osx
  ORT_LIB_NAME  := libonnxruntime.$(ORT_VERSION).dylib
else ifeq ($(_UNAME_S),Linux)
  RELEASE_OS    := linux
  ORT_OS        := linux
  ORT_LIB_NAME  := libonnxruntime.so.$(ORT_VERSION)
else
  $(error Unsupported OS for release: $(_UNAME_S))
endif

ifeq ($(_UNAME_M),arm64)
  RELEASE_ARCH  := arm64
  ORT_ARCH      := arm64
else ifeq ($(_UNAME_M),aarch64)
  RELEASE_ARCH  := arm64
  ORT_ARCH      := arm64
else
  RELEASE_ARCH  := x64
  ORT_ARCH      := x64
endif

RELEASE_PLATFORM := $(RELEASE_OS)-$(RELEASE_ARCH)
ORT_PLATFORM     := $(ORT_OS)-$(ORT_ARCH)

# Read CLI version from pubspec.yaml (e.g. "0.1.0")
RELEASE_VERSION  := $(shell grep '^version:' packages/kmdb_cli/pubspec.yaml | awk '{print $$2}')
RELEASE_NAME     := kmdb-$(RELEASE_VERSION)-$(RELEASE_PLATFORM)

KMDB_CLI_PKG    := packages/kmdb_cli
CLI_BUNDLE_DIR  := $(KMDB_CLI_PKG)/build/bundle
DIST_DIR        := dist/cli/$(RELEASE_PLATFORM)
RELEASE_ARCHIVE := $(DIST_DIR)/$(RELEASE_NAME).tar.gz
```

### 4. Add `build_cli` target

- [x] Add a `build_cli` Makefile target for local development:

```makefile
## Build the CLI binary with native assets (for local development).
## The binary is at packages/kmdb_cli/build/bundle/bin/kmdb.
build_cli:
	cd $(KMDB_CLI_PKG) && dart build cli
.PHONY: build_cli
```

### 5. Add `fetch_ort` and `release` targets

- [x] Add a `fetch_ort` Makefile target so developers can prime the cache
  independently of a full release build:

```makefile
## Download the ONNX Runtime dylib for the current platform into the local
## cache (packages/kmdb_inferencing/assets/native/). No-op if already present.
fetch_ort:
	bash scripts/download_ort.sh $(ORT_VERSION) $(ORT_PLATFORM)
.PHONY: fetch_ort
```

- [x] Add the `release` Makefile target:

```makefile
## Build a self-contained CLI archive for the current platform.
## Output: dist/cli/{os}-{arch}/kmdb-{version}-{os}-{arch}.tar.gz
## Requires: git lfs pull (to materialise bge_small.onnx)
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
```

### 6. Add `release_clean` target

- [x] Add the `release_clean` Makefile target:

```makefile
## Remove the release bundle and intermediate CLI build artifacts.
release_clean:
	rm -rf $(DIST_DIR)
	rm -rf $(KMDB_CLI_PKG)/build
.PHONY: release_clean
```

### 7. Update `clean` target

- [x] Extend the existing `clean` target to also call `release_clean`, or add
  `dist/` to whatever is already being removed, so a full `make clean` leaves
  the repo tidy.

### 8. Update developer documentation

- [x] Update `docs/user_guide/README.md` (or whichever getting-started doc is
  most prominent) to document:
  - `git lfs pull` must be run after cloning to materialise the ONNX model.
  - `make build_cli` — builds the CLI with native assets for local use; binary
    is at `packages/kmdb_cli/build/bundle/bin/kmdb`.
  - `make release` — produces a self-contained archive at
    `dist/cli/{os}-{arch}/kmdb-{version}-{os}-{arch}.tar.gz`. No further
    downloads are required when running the extracted binary.
  - `dart run bin/kmdb.dart` (from `packages/kmdb_cli/`) or
    `dart run packages/kmdb_cli/bin/kmdb.dart` (from the workspace root) both
    work for local development — native-assets hooks run in both cases.

## Summary

- Added `dist/` and `packages/kmdb_inferencing/assets/native/` to `.gitignore`.
- Created `scripts/download_ort.sh`: idempotent script that downloads the ONNX
  Runtime shared library for the current platform from GitHub Releases and caches
  it in `packages/kmdb_inferencing/assets/native/{ort-platform}/`. Skips the
  download if the file is already present.
- Added platform-detection variables to the `Makefile` (`RELEASE_OS`, `RELEASE_ARCH`,
  `ORT_LIB_NAME`, `DART_PLATFORM`, etc.) covering macOS and Linux; Windows deferred.
  `DART_PLATFORM` maps `macos-arm64` → `macos_arm64` to match `dart build cli`'s
  output directory naming.
- Added `build_cli` Makefile target for local development builds.
- Added `fetch_ort` Makefile target to prime the ORT cache independently.
- Added `release` Makefile target that: guards against LFS pointer stubs, builds
  the CLI via `dart build cli`, stages all assets, and produces a self-contained
  `.tar.gz` at `dist/cli/{os}-{arch}/kmdb-{version}-{os}-{arch}.tar.gz`.
- Added `release_clean` Makefile target; extended `clean` to also remove `dist/`.
- Updated `docs/user_guide/README.md` to replace the broken `dart compile exe`
  instructions with the release archive workflow and `make build_cli` for
  local development.
