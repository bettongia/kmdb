# KMDB Inferencing

ONNX Runtime bindings and BGE Small En v1.5 embedding model for KMDB semantic
search.

This package provides `OnnxEmbeddingModel`, an implementation of the
`EmbeddingModel` interface (defined in `package:kmdb`) that generates
384-dimensional dense vector embeddings using the
[BGE Small En v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) model. It is
the inference backend for `VecManager` in KMDB semantic and hybrid search.

## Model assets

The model binary (`bge_small.onnx`, ~127 MB) is tracked in the repository using
**Git LFS**. Supporting assets (`vocab.txt`, `tokenizer_config.json`,
`tokenizer.json`, `config.json`, `special_tokens_map.json`) are tracked
normally. All assets live under `assets/models/bge-small-en/`.

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

Pass an `OnnxEmbeddingModel` to `KmdbDatabase.open()` when using semantic or
hybrid search:

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

// Search using semantic similarity
final results = await db.collection<Book>('books').search(
  'memory management issues',
  mode: SearchMode.semantic,
);

// Always dispose the model when the database is closed
await db.close(); // calls model.dispose() automatically
```

`OnnxEmbeddingModel` can also be used directly to generate embeddings:

```dart
final (embedding, truncated) = await model.embed('The quick brown fox');
// embedding: Float32List of length 384, L2-normalised
// truncated: true if the input exceeded 510 BERT tokens
```

## Notes

- Inference runs synchronously on the calling isolate. For production Flutter
  applications, run `SyncEngine.sync()` and any delta indexing on a background
  isolate to keep the UI thread responsive.
- Field values exceeding 510 BERT tokens are truncated; the first 510 tokens are
  embedded. A truncation marker is recorded in the index.
- `KmdbDatabase.close()` calls `model.dispose()` automatically — do not call
  `dispose()` separately if the model was passed to `open()`.

## See also

- `package:kmdb` — core library; defines `EmbeddingModel`, `VecIndexDefinition`,
  and `VecManager`
- `package:kmdb_tokenizer_icu` — ICU-backed word tokenizer, accepted by
  `OnnxEmbeddingModel` as a substitute for the default `RegExpTokenizer`
- KMDB specification §22 — semantic search index structure and query path
