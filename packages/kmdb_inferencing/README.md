# KMDB Inferencing

ONNX Runtime bindings and embedding model catalog for KMDB semantic search.

This package provides:

- **`OnnxEmbeddingModel`** — an implementation of the `EmbeddingModel` interface
  (defined in `package:kmdb`) that generates dense vector embeddings using an
  ONNX model.
- **`ModelCatalog`** — an explicit allowlist of supported models with their
  catalog identifiers, embedding dimensions, and SHA-256 checksums.
- **`ModelDownloader`** — a crash-safe downloader that fetches and SHA-256-
  verifies model assets on first use, storing them in a local cache directory.
- **`ModelSpec`** — a value type describing a single catalog model entry.

## Supported models

| Model ID            | Dimensions | Status    |
| :------------------ | :--------- | :-------- |
| `bge-small-en-v1.5` | 384        | Validated |
| `bge-m3-v1.0`       | 1024       | Unvalidated† |

† Registered in the catalog but not yet tested end-to-end (deferred to v0.08).

The default model is `ModelCatalog.defaultModelId` (`'bge-small-en-v1.5'`).
Use `ModelCatalog.lookup(id)` to retrieve a `ModelSpec` by catalog identifier.

## Model assets

The default BGE Small En v1.5 binary (`bge_small.onnx`, ~127 MB) is tracked in
the repository using **Git LFS**. Supporting assets (`vocab.txt`,
`tokenizer_config.json`, `tokenizer.json`, `config.json`,
`special_tokens_map.json`) are tracked normally. All assets live under
`assets/models/bge-small-en/`.

Run `git lfs pull` after cloning to fetch the model binary before running tests
that require inference.

## Getting started

This package is part of the KMDB pub workspace and is not published to pub.dev.
Add it to your workspace `pubspec.yaml`:

```yaml
workspace:
  - packages/kmdb
  - packages/kmdb_inferencing
  # ...
```

The ONNX Runtime native library must be available on the host system. See the
[ONNX Runtime release page](https://github.com/microsoft/onnxruntime/releases)
for pre-built binaries. Construction throws `UnsupportedError` if the library or
model file cannot be loaded.

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

Use `cacheDir` to download a catalog model on first use. The model is verified
via SHA-256 and stored in the specified directory:

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
- Web platform is not supported (`dart:io` is required for ONNX Runtime FFI).

## See also

- `package:kmdb` — core library; defines `EmbeddingModel`, `VecIndexDefinition`,
  and `VecManager`
- `package:betto_icu` — ICU-backed word tokenizer (`IcuTokenizer`), accepted by
  `OnnxEmbeddingModel` as a substitute for the default `RegExpTokenizer`
- KMDB specification §22 — semantic search index structure, model lifecycle, and
  model identity tracking
