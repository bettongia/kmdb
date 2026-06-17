# Technical Proposal: `betto_onnxrt` — ONNX Runtime Package

## 1. Overview

`kmdb_inferencing` currently bundles ONNX Runtime (ORT) distribution, FFI
bindings, and model management in a single package that is tightly coupled to
KMDB's internal embedding pipeline. This creates three problems that only grow
as the platform and model surface expands:

1. **iOS is broken.** `ort_library.dart` throws `UnsupportedError` for
   `Platform.isIOS` — the iOS ORT framework must be bundled at build time via
   the Swift Package Manager, which is not wired up.
2. **The FFI binding is version-fragile.** `ort_session.dart` accesses
   `OrtApi` function pointers by **numeric vtable slot index** (`_slotPtr<T>(
   struct, slotIndex)` — slot 7 = `CreateSession`, slot 9 = `Run`, etc.).
   Those slot numbers are ORT-version-specific and will silently corrupt if
   the ORT version changes without regenerating them. Centralising this
   binding in a versioned package reduces the risk of drift.
3. **Model management is KMDB-domain coupled.** The planned `ModelDownloader`
   and `ModelSpec` types (see
   [plan_configurable_embedding_model.md](../plans/plan_configurable_embedding_model.md))
   have no KMDB-specific dependencies. A second ORT consumer in v0.06
   (Magika, a file-type classifier) would need to duplicate or borrow the
   same infrastructure.

This proposal defines a standalone `betto_onnxrt` Dart package — separate from
the KMDB monorepo, following the `betto_zstd` package family convention — that
provides the ORT runtime binary, FFI bindings, and model-cache infrastructure
as a reusable dependency.

### Goals

- Bundle the ONNX Runtime binary for all target platforms at **build time**
  (not at first-run), using the Dart native-assets hook mechanism.
- Provide a generalised `OnnxSession` API usable by both embedding models
  (BGE Small En, BGE-M3) and classifiers (Magika) — not BGE-shaped.
- Provide a `ModelDownloader` and `ModelSpec` infrastructure for on-demand
  model acquisition with crash-safe download and SHA-256 verification.
- Expose an optional `AllowlistProvider` interface so callers can restrict
  which models may be used; `betto_onnxrt` itself ships no fixed allowlist.
- Be usable from **pure-Dart CLI programs** (`kmdb_cli`) as well as Flutter
  applications — no Flutter engine required.
- Pin to a specific ORT version; expose the version as a generated constant
  derived from a `VERSION_ONNX` file, consistent with the v0.05 version-file
  convention.

### Non-goals (v1)

- Generic multi-backend ML runtime abstraction (TFLite, CoreML, TensorRT).
  The swap seam already exists in KMDB via the `EmbeddingModel` interface in
  `packages/kmdb/lib/src/search/embedding_model.dart`. A future CoreML-backed
  embedder would be a separate sibling package; there is no second concrete
  backend to justify a generic abstraction now.
- Web / WASM support. KMDB excludes semantic search from the web browser
  (CLAUDE.md §20); ORT-Web is real but heavy and is not a v1 requirement.
- GPU execution providers (CUDA, DirectML, NNAPI). CPU-only ORT covers all
  current models and targets.
- Reduced-opset / ORT-format models. The full BGE and Magika operator sets are
  supported by the full ORT build. A custom reduced build is a future size
  optimisation, not a v1 requirement.

---

## 2. Considered approaches

### 2.1 Adopt an existing pub.dev package

Candidates: `flutter_onnxruntime` (1.7.1, ORT 1.22.0, publisher-verified),
`onnxruntime` (gtbluesky), `fonnx` (Telosnex).

**Rejected.** Every maintained ORT package on pub.dev is a Flutter *plugin*,
requiring the Flutter plugin/build system for both library resolution and the
`dart:ffi` binding. `kmdb_inferencing` and `kmdb_cli` are pure Dart — a Flutter
plugin cannot be used from `dart compile exe` or `dart run` without a Flutter
engine. Adopting one would either force the CLI to become a Flutter app or leave
the CLI on a separate bespoke FFI path anyway, maintaining two integration
points.

### 2.2 Federated Flutter plugin (sherpa_onnx pattern)

Separate per-platform packages (`betto_onnxrt_ios`, `betto_onnxrt_android`,
`betto_onnxrt_macos`, …) each shipping the prebuilt ORT binary for that
platform, federated under a common `betto_onnxrt` interface package.

**Rejected.** The federated plugin mechanism requires the Flutter build system
for binary resolution and plugin registration. The pure-Dart CLI constraint
rules it out for the same reason as §2.1. The `sherpa_onnx` pattern is the
right model to *study* for per-platform binary staging; it is not the right
model to *adopt* when CLI support is a hard requirement.

