# Extract `betto_onnxrt` — Standalone ONNX Runtime Package

**Status**: Open

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
`github.com/bettongia/onnxrt`, following the `betto_zstd` convention), then
update `kmdb_inferencing` to depend on it.

See [docs/proposals/betto_onnxrt.md](../proposals/betto_onnxrt.md) for the
full proposal, rationale, and platform binary acquisition table.

## Open questions

- [ ] **Q1 — iOS XCFramework via native assets (spike required — blocking).**
      Can `hook/build.dart` stage the ORT XCFramework
      (`microsoft/onnxruntime-swift-package-manager`, `onnxruntime-c` variant)
      and emit it as a `CodeAsset` that Flutter/Xcode links during
      `flutter build ios`? Or does iOS require the fallback: a minimal Flutter
      plugin shim with a `Package.swift` SPM dependency? A spike against a stub
      `betto_onnxrt` package (no real ORT logic, just the hook + a dummy
      XCFramework) must be run before the Stage A checklist is finalised. The
      choice determines: (a) the hook implementation for iOS in Stage A Phase 2,
      and (b) whether `betto_onnxrt` is a pure Dart package or also ships a
      Flutter plugin shim. **Do not use `onnxruntime-mobile`** (reduced opset,
      incompatible with BGE). **Do not use CocoaPods** (being deprecated).
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

## Investigation

### Current `kmdb_inferencing` ORT surface

