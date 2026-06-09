# KMDB Inferencing

ONNX Runtime bindings and embedding model catalog for KMDB semantic search.

This package provides:

- **`OnnxEmbeddingModel`** — an implementation of the `EmbeddingModel` interface
  (defined in `package:kmdb`) that generates dense vector embeddings using an
  ONNX model via the `betto_onnxrt` runtime.
- **`ModelCatalog`** — an explicit allowlist of supported models implementing
  `AllowlistProvider` from `betto_onnxrt`.
- **`ModelDownloader`** (from `betto_onnxrt`) — a crash-safe downloader that
  fetches and SHA-256-verifies model assets on first use, storing them in a local
  cache directory.
- **`ModelSpec`** (from `betto_onnxrt`) — a generic value type describing a
  downloadable model: stable `id`, a named `files` map, and a `meta` map.

## Supported models

| Model ID            | Dimensions | Status    |
| :------------------ | :--------- | :-------- |
| `bge-small-en-v1.5` | 384        | Validated |
| `bge-m3-v1.0`       | 1024       | Unvalidated† |

† Registered in the catalog but not yet tested end-to-end (deferred to v0.08).

The default model is `ModelCatalog.defaultModelId` (`'bge-small-en-v1.5'`).
Use `ModelCatalog.lookup(id)` to retrieve a `ModelSpec` by catalog identifier.
The model's embedding dimension is stored in `spec.meta['dimensions'] as int`.

## ORT binary acquisition

The ONNX Runtime native library is **staged at build time** by the
`betto_onnxrt` native-assets build hook (`hook/build.dart` in the
[`betto_onnxrt`](https://github.com/bettongia/onnxrt) package). The hook
downloads the platform-appropriate ORT binary from the official Microsoft ORT
GitHub Releases, verifies its SHA-256, and registers it as a `CodeAsset` with
the Dart build system.

This replaces the old `ort_library.dart` runtime-download mechanism that:
- stalled on first run while downloading ~80 MB
- violated App Store policies on iOS (downloading executable code at runtime)
- had no checksum verification

**iOS:** The ORT iOS XCFramework is a static `ar archive`; Flutter's
native-assets system enforces dynamic link mode and rejects it. The hook iOS
branch logs a warning and emits no `CodeAsset`. `OnnxRuntime.load()` will throw
`UnsupportedError` on iOS until an SPM plugin shim is implemented (tracked in
the `betto_onnxrt` repository).

## Model assets

The default BGE Small En v1.5 binary (`bge_small.onnx`, ~127 MB) is tracked in
the repository using **Git LFS**. Supporting assets (`vocab.txt`,
`tokenizer_config.json`, etc.) are tracked normally. All assets live under
`assets/models/bge-small-en/`.

Run `git lfs pull` after cloning to fetch the model binary before running tests
that require inference.

## Getting started

This package is part of the KMDB pub workspace and is not published to pub.dev.
The `betto_onnxrt` dependency is wired via a `dependency_overrides` git-ref in
the workspace root `pubspec.yaml`:

```yaml
dependency_overrides:
  betto_onnxrt:
    git: git@github.com:bettongia/onnxrt.git
```

Run `dart pub get` from the workspace root to resolve all dependencies.

## Usage

### Default model (bundled LFS asset)

Pass an `OnnxEmbeddingModel` to `KmdbDatabase.open()` when using semantic or
hybrid search. No network access required — uses the bundled LFS asset:

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_inferencing/kmdb_inferencing.dart';

final model = await OnnxEmbeddingModel.load();

final db = await KmdbDatabase.open(
  store,
  vecIndexes: [
    VecIndexDefinition(collection: 'books', field: 'description'),
  ],
  embeddingModel: model,
);

// Always dispose the model when the database is closed
await db.close(); // calls model.dispose() automatically
```

### Download-on-demand (catalog model + cache dir)

Use `cacheDir` to download a catalog model on first use. The `ModelCatalog`
allowlist gates which models may be downloaded. The model is verified via
SHA-256 and stored in the specified directory:

```dart
import 'package:kmdb_inferencing/kmdb_inferencing.dart';

final spec = ModelCatalog.lookup('bge-small-en-v1.5');
final model = await OnnxEmbeddingModel.load(
  spec: spec,
  cacheDir: '/path/to/model/cache',
  onProgress: (received, total) {
    print('Downloading: ${received ~/ 1024} / ${total ~/ 1024} KB');
  },
);
```

### Using ModelDownloader directly

`ModelDownloader` (from `betto_onnxrt`) can be used to download model files
without loading the ORT session. Pass `allowlist: ModelCatalog()` to restrict
downloads to catalog-registered models:

```dart
import 'package:kmdb_inferencing/kmdb_inferencing.dart';

final downloader = ModelDownloader(allowlist: ModelCatalog());
final resolved = await downloader.ensure(
  ModelCatalog.lookup('bge-small-en-v1.5'),
  cacheDir: '/path/to/cache',
);
// resolved.filePaths['onnx'] → '/path/to/cache/bge-small-en-v1.5/model.onnx'
// resolved.filePaths['vocab'] → '/path/to/cache/bge-small-en-v1.5/vocab.txt'
```

### Direct embedding (advanced)

`OnnxEmbeddingModel` can also be used directly to generate embeddings:

```dart
final (embedding, truncated) = await model.embed('The quick brown fox');
// embedding: Float32List (D-dimensional, L2-normalised)
// truncated: true if the input exceeded 510 BERT tokens
```

## Model identity and index rebuild

Every `$vec:` index records the catalog ID of the model that built it. When the
database is reopened with a different `modelId`, `VecManager` detects the
mismatch and marks the affected indexes `stale`. The indexes are rebuilt lazily
on the next `search()` call, or immediately by calling `KmdbDatabase.reindex()`
(or the CLI command `kmdb <db> reindex`).

## Notes

- Inference runs synchronously on the calling isolate. For production Flutter
  applications, run delta indexing on a background isolate to keep the UI thread
  responsive.
- Field values exceeding 510 BERT tokens are truncated; the first 510 tokens are
  embedded. A truncation marker is recorded in the index.
- `KmdbDatabase.close()` calls `model.dispose()` automatically — do not call
  `dispose()` separately if the model was passed to `open()`.
- Web platform is not supported (`dart:io` is required for ORT FFI).
- iOS is not yet supported (SPM plugin shim pending in `betto_onnxrt`).

## See also

- `package:betto_onnxrt` — ORT runtime, `OnnxSession`, `ModelDownloader`,
  `ModelSpec`, `AllowlistProvider` (https://github.com/bettongia/onnxrt)
- `package:kmdb` — core library; defines `EmbeddingModel`, `VecIndexDefinition`,
  and `VecManager`
- `package:betto_icu` — ICU-backed word tokenizer (`IcuTokenizer`), accepted by
  `OnnxEmbeddingModel` as a substitute for the default `RegExpTokenizer`
- KMDB specification §22 — semantic search index structure, model lifecycle, and
  model identity tracking
