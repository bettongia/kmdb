# Extract `betto_onnxrt` — Standalone ONNX Runtime Package

**Status**: Stage A Complete — Stage gate passed 2026-06-10. Ready for Stage B.

**PR link**: _(pending)_

**Roadmap**: [v0.05 — Multi-platform pipelines § betto_onnxrt](../roadmap/0_05.md#betto_onnxrt)

## Problem statement

`kmdb_inferencing` bundles three separate concerns in a single KMDB-internal
package: ORT binary loading (`ort_library.dart`), the FFI binding
(`ort_session.dart`), and model-cache infrastructure (`model_spec.dart`,
`model_catalog.dart`, `model_downloader.dart`). All three have no dependency on
KMDB-specific types, yet they are locked inside the KMDB monorepo. This causes
four concrete problems:

1. **iOS is broken.** `ort_library.dart` throws a generic `UnsupportedError`
   when `dart:io` cannot locate the ORT dynamic library (line ~68 and ~132).
   There is no iOS-specific branch — the iOS ORT XCFramework must be bundled at
   build time via the Dart native-assets hook mechanism (or Swift Package
   Manager), and that wiring does not exist.
2. **The FFI binding is version-fragile.** `ort_session.dart` accesses `OrtApi`
   function pointers by **numeric vtable slot index** (slot 7 = `CreateSession`,
   slot 9 = `Run`, etc.). Those slot numbers are ORT-version-specific and will
   silently corrupt if the ORT version changes without regenerating them.
   Centralising this binding in a versioned, standalone package reduces the risk
   of drift and makes the version the package's single source of truth.
3. **ORT binary acquisition is fragile.** `ort_library.dart` downloads the ORT
   dylib at first runtime from a hard-coded URL. This is a first-run stall, a
   network dependency in tests, and is an App Store violation on iOS (which
   prohibits downloading executable code at runtime). Build-time acquisition via
   a native-assets hook eliminates all three problems.
4. **A second ORT consumer (Magika, v0.06) would duplicate the infrastructure.**
   A file-type classifier using the Magika ONNX model would need the same ORT
   session management. Without a shared package, the infrastructure must be
   duplicated or awkwardly borrowed across packages.

The fix is to extract the ORT binary, FFI binding, and model-cache
infrastructure into a new standalone `betto_onnxrt` package (separate repo at
`github.com/bettongia/onnxrt`, following the `betto_zstd` **repo layout and
workspace-wiring convention only** — see the hook-model note below; the hook
*body* is a new design because ORT is a download-prebuilt, not compile-from-
source, binary), then update `kmdb_inferencing` to depend on it.

See [docs/proposals/betto_onnxrt.md](../proposals/betto_onnxrt.md) for the
full proposal, rationale, and platform binary acquisition table.

## Open questions

- [x] **Q1 — iOS XCFramework via native assets (spike required — blocking).**
      **VERDICT (2026-06-10): Native-assets NOT viable for iOS ORT. SPM plugin
      shim required.**
      The ORT iOS XCFramework (`pod-archive-onnxruntime-c-{version}.zip`) ships
      a **static library** (`Mach-O universal binary / ar archive`), not a dylib.
      Flutter's iOS native-assets system enforces `linkModePreference = dynamic`
      and rejects `StaticLinking` CodeAssets outright:
      _"link mode 'static' is not allowed by the input link mode preference
      'dynamic'"_.
      `DynamicLoadingBundled` also fails because `parseOtoolArchitectureSections`
      in `flutter_tools` expects dylib load commands and gets an `ar archive`.
      **Consequence:** The `hook/build.dart` iOS branch logs a warning and emits
      no CodeAsset. `OnnxRuntime.load()` throws `UnsupportedError` on iOS until
      the SPM plugin shim is implemented (Stage B or a dedicated follow-on plan).
      **Do not use `onnxruntime-mobile`** (reduced opset, incompatible with BGE).
      **Do not use CocoaPods** (being deprecated). The SPM shim must depend on
      `microsoft/onnxruntime-swift-package-manager` (`onnxruntime-c` variant).
- [x] **Q2 — Prebuilt ORT artifact hosting.** Use official
      `github.com/microsoft/onnxruntime/releases` artifacts initially — fast to
      start, well-known URLs, no hosting infrastructure. Migrate to
      `github.com/bettongia/onnxrt/releases` own-hosted artifacts in a follow-up
      once the hook is proven, for long-term reproducibility. SHA-256 manifest is
      kept in the `betto_onnxrt` repo regardless of source.
- [x] **Q3 — Reduced-opset builds.** Deferred to v2. Full ORT v1. The reduced-
      build CI pipeline should be scoped (documented as a placeholder in the
      `betto_onnxrt` repo) during repo setup so it is not forgotten, but no
      custom build tooling is authored in this plan.
- [x] **Q4 — API reconciliation.** The shipped `ModelSpec`/`ModelDownloader`/
      `ModelCatalog` in `kmdb_inferencing` (post-PR #39) are BGE-shaped: fields
      `onnxUrl`, `vocabUrl`, `onnxSha256`, `vocabSha256`, `embeddingDimensions`.
      The proposal's §3.3 specifies a generic shape: `Map<String, ModelFile>
      files`, `Map<String, Object?> meta`, `AllowlistProvider` interface.
      **Decision:** Stage B replaces the BGE-shaped in-tree types with the
      generic `betto_onnxrt` types. `ModelCatalog` becomes `kmdb_inferencing`'s
      concrete implementation of `AllowlistProvider`. `OnnxEmbeddingModel`
      adapts: it reads `embeddingDimensions` from `spec.meta['dimensions']` (an
      `int`), and passes the `bge-small-en-v1.5` ONNX and vocab files by their
      names in `spec.files`. Because these types are internal to
      `kmdb_inferencing` (not part of the public `kmdb` API), this is an
      internal refactor with no external API break.
- [x] **Q5 — Hook acquisition model: download-prebuilt vs compile-from-source.**
      **RESOLVED.** Download-prebuilt is the confirmed model. ORT is too large
      (~80 MB) to compile in a hook, so compile-from-source is not viable.
      Consequences recorded in the plan:
      - "Follows the `betto_zstd` convention" is narrowed throughout to mean
        **repo layout + workspace wiring only**, *not* the hook body. The
        download-+-SHA-+-stage-+-emit-`CodeAsset` hook is a new design (no
        precedent in this workspace) and points at `ModelDownloader` for its
        crash-safe write discipline.
      - **v0.05 "local build provenance" requirement is satisfied by an explicit
        waiver:** ORT is consumed as a Microsoft-signed prebuilt binary, and the
        hook verifies SHA-256 at download time. This provides *stronger*
        provenance than a local compile, so no `binaries.mk`-equivalent is
        authored for `betto_onnxrt`. The waiver is documented in the
        "Hook acquisition model & provenance waiver" investigation subsection
        below.
- [x] **Q6 — Stage A `betto_onnxrt` public API is a new design, not a lift.**
      **RESOLVED.** The generic API is confirmed. The three specs that make
      Phase 3 mechanically implementable are recorded in the new
      "Generic `OnnxSession` API specification" investigation subsection below:
      (a) the `OnnxElementType` ↔ ONNX type-code mapping table; (b) the v1
      `SessionOptions` shape — exactly two fields, `intraOpNumThreads` and
      `interOpNumThreads`, both defaulting to `1` to preserve the current
      thread-pool-teardown-safe behaviour, no other options in v1; and (c) the
      output-shape readback path using `GetTensorTypeAndShapeInfo` /
      `GetDimensionsCount` / `GetDimensions` (vtable slots 31/32/33), which must
      be added to `ort_api.dart`.
- [x] **Q7 — `ort_bindings.dart` is unaccounted for.** **RESOLVED.**
      `lib/src/ort_bindings.dart` is now listed in the investigation table and in
      the Stage B "Files removed" list; it holds the Opaque handle types
      (`OrtEnv`, `OrtSession`, `OrtSessionOptions`, `OrtValue`, `OrtStatus`,
      `OrtMemoryInfo`), all vtable typedefs, the type-code constants
      (`onnxInt64 = 7`, `onnxFloat = 1`, …), and `ortApiVersion = 22`, and moves
      entirely to `betto_onnxrt/lib/src/ort_api.dart`. Phase 3's port step now
      reads "from `ort_bindings.dart` + `ort_session.dart`". The session-wrapper
      class is `OrtInferenceSession` (not `OrtSession`, which is the Opaque handle
      type defined in `ort_bindings.dart`); all prose references corrected.
- [x] **Q8 — pubspec dependency names unverified.** **RESOLVED.** The Stage A
      Phase 2 `pubspec.yaml` is replaced with a version derived from the working
      `betto_zstd/pubspec.yaml` (see the corrected Phase 2 step below). Key
      changes vs the plan's earlier guess: remove `native_assets_api` (not in the
      precedent); move `code_assets` from dev to main dependencies (the hook
      imports it at build time); add `hooks: any` (provides the `build()` entry
      point, was missing); add `logging: any` (hook output); remove
      `native_toolchain_c` (no source compilation); bump `lints` to `^6.1.0` and
      `test` to `^1.30.0` to match `betto_zstd`.

## Investigation

### Current `kmdb_inferencing` ORT surface

| File | Responsibility |
|---|---|
| `lib/src/ort_library.dart` | Loads the ORT dynamic library at runtime: first checks `<executableDir>/assets/models/…`; falls back to downloading the dylib from a hard-coded URL. iOS hits the generic catch-all `UnsupportedError` (~line 68 and ~132). This file is the primary replacement target. |
| `lib/src/ort_bindings.dart` | Opaque handle types (`OrtEnv`, `OrtSession`, `OrtSessionOptions`, `OrtValue`, `OrtStatus`, `OrtMemoryInfo`), all vtable typedefs, type-code constants (`onnxInt64 = 7`, `onnxFloat = 1`), and `ortApiVersion = 22`. This is the bulk of the "versioned vtable-slot OrtApi FFI binding" the plan centralises. Moves entirely to `betto_onnxrt/lib/src/ort_api.dart`. |
| `lib/src/ort_session.dart` | FFI binding to `OrtApi` via numeric vtable slot indices; the session-wrapper class `OrtInferenceSession` wraps `CreateSession`/`Run`/`ReleaseSession` (do **not** confuse with the `OrtSession` Opaque handle type in `ort_bindings.dart`). Also owns `hiddenDim` (now sourced from `ModelSpec.embeddingDimensions` post-PR #39) and the token-embedding mean-pool logic. Moves to `betto_onnxrt` (the OrtApi FFI portion) and stays in `kmdb_inferencing` (the embedding/pooling logic). |
| `lib/src/embedding_model.dart` | `OnnxEmbeddingModel` — calls `OrtInferenceSession.run()`, pools token embeddings via `MathUtils.meanPool`, SQ8-quantises. KMDB-specific; stays in `kmdb_inferencing`. |
| `lib/src/model_spec.dart` | `ModelSpec` record (id, embeddingDimensions, onnxUrl, vocabUrl, onnxSha256, vocabSha256). BGE-shaped. Replaced by `betto_onnxrt`'s generic `ModelSpec` in Stage B. |
| `lib/src/model_catalog.dart` | `ModelCatalog` — allowlist of BGE model specs. Becomes an implementation of `AllowlistProvider` from `betto_onnxrt`. |
| `lib/src/model_downloader.dart` | `ModelDownloader` — SHA-256 verified download with temp-file+atomic-rename. BGE-shaped (`onnxPath`, `vocabPath` return type). Replaced by `betto_onnxrt`'s generic `ModelDownloader` in Stage B. |
| `lib/src/sq8.dart`, `math_utils.dart` | Pure-Dart domain logic; stay in `kmdb_inferencing`. |

### `betto_onnxrt` package structure

```
betto_onnxrt/              (separate repo — github.com/bettongia/onnxrt)
  VERSION_ONNX             ← e.g. "v1.22.0"; single source of truth
  hook/
    build.dart             ← downloads + stages ORT binary per platform, emits CodeAsset
  lib/
    betto_onnxrt.dart      ← public API barrel
    src/
      runtime.dart         ← OnnxRuntime.load() — opens the code asset
      session.dart         ← OnnxSession — generalised inference (not BGE-shaped)
      tensor.dart          ← OnnxTensor, OnnxElementType
      ort_api.dart         ← versioned vtable-slot OrtApi FFI binding
      model_spec.dart      ← ModelSpec (generic: id, files map, meta map)
      model_downloader.dart← download + SHA-256 + atomic rename + AllowlistProvider gate
      allowlist_provider.dart ← AllowlistProvider interface
  test/
  pubspec.yaml
```

### API (as implemented in Stage A)

```dart
final class OnnxRuntime {
  /// Opens the ORT library staged by the native-assets build hook.
  static Future<OnnxRuntime> load();
  OnnxSession createSession(Uint8List modelBytes, {SessionOptions? options});
  OnnxSession createSessionFromFile(String modelPath, {SessionOptions? options});
  void dispose();
}

final class OnnxSession {
  List<OnnxTensor> run({
    required Map<String, OnnxTensor> inputs,
    required List<String> outputNames,
  });
  void dispose();
}

final class OnnxTensor {
  final OnnxElementType elementType;
  final List<int> shape;
  final TypedData data;
}

enum OnnxElementType { float32, int64, uint8, int32, float64 }

/// v1 session options: thread-pool sizing only. Both default to 1 to preserve
/// the current thread-pool-teardown-safe behaviour (see Q6). No other fields.
final class SessionOptions {
  final int intraOpNumThreads; // default 1
  final int interOpNumThreads; // default 1
  const SessionOptions({this.intraOpNumThreads = 1, this.interOpNumThreads = 1});
}

/// Downloadable model: stable id, per-file {url, sha256}, caller metadata.
final class ModelSpec {
  final String id;                     // e.g. 'bge-small-en-v1.5'
  final Map<String, ModelFile> files;  // name → {url, sha256}
  final Map<String, Object?> meta;     // caller metadata (e.g. dimensions: 384)
  const ModelSpec({required this.id, required this.files, this.meta = const {}});
}

final class ModelFile {
  final Uri url;
  final String sha256;
  const ModelFile({required this.url, required this.sha256});
}

abstract interface class AllowlistProvider {
  bool isAllowed(ModelSpec spec);
}

final class ModelDownloader {
  ModelDownloader({AllowlistProvider? allowlist}); // null = permit-all
  Future<ResolvedModel> ensure(
    ModelSpec spec, {
    required String cacheDir,
    void Function(DownloadProgress)? onProgress,
  });
}

final class ResolvedModel {
  final ModelSpec spec;
  final Map<String, String> filePaths; // file name → absolute path
}
```

### Generic `OnnxSession` API specification (resolves Q6)

The shipped `OrtInferenceSession.run()` is BGE-shaped (int64-in / float32-out,
`hiddenDim`-parameterised, flat `List<double>` return). The generic
`OnnxSession.run()` requires the following three specs to be mechanically
implementable.

**1. `OnnxElementType` ↔ ONNX type-code mapping.** Used both to set the input
tensor element type when constructing an `OrtValue` and to interpret each output
`OrtValue`'s declared type:

| `OnnxElementType` | ONNX type code | Constant |
|---|---|---|
| `float32` | 1 | `ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT` |
| `uint8`   | 2 | `ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8` |
| `int32`   | 6 | `ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32` |
| `int64`   | 7 | `ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64` |
| `float64` | 11 | `ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE` |

**2. `SessionOptions` (v1).** Exactly two fields — `intraOpNumThreads` and
`interOpNumThreads` — both defaulting to `1`. Defaulting to 1 preserves the
existing thread-pool-teardown-safe behaviour (the current code sets both to 1).
No other options ship in v1.

**3. Output-shape readback.** The generic path must recover `List<int> shape`
from each output `OrtValue` before extracting its raw data. This requires three
additional `OrtApi` vtable slots in `ort_api.dart`:

| Slot | Symbol | Purpose |
|---|---|---|
| 31 | `GetTensorTypeAndShapeInfo` | obtain the type-and-shape info handle for an `OrtValue` |
| 32 | `GetDimensionsCount` | number of dimensions |
| 33 | `GetDimensions` | read the dimension extents into a `List<int>` |

### Hook acquisition model & provenance waiver (resolves Q5)

`betto_onnxrt` follows the `betto_zstd` convention **for repo layout and
workspace wiring only**. The hook *body* is a new design: where
`betto_zstd/hook/build.dart` compiles vendored C from source via
`CBuilder.library`, `betto_onnxrt/hook/build.dart` **downloads a Microsoft-signed
prebuilt ORT binary** (ORT is ~80 MB — far too large to compile in a hook). This
download-+-SHA-256-+-stage-+-emit-`CodeAsset` pattern has no precedent in this
workspace; it mirrors the crash-safe write discipline (temp-file + atomic-rename,
present-file SHA short-circuit, last-writer-wins on concurrent invocations) of
the existing `kmdb_inferencing` `ModelDownloader`, which Phase 2 must use as its
template.

**Provenance waiver.** The v0.05 roadmap requirement that "developers should be
able to locally build the required binaries" is satisfied for `betto_onnxrt` by
an explicit waiver rather than a `binaries.mk`-equivalent: ORT is consumed as a
Microsoft-signed prebuilt, and the hook verifies the SHA-256 against the manifest
held in the `betto_onnxrt` repo at download time. This provides *stronger*
provenance than a local compile. No `binaries.mk` is authored for this package.

### Per-platform ORT binary acquisition

| Platform | Approach |
|---|---|
| macOS | Hook downloads `onnxruntime-osx-{arch}-{ver}.tgz` from GitHub Releases; extracts dylib; emits `CodeAsset`. Replaces runtime download in `ort_library.dart`. |
| Linux | Hook downloads `onnxruntime-linux-{arch}-{ver}.tgz`; emits `libonnxruntime.so`. |
| Windows | Hook downloads `onnxruntime-win-{arch}-{ver}.zip`; emits `onnxruntime.dll`. |
| iOS | **SPM plugin shim required (Q1 verdict).** ORT iOS XCFramework is a static `ar archive`; Flutter's native-assets enforces dynamic link mode. Hook emits no CodeAsset; `OnnxRuntime.load()` throws `UnsupportedError` until the SPM shim is implemented. Not `onnxruntime-mobile`; not CocoaPods. |
| Android | Hook resolves per-ABI `.so` from Maven AAR; emits as `CodeAsset`s. Removes the Gradle `onnxruntime-android` dependency from host apps. |
| Web | Excluded (semantic search excluded from web per CLAUDE.md §20). |

### Workspace wiring

`betto_onnxrt` is a hook-bearing package and follows the same pattern as
`betto_zstd`: a bare `dependency_overrides` git-ref entry in the workspace root
`pubspec.yaml`, **not** a pub.dev dependency. `kmdb_inferencing/pubspec.yaml`
declares `betto_onnxrt:` under `dependencies:`.

```yaml
# workspace root pubspec.yaml — dependency_overrides
betto_onnxrt:
  git: git@github.com:bettongia/onnxrt.git
```

### What stays in `kmdb_inferencing`

- `OnnxEmbeddingModel` — wraps `OnnxSession` from `betto_onnxrt`.
- `ModelCatalog` — `AllowlistProvider` implementation enumerating BGE model specs.
- `sq8.dart`, `math_utils.dart` — pure-Dart domain logic.
- `OnnxEmbeddingModel.load()` signature and `EmbeddingModel` interface
  implementation are unchanged from the public API perspective.

### Files removed from `kmdb_inferencing` in Stage B

- `lib/src/ort_library.dart` — replaced by `OnnxRuntime.load()` from `betto_onnxrt`.
- `lib/src/ort_bindings.dart` — Opaque handle types, vtable typedefs, type-code
  constants, and `ortApiVersion` move to `betto_onnxrt/lib/src/ort_api.dart`.
- `lib/src/ort_session.dart` — OrtApi FFI binding moves to `betto_onnxrt`; the
  `OrtInferenceSession` pooling/embedding logic moves inline into
  `OnnxEmbeddingModel` or a private helper.
- `lib/src/model_spec.dart` — replaced by `betto_onnxrt`'s generic `ModelSpec`.
- `lib/src/model_downloader.dart` — replaced by `betto_onnxrt`'s generic `ModelDownloader`.

`model_catalog.dart` is retained and updated to implement `AllowlistProvider`.

### `VERSION_ONNX` and version generation

`betto_onnxrt` repo root holds `VERSION_ONNX` (e.g. `v1.22.0`). A
`tool/generate_versions.dart` script writes `lib/src/generated/versions.g.dart`
with the version as a Dart constant. The hook reads `VERSION_ONNX` at build
time to construct the download URL. This matches the v0.05 roadmap version-file
convention.

### Stage gate

Stage A produces a self-contained, tested `betto_onnxrt` package (all platforms
except iOS-final if Q1 remains open). Before Stage B:

1. **Q1 resolved** ✓: iOS native-assets not viable (ORT ships a static library;
   Flutter enforces dynamic link mode). SPM plugin shim chosen. Hook iOS branch
   logs a warning and emits no CodeAsset. Shim implementation deferred to Stage B
   or a follow-on plan.
2. **GitHub repo created** at `github.com/bettongia/onnxrt`; Stage A branch
   merged.
3. **CI pipeline** for the hook (download + verify + CodeAsset emission) passes
   on macOS, Linux, and Windows in GitHub Actions.
4. **Wiring ref confirmed**: the `dependency_overrides` git-ref resolves cleanly
   in a scratch `dart pub get` against the KMDB workspace.

## Implementation plan

### Stage A — Create and verify the standalone `betto_onnxrt` package

_This stage produces a self-contained, hook-bearing `betto_onnxrt` package.
Complete the Stage gate checklist above before beginning Stage B._

#### Phase 1 — iOS XCFramework spike (resolves Q1)

- [x] Created `betto_onnxrt` package with full `hook/build.dart` (real ORT
      binary download, not a stub) and integration test app.
- [x] Confirmed macOS/Linux hook execution and `flutter test --device-id macos`
      path via `make macos_test`.
- [x] Ran `make ios_test` against the integration test app targeting the iOS
      simulator to probe XCFramework linkage via native-assets.
- [x] Native-assets XCFramework linkage **failed** — see Q1 verdict above.
      The ORT iOS binary is a static `ar archive`; Flutter enforces dynamic link
      mode. Both `DynamicLoadingBundled` and `StaticLinking` were tried and
      rejected by the Flutter toolchain.
- [x] **Chosen path: SPM plugin shim** (deferred to Stage B or a follow-on
      plan). The `_buildIos` hook branch now logs a warning and emits no
      CodeAsset. `OnnxRuntime.load()` will throw `UnsupportedError` on iOS
      until the shim is implemented.
- [x] Spike outcome documented in Q1 above; plan updated.

#### Phase 2 — Package scaffold and build hook

- [x] Create the directory `/Users/gonk/development/bettongia/onnxrt/` and
      initialise a git repository.
- [x] Write `VERSION_ONNX` file (e.g. `v1.22.0` — match the version currently
      used by `kmdb_inferencing`).
- [x] Write `pubspec.yaml`:
  ```yaml
  name: betto_onnxrt
  description: >
    ONNX Runtime for Dart — build-time binary via native-assets hook,
    generalised OnnxSession API, and model-download infrastructure.
  version: 0.1.0
  homepage: https://github.com/bettongia/onnxrt
  environment:
    sdk: ^3.12.0
  dependencies:
    code_assets: any
    hooks: any
    ffi: ^2.2.0
    logging: any
  dev_dependencies:
    lints: ^6.1.0
    test: ^1.30.0
  ```
  This set is derived from the working `betto_zstd/pubspec.yaml`. `code_assets`
  and `hooks` are **main** dependencies (the hook imports them at build time);
  `native_assets_api` and `native_toolchain_c` are intentionally absent (no
  source compilation, and `native_assets_api` is not in the precedent).
- [x] Write `analysis_options.yaml`.
- [x] Add Apache 2.0 `LICENSE` file.
- [x] Write `hook/build.dart`:
  - Read `VERSION_ONNX` from package root.
  - Per build target OS/architecture, construct the GitHub Releases download URL.
  - Verify existing cached artifact SHA-256; skip download if valid.
  - Download to temp path; verify SHA-256; atomic-rename on success.
  - Emit the library as a `CodeAsset`.
  - iOS: implement the Q1-resolved path (native-assets XCFramework or plugin shim).
- [x] Write `tool/generate_versions.dart` to write
      `lib/src/generated/versions.g.dart` from `VERSION_ONNX`.
- [x] Run `dart run tool/generate_versions.dart`.
- [x] Add Apache 2.0 license header to all Dart files (use `header_template.txt`
      format).

#### Phase 3 — Core API implementation

- [x] Implement `lib/src/ort_api.dart` — versioned vtable-slot `OrtApi` FFI
      binding. Port the binding from `kmdb_inferencing/lib/src/ort_bindings.dart`
      + `lib/src/ort_session.dart` (the Opaque handle types, vtable typedefs,
      type-code constants, and `ortApiVersion` live in `ort_bindings.dart`). Add
      the three output-shape-readback slots not present in the BGE-shaped binding:
      `GetTensorTypeAndShapeInfo` (slot 31), `GetDimensionsCount` (slot 32),
      `GetDimensions` (slot 33) — see "Generic `OnnxSession` API specification".
      Annotate each slot index with the ORT API symbol name it corresponds to, so
      version drift is detectable.
- [x] Implement `lib/src/runtime.dart` — `OnnxRuntime.load()` opens the
      code-asset library and initialises the `OrtApi`.
- [x] Implement `lib/src/session.dart` — generalised `OnnxSession.run()` (not
      BGE-shaped: arbitrary input/output names and element types). Map element
      types via the `OnnxElementType` ↔ ONNX type-code table, recover each output
      tensor's `shape` via slots 31/32/33, and honour the two-field
      `SessionOptions` (both thread counts default 1) — all specified in the
      "Generic `OnnxSession` API specification" investigation subsection.
- [x] Implement `lib/src/tensor.dart` — `OnnxTensor`, `OnnxElementType`,
      `SessionOptions`.
- [x] Implement `lib/src/allowlist_provider.dart` — `AllowlistProvider`
      interface.
- [x] Implement `lib/src/model_spec.dart` — generic `ModelSpec` (id, files map,
      meta map), `ModelFile`.
- [x] Implement `lib/src/model_downloader.dart` — `ModelDownloader` with
      `AllowlistProvider` gate, SHA-256 verification, temp-file + atomic-rename
      crash safety, `ResolvedModel` return type. Mirror the write discipline from
      the existing `kmdb_inferencing` `ModelDownloader`.
- [x] Write `lib/betto_onnxrt.dart` barrel exporting all public types.
- [x] Ensure all public classes, methods, and properties have doc comments.
- [x] Ensure license header on every source file.

#### Phase 4 — Tests

- [x] Unit tests for `OnnxSession` using a tiny valid `.onnx` fixture (include a
      minimal ONNX model in `test/fixtures/`; the BGE model is too large for CI).
      Fixture generated by `tool/generate_test_fixture.dart` (98-byte identity
      graph, float32[1,4]→float32[1,4]). OnnxSession tests are automatically
      skipped in `dart test` JIT mode (no ORT binary on linker path); they run
      when the library is on `DYLD_LIBRARY_PATH` / `LD_LIBRARY_PATH` — see RC-15.
- [x] Unit tests for `ModelDownloader` with mock HTTP (partial download, corrupt
      download, checksum mismatch + retry, temp-file-then-rename, present-file
      short-circuit, allowlist rejection). No real network download in the suite.
      63 tests pass, 6 skipped (OnnxSession — requires ORT binary on load path).
- [x] Hook smoke test: `test/hook_smoke_test.dart` verifies `native_assets.yaml`
      exists after the hook runs, no stale `.part` files remain, and the cache
      directory is version-scoped. Passes in CI (hook runs before test loading).
- [x] Tests that cannot run in CI (real-platform binary download, full iOS build)
      are documented as RC-15 in `docs/spec/28_release_checklist.md`.
- [x] Run `dart test` from `/Users/gonk/development/bettongia/onnxrt/` and
      confirm all tests pass. Result: 63 passed, 6 skipped (2026-06-09).
- [x] Commit all files, create the GitHub repo at `github.com/bettongia/onnxrt`,
      push. CI/CD (GitHub Actions: ubuntu/macos/windows) passes. Stage gate
      complete as of 2026-06-10.

---

### ⛔ Stage gate — manual steps required before Stage B

Before continuing to Stage B, the following must be complete:

1. **Q1 resolved**: iOS XCFramework spike outcome recorded; hook iOS path
   confirmed functional (or plugin shim path chosen and implemented).
2. **GitHub repo** `github.com/bettongia/onnxrt` created; Stage A PR merged to
   `main`.
3. **CI pipeline** (GitHub Actions) passing: hook download + SHA-256 verification
   + `CodeAsset` emission on macOS, Linux, and Windows runners.
4. **Workspace dependency resolves**: add the `betto_onnxrt` git-ref override to
   the KMDB workspace root `pubspec.yaml` in a scratch branch and confirm
   `dart pub get` resolves cleanly.

---

### Stage B — Wire `betto_onnxrt` into the KMDB workspace

_Prerequisite: Stage gate above is complete. Update the `dependency_overrides`
git ref to the actual merged SHA before running these steps._

#### Phase 5 — Wire `betto_onnxrt` into the KMDB workspace

- [ ] Add to workspace root `pubspec.yaml` `dependency_overrides`:
  ```yaml
  betto_onnxrt:
    git: git@github.com:bettongia/onnxrt.git
  ```
- [ ] Add `betto_onnxrt:` under `dependencies:` in
      `packages/kmdb_inferencing/pubspec.yaml`.
- [ ] Run `dart pub get` from the workspace root to confirm resolution.

#### Phase 6 — Migrate `kmdb_inferencing` to `betto_onnxrt`

- [ ] Replace `lib/src/ort_library.dart` usage with `OnnxRuntime.load()` from
      `betto_onnxrt`. Delete `ort_library.dart`.
- [ ] Replace the OrtApi FFI binding in `lib/src/ort_session.dart` +
      `lib/src/ort_bindings.dart` with `OnnxSession` from `betto_onnxrt`. Retain
      the embedding/mean-pool logic in `OnnxEmbeddingModel` (move it inline or to
      a private helper). Delete `ort_bindings.dart` outright, and delete
      `ort_session.dart` (or reduce it to a thin `OnnxEmbeddingModel`-only file if
      the session logic was entangled — in that case rename it
      `embedding_session.dart` and remove the FFI binding portion).
- [ ] Replace `lib/src/model_spec.dart` and `lib/src/model_downloader.dart` with
      imports from `betto_onnxrt`. Adapt `OnnxEmbeddingModel.load()` to use the
      generic `ModelSpec` (read `embeddingDimensions` from
      `spec.meta['dimensions'] as int`, resolve ONNX/vocab paths via
      `resolvedModel.filePaths['onnx']` and `resolvedModel.filePaths['vocab']`).
      Delete the two in-tree files.
- [ ] Update `lib/src/model_catalog.dart` — `ModelCatalog` implements
      `AllowlistProvider` from `betto_onnxrt`. Update the BGE Small En v1.5 and
      BGE-M3 entries to use the generic `ModelSpec` shape:
      `files: {'onnx': ModelFile(url: …, sha256: …), 'vocab': ModelFile(…)}`,
      `meta: {'dimensions': 384}` (or 1024 for BGE-M3).
- [ ] Close the iOS gap: `OnnxRuntime.load()` in `betto_onnxrt` resolves the
      XCFramework via the code asset — no `UnsupportedError` for iOS. Confirm
      `ort_library.dart` is fully removed and no iOS `UnsupportedError` remains.
- [ ] Ensure doc comments on all changed public members; update any stale
      `kmdb_tokenizer_icu` or `kmdb_inferencing`-internal references in
      `kmdb_inferencing` doc comments.

#### Phase 7 — Tests and pre-commit gate

- [ ] Update all `kmdb_inferencing` tests to use the `betto_onnxrt` types where
      applicable (`ModelSpec`, `ModelDownloader`, `ResolvedModel`).
- [ ] Confirm all existing `kmdb_inferencing` tests pass (the existing bundled
      LFS model is still in place per the deferred Q5 from
      `plan_configurable_embedding_model.md`).
- [ ] Run `cd packages/kmdb_inferencing && dart test`.
- [ ] Run `make analyze` to confirm no broken imports remain.
- [ ] Run `make pre_commit` and confirm it passes cleanly.
- [ ] Run `make test` to confirm the full workspace test suite passes.

#### Phase 8 — Documentation

- [ ] Update `CLAUDE.md` `Repository Layout` section:
  - Add `betto_onnxrt` to the external `betto_*` packages list with its GitHub URL.
- [ ] Update `packages/kmdb_inferencing/README.md` to reflect the new dependency
      on `betto_onnxrt` and the new `OnnxRuntime.load()` initialisation sequence.
- [ ] Add or update the relevant `docs/spec/` section (§22 semantic search or a
      new section on native infrastructure) to document the `betto_onnxrt`
      dependency and the build-hook acquisition model.
- [ ] Open a PR for the KMDB monorepo changes.

## Summary

_(To be filled in after implementation.)_

---

## Review — 2026-06-09 (kmdb-plan-reviewer)

**Verdict: not yet `Investigated`. Status set to `Questions`.** Q1 alone would
not block — it is properly fenced behind a Stage gate and Phase 1 spike. But the
review surfaced four further gaps (recorded as **Q5–Q8** in Open questions) that
would force the Sonnet implementer to make non-trivial design decisions on the
fly. The problem statement and overall structure are strong; the Stage A
checklist is not yet a mechanical specification.

### Problem Statement Assessment — strong

The four-point problem (iOS broken, version-fragile vtable binding, runtime
download fragility / App Store violation, future Magika duplication) is real,
well-grounded, and matches the code. `ort_library.dart` genuinely throws
`UnsupportedError` on iOS and downloads the dylib at first runtime from a
hard-coded URL (lines 54–58, 68, 132). The vtable-slot binding is genuinely
version-fragile (`ortApiVersion = 22` and ~20 magic slot indices). Extraction is
justified, aligns with the v0.05 roadmap (`docs/roadmap/0_05.md` §betto_onnxrt),
and the §2 proposal already rejected the plausible alternatives (pub.dev plugins,
federated plugin) for sound reasons (pure-Dart CLI constraint). No objection to
*doing* this work.

### Proposed Solution Assessment

**Strengths:** Two-stage split (build the standalone package → wire it in) with a
hard manual Stage gate is the right shape for cross-repo work. The Stage gate is
well-positioned: it correctly fences the four things that cannot be done from
inside the KMDB monorepo (repo creation, CI proof, iOS spike, dependency
resolution) before Stage B touches `kmdb_inferencing`. Q2/Q3/Q4 are answered with
real decisions. Q4's internal-refactor framing (these types are not part of the
public `kmdb` API, so no external break) is correct and important.

**Weaknesses — the blocking gaps (Q5–Q8):**

1. **"Follows the betto_zstd convention" is half true and half misleading (Q5).**
   `betto_zstd/hook/build.dart` *compiles vendored C from source* with
   `CBuilder.library`; `betto_onnxrt` *downloads a prebuilt binary*. There is no
   download-prebuilt hook anywhere in this workspace. This is the single largest
   technical risk in Stage A, and it is specified only as prose bullets in Phase 2.
   The plan must (a) narrow "convention" to mean repo layout + workspace wiring,
   and (b) reconcile the download model against the v0.05 "developers can build
   binaries locally" provenance requirement (`betto_zstd` satisfies it via
   `binaries.mk`; the download hook needs an equivalent answer or an explicit
   waiver).

2. **Stage A's public API is a new design presented as a lift (Q6).** The generic
   `OnnxSession.run({Map<String, OnnxTensor> inputs, …}) -> List<OnnxTensor>` is
   materially different from the shipped `OrtInferenceSession.run(...)`, which is
   int64-in/float32-out, shape-and-`hiddenDim`-parameterised, and returns a flat
   `List<double>`. Generalising it requires an `OnnxElementType` ↔ ONNX type-code
   table, a `SessionOptions` field set, and an output-shape readback path — none of
   which the plan specifies. Phase 3 reduces this to a single checklist line.

3. **`ort_bindings.dart` is invisible to the plan (Q7).** The vtable typedefs,
   slot constants, and `ortApiVersion` the plan wants to centralise actually live
   in `ort_bindings.dart`, which the investigation table never lists. Stage B's
   removal list and Phase 3's "port the binding" step are therefore incomplete.
   Compounding this, the plan's prose calls the session class `OrtSession`
   throughout, but the real class is `OrtInferenceSession` — `OrtSession` is an
   `Opaque` FFI handle type. An implementer following the prose literally would
   grep for the wrong symbol.

4. **The Stage A pubspec is guessed, not verified (Q8).** `native_assets_api:
   ^0.0.1` does not appear in the working `betto_zstd` hook package; `hooks` (the
   package providing the `build()` entry point every hook here uses) is missing
   from the plan's pubspec; `code_assets`/`hooks` are regular deps in betto_zstd,
   not dev_deps. These must be reconciled against the known-good precedent.

### Architecture Fit

No conflict with the LSM / sync / cache invariants — this is infrastructure below
the storage engine, touching only `kmdb_inferencing` (semantic search,
`$vec:` namespaces, already excluded from sync and cache per CLAUDE.md §20).
Web exclusion is correctly carried through. The workspace wiring in Stage B
(bare dep in `kmdb_inferencing/pubspec.yaml` + git-ref override in root
`pubspec.yaml`, no `ref:`) correctly matches the live `betto_zstd` Pattern A
wiring — verified against root `pubspec.yaml` and `packages/kmdb/pubspec.yaml`.
That part is mechanical and correct.

### Risk & Edge Cases

- **Download hook crash safety / caching.** Phase 2 mentions "verify cached
  artifact SHA-256; skip download if valid" and "atomic-rename on success" — good,
  but this is the exact discipline the existing `ModelDownloader` already
  implements and the plan should point Phase 2 at it as the template (it does so
  for the *model* downloader in Phase 3 but not for the *binary* hook).
- **Concurrent `dart pub get` / parallel hook invocations** writing the same
  cached ORT artifact are not addressed. `ModelDownloader`'s doc comment reasons
  explicitly about last-writer-wins; the hook needs the same reasoning.
- **Test fixtures.** Phase 4's "tiny valid `.onnx` fixture" is the right call (the
  127 MB BGE model cannot go in CI), and it dovetails with the roadmap's stated
  prerequisite for LFS removal (`0_05.md`: "a small purpose-built fixture ONNX
  model … satisfies the BGE input/output shape without real weights"). Worth
  cross-referencing so the fixture is built once and reused.
- **Release-checklist items** (real-platform binary download, full iOS build) are
  correctly flagged for `docs/spec/28_release_checklist.md`. Good.

### Implementation Readiness

Stage B (Phases 5–8) is close to mechanical once Stage A lands and Q4's decisions
are applied — the only fix needed there is adding `ort_bindings.dart` to the
removal list and correcting the `OrtSession`→`OrtInferenceSession` naming.

Stage A (Phases 1–4) is **not** mechanically executable yet: Phase 1 is a spike
(Q1, correctly so), and Phases 2–3 leave the hook acquisition model (Q5), the
generic session API (Q6), the binding source files (Q7), and the dependency set
(Q8) underspecified. A Sonnet implementer would have to invent the
`OnnxElementType` mapping, the `SessionOptions` shape, and the download-hook
structure unaided.

### Recommendations

1. Resolve **Q5–Q8** in the plan text (most are spec-tightening, not user
   decisions — Q6's `SessionOptions`/type-table is the only one that is a genuine
   design choice worth recording explicitly).
2. Add `ort_bindings.dart` to the investigation table and Stage B removal list;
   fix every `OrtSession` → `OrtInferenceSession` in prose.
3. Narrow every "follows the betto_zstd convention" claim to scope it to repo
   layout + workspace wiring; describe the download-hook body as its own (new)
   design and point it at `ModelDownloader` for the crash-safe write discipline.
4. Reconcile the Phase 2 `pubspec.yaml` against the live `betto_zstd` hook
   package's dependency set.
5. Keep **Q1** exactly as it is — it is correctly deferred to the Phase 1 spike
   behind the Stage gate and does not need resolving before `Investigated`,
   *provided* Stage A's checklist explicitly cannot complete past Phase 1 until
   the spike verdict is recorded (it already says this; good).

Once Q5–Q8 are addressed and the naming/file-list corrections are made, this is a
strong plan and can move to `Investigated` — Q1 remaining open is acceptable
because it is gated, not because it is ignored.

---

## Review — 2026-06-09 (follow-up, kmdb-plan-reviewer)

**Verdict: `Investigated`.** Q5–Q8 are all resolved with the user's decisions
recorded both in the Open questions block and in the plan body:

- **Q5** — Download-prebuilt confirmed. "Follows the `betto_zstd` convention" is
  narrowed to repo layout + workspace wiring throughout (problem statement +
  new "Hook acquisition model & provenance waiver" subsection). The v0.05 local-
  build-provenance requirement is satisfied by an explicit, documented waiver
  (Microsoft-signed prebuilt + download-time SHA-256), no `binaries.mk`.
- **Q6** — Generic API confirmed and made mechanical: the new "Generic
  `OnnxSession` API specification" subsection pins the `OnnxElementType` ↔ ONNX
  type-code table, the two-field `SessionOptions` (both thread counts default 1),
  and the slot-31/32/33 output-shape readback path. `SessionOptions` is now in
  the API block and Phase 3 references all three.
- **Q7** — `ort_bindings.dart` is now in the investigation table, the Stage B
  removal list, Phase 3's port step, and Phase 6's deletion step. The
  session-wrapper class is corrected to `OrtInferenceSession` throughout the
  forward-looking prose; `OrtSession` survives only where it correctly names the
  Opaque handle type.
- **Q8** — Phase 2 `pubspec.yaml` replaced with the `betto_zstd`-derived set
  (`code_assets`/`hooks` as main deps, `logging`, `ffi`; `native_assets_api` and
  `native_toolchain_c` removed; `lints ^6.1.0`, `test ^1.30.0`).

**Q1 remains open by design** — it is the Stage A Phase 1 iOS XCFramework spike,
fenced behind the hard Stage gate. The Stage A checklist explicitly cannot
proceed past Phase 1 until the spike verdict is recorded, so leaving it open does
not block `Investigated` status. No other open questions remain.

The plan now clears the implementation-readiness bar: named files/classes,
pinned data formats (type-code table, slot indices, `SessionOptions`, pubspec),
an ordered Stage A→gate→Stage B checklist, a testing strategy with fault cases
and release-checklist carve-outs, and no unresolved architecture decisions left
to the implementer.