### 2.3 Native-assets build hook (`package:sqlite3` v3 pattern) ✓ Recommended

A single `betto_onnxrt` package with a `hook/build.dart` that downloads the
prebuilt ORT binary for the current build target, verifies its SHA-256, stages
it, and emits a `CodeAsset`. The Dart and Flutter toolchains both consume code
assets — the same hook feeds `dart compile exe` (CLI) and `flutter build ios`
(mobile) without any per-platform package split.

This is exactly what `package:sqlite3` v3 does. It is the precedent in the
Dart/Flutter ecosystem for "prebuilt native binary, usable from CLI and Flutter,
single package." The `betto_zstd` package compiles Zstd from source in its hook
(feasible because Zstd is dependency-free C); `betto_onnxrt` downloads prebuilt
ORT artifacts instead (necessary because ORT is a large C++ project with its
own CMake toolchain). The packaging philosophy is identical.

Key properties of this approach:

- **pub.dev sees kilobytes, not megabytes.** The hook source and SHA-256
  manifest are in the published package; binaries are downloaded during `dart
  pub get` / `flutter pub get` by the hook. `sqlite3` keeps its published
  package under 1 MB despite bundling a real native library; `betto_onnxrt`
  follows the same pattern.
- **Build-time acquisition, not first-run.** The ORT binary is present when
  the application starts; there is no first-launch download stall or network
  failure for the runtime itself. Only *models* remain on-demand.
- **Pure-Dart CLI is a solved problem** in the `sqlite3` v3 design — "usable
  without Flutter" is an explicit goal of that package.

iOS is the one platform where native-assets XCFramework linkage is not yet
exercised by `sqlite3` (which compiles from source on iOS). This is the single
spike required before the proposal can be fully closed; see §5.

---

## 3. Recommended design

### 3.1 Package structure

```
betto_onnxrt/                          (separate repo, github.com/bettongia/onnxrt)
  VERSION_ONNX                         ← e.g. "v1.22.0"; single source of truth
  hook/
    build.dart                         ← downloads + stages ORT binary, emits CodeAsset
  lib/
    betto_onnxrt.dart                  ← public API barrel
    src/
      runtime.dart                     ← OnnxRuntime (opens the code asset)
      session.dart                     ← OnnxSession (generalised inference)
      tensor.dart                      ← OnnxTensor, OnnxElementType
      ort_api.dart                     ← vtable-slot OrtApi FFI binding (versioned)
      model_spec.dart                  ← ModelSpec value type
      model_downloader.dart            ← download + SHA-256 + atomic rename
      allowlist_provider.dart          ← AllowlistProvider interface
  test/
  pubspec.yaml
```

`VERSION_ONNX` is the single source of truth for the pinned ORT version.
`hook/build.dart` reads it to construct the download URL. A
`tool/generate_versions.dart` script writes a `lib/src/generated/versions.g.dart`
constant, consistent with the v0.05 version-file convention for the workspace.

### 3.2 Binary acquisition per platform

| Platform | Build-time acquisition | Notes |
|---|---|---|
| macOS | Hook downloads `onnxruntime-osx-{arch}-{ver}.tgz` from GitHub Releases; extracts `libonnxruntime.{ver}.dylib`; emits as `CodeAsset` | Replace `ort_library.dart` runtime-download entirely |
| Linux | Hook downloads `onnxruntime-linux-{arch}-{ver}.tgz`; emits `libonnxruntime.so.{ver}` | x86\_64 + arm64 |
| Windows | Hook downloads `onnxruntime-win-{arch}-{ver}.zip`; emits `onnxruntime.dll` | Authenticode signing via CI (OV cert per v0.05 pipeline) |
| iOS | **Spike required** — see §5. Primary path: hook stages ORT XCFramework (from `microsoft/onnxruntime-swift-package-manager`) and emits as a `CodeAsset` that Flutter/Xcode links. Fallback: minimal iOS-only Flutter plugin shim with `Package.swift` SPM dependency | Use full `onnxruntime-c` XCFramework, **not** `onnxruntime-mobile` (reduced opset, incompatible with BGE) |
| Android | Hook resolves per-ABI `.so` files from the Maven AAR (`com.microsoft.onnxruntime:onnxruntime-android:{ver}`); emits as `CodeAsset`s; Flutter native-assets places them in `jniLibs` | Removes the Gradle dependency from the host app (currently `kmdb_ui`), replacing it with transparent hook-based delivery |
| Web | Excluded from v1 (semantic search excluded from web, CLAUDE.md §20) | |

### 3.3 API