| File | Responsibility |
|---|---|
| `lib/src/ort_library.dart` | Loads the ORT dynamic library at runtime: first checks `<executableDir>/assets/models/…`; falls back to downloading the dylib from a hard-coded URL. iOS hits the generic catch-all `UnsupportedError` (~line 68 and ~132). This file is the primary replacement target. |
| `lib/src/ort_session.dart` | FFI binding to `OrtApi` via numeric vtable slot indices; `OrtSession` wraps `CreateSession`/`Run`/`ReleaseSession`. Also owns `hiddenDim` (now sourced from `ModelSpec.embeddingDimensions` post-PR #39) and the token-embedding mean-pool logic. Moves to `betto_onnxrt` (the OrtApi FFI portion) and stays in `kmdb_inferencing` (the embedding/pooling logic). |
| `lib/src/embedding_model.dart` | `OnnxEmbeddingModel` — calls `OrtSession.run()`, pools token embeddings via `MathUtils.meanPool`, SQ8-quantises. KMDB-specific; stays in `kmdb_inferencing`. |
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

### Per-platform ORT binary acquisition

| Platform | Approach |
|---|---|
| macOS | Hook downloads `onnxruntime-osx-{arch}-{ver}.tgz` from GitHub Releases; extracts dylib; emits `CodeAsset`. Replaces runtime download in `ort_library.dart`. |
| Linux | Hook downloads `onnxruntime-linux-{arch}-{ver}.tgz`; emits `libonnxruntime.so`. |
| Windows | Hook downloads `onnxruntime-win-{arch}-{ver}.zip`; emits `onnxruntime.dll`. |
| iOS | **Pending Q1 spike.** Primary path: hook stages ORT XCFramework, emits as `CodeAsset`. Fallback: minimal Flutter plugin shim with `Package.swift` SPM dependency. Not `onnxruntime-mobile`; not CocoaPods. |
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
- `lib/src/ort_session.dart` — OrtApi FFI binding moves to `betto_onnxrt`; pooling/
  embedding logic moves inline into `OnnxEmbeddingModel` or a private helper.
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

1. **Q1 resolved**: the iOS XCFramework spike result is recorded; the hook iOS
   branch (or plugin shim path) is confirmed working.
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

- [ ] Create a minimal stub `betto_onnxrt` package (no real ORT logic): just a
      `hook/build.dart` that attempts to stage a placeholder XCFramework and
      emit it as a `CodeAsset`.
- [ ] Run `dart build` against the stub to confirm macOS/Linux hook execution.
- [ ] Run `flutter build ios` against a minimal test Flutter app that declares
      `betto_onnxrt` as a dependency to confirm XCFramework linkage via
      native assets.
- [ ] If native-assets XCFramework linkage succeeds: proceed with the primary
      path (hook stages ORT XCFramework). Record verdict in Q1 above.
- [ ] If native-assets XCFramework linkage fails: implement the fallback plugin
      shim (`Package.swift` SPM dependency pointing to
      `microsoft/onnxruntime-swift-package-manager`). Record verdict in Q1.
- [ ] Document the spike outcome and chosen iOS path in this plan before
      proceeding to Phase 2.

#### Phase 2 — Package scaffold and build hook

- [ ] Create the directory `/Users/gonk/development/bettongia/onnxrt/` and
      initialise a git repository.
- [ ] Write `VERSION_ONNX` file (e.g. `v1.22.0` — match the version currently
      used by `kmdb_inferencing`).
- [ ] Write `pubspec.yaml`:
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
    ffi: ^2.2.0
    native_assets_api: ^0.0.1
  dev_dependencies:
    lints: ^6.0.0
    test: ^1.25.6
    code_assets: ^0.0.1
  ```
- [ ] Write `analysis_options.yaml`.
- [ ] Add Apache 2.0 `LICENSE` file.
- [ ] Write `hook/build.dart`:
  - Read `VERSION_ONNX` from package root.
  - Per build target OS/architecture, construct the GitHub Releases download URL.
  - Verify existing cached artifact SHA-256; skip download if valid.
  - Download to temp path; verify SHA-256; atomic-rename on success.
  - Emit the library as a `CodeAsset`.
  - iOS: implement the Q1-resolved path (native-assets XCFramework or plugin shim).
- [ ] Write `tool/generate_versions.dart` to write
      `lib/src/generated/versions.g.dart` from `VERSION_ONNX`.
- [ ] Run `dart run tool/generate_versions.dart`.
- [ ] Add Apache 2.0 license header to all Dart files (use `header_template.txt`
      format).

#### Phase 3 — Core API implementation

- [ ] Implement `lib/src/ort_api.dart` — versioned vtable-slot `OrtApi` FFI
      binding. Port the binding from `kmdb_inferencing/lib/src/ort_session.dart`
      and annotate each slot index with the ORT API symbol name it corresponds
      to, so version drift is detectable.
- [ ] Implement `lib/src/runtime.dart` — `OnnxRuntime.load()` opens the
      code-asset library and initialises the `OrtApi`.
- [ ] Implement `lib/src/session.dart` — generalised `OnnxSession.run()` (not
      BGE-shaped: arbitrary input/output names and element types).
- [ ] Implement `lib/src/tensor.dart` — `OnnxTensor`, `OnnxElementType`.
- [ ] Implement `lib/src/allowlist_provider.dart` — `AllowlistProvider`
      interface.
- [ ] Implement `lib/src/model_spec.dart` — generic `ModelSpec` (id, files map,
      meta map), `ModelFile`.
- [ ] Implement `lib/src/model_downloader.dart` — `ModelDownloader` with
      `AllowlistProvider` gate, SHA-256 verification, temp-file + atomic-rename
      crash safety, `ResolvedModel` return type. Mirror the write discipline from
      the existing `kmdb_inferencing` `ModelDownloader`.
- [ ] Write `lib/betto_onnxrt.dart` barrel exporting all public types.
- [ ] Ensure all public classes, methods, and properties have doc comments.
- [ ] Ensure license header on every source file.

#### Phase 4 — Tests

- [ ] Unit tests for `OnnxSession` using a tiny valid `.onnx` fixture (include a
      minimal ONNX model in `test/fixtures/`; the BGE model is too large for CI).
- [ ] Unit tests for `ModelDownloader` with mock HTTP (partial download, corrupt
      download, checksum mismatch + retry, temp-file-then-rename, present-file
      short-circuit, allowlist rejection). No real network download in the suite.
- [ ] Hook smoke test: confirm `dart build` completes on the CI runner without
      errors and the code asset is staged.
- [ ] Tests that cannot run in CI (real-platform binary download, full iOS build)
      are documented as entries in `docs/spec/28_release_checklist.md`.
- [ ] Run `dart test` from `/Users/gonk/development/bettongia/onnxrt/` and
      confirm all tests pass.
- [ ] Commit all files, create the GitHub repo at `github.com/bettongia/onnxrt`,
      push, and open a PR.

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
- [ ] Replace the OrtApi FFI binding in `lib/src/ort_session.dart` with
      `OnnxSession` from `betto_onnxrt`. Retain the embedding/mean-pool logic
      in `OnnxEmbeddingModel` (move it inline or to a private helper). Delete
      `ort_session.dart` (or reduce it to a thin `OnnxEmbeddingModel`-only file
      if the session logic was entangled — in that case rename it
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