```dart
/// Opens the ORT library bundled by the build hook. Fast — no download,
/// no file resolution at runtime. Throws [UnsupportedError] on web.
final class OnnxRuntime {
  static Future<OnnxRuntime> load();

  /// Creates an inference session from [modelBytes] (an .onnx file in memory).
  OnnxSession createSession(
    Uint8List modelBytes, {
    SessionOptions? options,
  });

  /// Creates an inference session from a file path. Preferred when the model
  /// is large and memory-mapping is desirable.
  OnnxSession createSessionFromFile(
    String modelPath, {
    SessionOptions? options,
  });

  void dispose();
}

/// A single ORT inference session. Generalised — not BGE-shaped.
/// Supports arbitrary input/output names and tensor element types.
final class OnnxSession {
  /// Runs inference. [inputs] are keyed by the model's input node names;
  /// [outputNames] selects which outputs to return.
  List<OnnxTensor> run({
    required Map<String, OnnxTensor> inputs,
    required List<String> outputNames,
  });

  void dispose();
}

/// A tensor with a fixed element type and shape.
final class OnnxTensor {
  final OnnxElementType elementType;
  final List<int> shape;
  // Typed data: Int64List, Float32List, Uint8List, etc.
  final TypedData data;

  const OnnxTensor({required this.elementType, required this.shape, required this.data});
}

enum OnnxElementType { float32, int64, uint8, int32, float64 /* ... */ }

/// Describes a downloadable model: stable id, file URLs, SHA-256 checksums,
/// and any caller-meaningful metadata (e.g. embedding dimensions).
final class ModelSpec {
  final String id;                     // e.g. 'bge-small-en-v1.5'
  final Map<String, ModelFile> files;  // name → {url, sha256}
  final Map<String, Object?> meta;     // caller metadata (dimensions, etc.)

  const ModelSpec({required this.id, required this.files, this.meta = const {}});
}

final class ModelFile {
  final Uri url;
  final String sha256;
  const ModelFile({required this.url, required this.sha256});
}

/// Caller-supplied gate controlling which models [ModelDownloader] may fetch.
/// Default behaviour (no provider) is permit-all. [kmdb_inferencing] supplies
/// its BGE catalog as a concrete implementation; Magika consumers supply theirs.
abstract interface class AllowlistProvider {
  /// Return false (or throw) to prevent [spec] from being downloaded.
  bool isAllowed(ModelSpec spec);
}

/// Downloads and caches model files with crash-safe write discipline:
/// download to a temp path, verify SHA-256, then atomically rename.
/// Concurrent invocations sharing the same [cacheDir] are safe: both writers
/// produce byte-identical verified output; last-writer-wins on the rename.
final class ModelDownloader {
  ModelDownloader({AllowlistProvider? allowlist}); // null = permit-all

  /// Ensures every file in [spec] is present and verified under [cacheDir].
  /// Short-circuits if files exist and checksums match. Downloads and verifies
  /// any missing or corrupt files. Calls [onProgress] during active downloads.
  Future<ResolvedModel> ensure(
    ModelSpec spec, {
    required String cacheDir,
    void Function(DownloadProgress)? onProgress,
  });
}

/// Paths to all files for a resolved [ModelSpec], ready for use.
final class ResolvedModel {
  final ModelSpec spec;
  final Map<String, String> filePaths; // file name → absolute path
}

final class DownloadProgress {
  final String fileName;
  final int bytesReceived;
  final int? totalBytes; // null if Content-Length absent
}
```

### 3.4 What stays in `kmdb_inferencing`

`betto_onnxrt` is deliberately model-agnostic. `kmdb_inferencing` retains:

- `OnnxEmbeddingModel` — wraps `OnnxSession` to implement the `EmbeddingModel`
  interface (calls `session.run()`, pools token embeddings, SQ8-quantises).
- `ModelCatalog` — `kmdb_inferencing`'s concrete implementation of
  `AllowlistProvider`, enumerating permitted BGE model specs with their URLs,
  checksums, and `embeddingDimensions` metadata.
- `sq8.dart`, `math_utils.dart`, `ort_session.dart` dimension generalisation
  — all KMDB-domain concerns, implemented in the
  `plan_configurable_embedding_model.md` plan.

`betto_onnxrt` defines the types (`ModelSpec`, `AllowlistProvider`,
`ModelDownloader`). `kmdb_inferencing` depends on `betto_onnxrt` and provides
the KMDB-specific concrete values (the catalog, the embedding logic).

---

## 4. Sequencing

### 4.1 Relationship to `plan_configurable_embedding_model.md`

The configurable embedding model plan is `Investigated` and ready to implement.
It places `ModelSpec`, `ModelCatalog`, and `ModelDownloader` in
`kmdb_inferencing`. This overlaps with what `betto_onnxrt` will eventually own,
but the plan should be implemented **as-is, first** — not blocked on standing up
a new external repo.

Two targeted adjustments to the plan implementation allow later extraction to be
a near-mechanical import swap:

1. Implement `ModelDownloader` with the **exact signature from §3.3** (above),
   not a bespoke shape. When `betto_onnxrt` exists, the import changes from
   `kmdb_inferencing` to `betto_onnxrt`; the call sites do not change.
2. Frame `ModelCatalog` as `kmdb_inferencing`'s **implementation of
   `AllowlistProvider`** from the start (catalog = the allowed set). This
   matches the Q2 decision and means no API rework when ownership moves.

All other plan work (dimension generalisation, `modelId` on `VecIndexState`,
`reindex()`, config migration) is independent of this proposal and stands
unchanged.

### 4.2 Suggested milestones

| Milestone | Work |
|---|---|
| v0.05 (platform infra) | Implement `plan_configurable_embedding_model.md` with the §4.1 adjustments. Author `betto_onnxrt` repo: `hook/build.dart` for macOS/Linux/Windows, `OnnxRuntime.load()`, generalised `OnnxSession`. Run the iOS XCFramework native-assets spike (§5). |
| Post-v0.05 extraction | Replace `kmdb_inferencing`'s in-tree `ModelDownloader`/`ModelSpec` with `import 'package:betto_onnxrt/...'`. Close iOS gap: wire up the SPM XCFramework path in the hook (or the fallback shim). Replace `ort_library.dart` runtime-download with hook-bundled binary. |
| v0.06 | Magika consumes `OnnxSession` directly from `betto_onnxrt` as a file-type classifier — the second model type that validates the multi-consumer design. |

---

## 5. Open questions

### Q1 — iOS XCFramework via native assets (spike required)

`package:sqlite3` compiles from source on iOS (a single C TU). `betto_onnxrt`
must link a prebuilt XCFramework — this scenario is not covered by `sqlite3`
and may require a different code-asset emission in the hook.

**Two paths to evaluate:**

- **Primary:** `hook/build.dart` stages the ORT XCFramework and emits it as a
  `CodeAsset`; Flutter/Xcode links it during `flutter build ios`. Requires
  validating that the current Dart SDK native-assets iOS support handles
  prebuilt XCFramework linkage cleanly.
- **Fallback:** A minimal iOS-only Flutter plugin shim inside (or alongside)
  `betto_onnxrt` that declares a `Package.swift` with the SPM dependency
  (`microsoft/onnxruntime-swift-package-manager`). The Flutter tool generates
  a wrapper SPM package, resolves the XCFramework, and links it into the
  Runner target. The hook handles all other platforms as above.

Use SPM (`microsoft/onnxruntime-swift-package-manager`) in both cases — not
CocoaPods (being deprecated). Do not use `onnxruntime-mobile` (reduced opset
incompatible with BGE).

**Resolution:** Run a minimal spike — `dart build` + `flutter build ios` against
a stub `betto_onnxrt` that only declares the ORT XCFramework — before
committing to either path. This spike is the only blocking open question.

### Q2 — Prebuilt ORT artifact hosting

The build hook can download from:
- `github.com/microsoft/onnxruntime/releases` (official, public, no hosting
  cost, but subject to upstream naming changes and availability).
- `github.com/bettongia/onnxrt/releases` (own hosting: full control over
  artifacts, can publish reduced-opset builds, consistent naming regardless
  of upstream changes).

Decision affects the hook URL templates and the SHA-256 manifest location.
Own hosting is preferable long-term for reproducibility; official artifacts
are the faster starting point.

### Q3 — Reduced-opset builds

Full ORT adds roughly 20–65 MB per platform. A custom ORT build keyed to the
BGE + Magika operator sets (using ORT's operator-reduction tooling) could cut
this by a substantial fraction. This is a future size optimisation — v1 uses
full ORT — but the reduced-build CI pipeline should be scoped during the
`betto_onnxrt` repo setup so it is not forgotten.

---

## 6. References

- [Dart Hooks documentation](https://dart.dev/tools/hooks)
- [code_assets package](https://pub.dev/packages/code_assets)
- [dart-lang/native sqlite code_assets example](https://github.com/dart-lang/native/tree/main/pkgs/code_assets/example/sqlite)
- [ONNX Runtime releases](https://github.com/microsoft/onnxruntime/releases)
- [ONNX Runtime Swift Package Manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
- [ONNX Runtime reduced-operator builds](https://onnxruntime.ai/docs/reference/operators/reduced-operator-config-file.html)
- [Flutter native Swift Package Manager support](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors)
- [betto_zstd](https://github.com/bettongia/zstd) — reference for the betto_* package pattern
