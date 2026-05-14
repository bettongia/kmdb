# kmdb

A local-first document database for Dart and Flutter.

KMDB provides a typed, reactive query API over a Log-Structured Merge Tree (LSM)
storage engine, with multi-device sync via commodity cloud storage (Google
Drive, iCloud) — no central server required. The architecture treats immutable
SSTables as the natural sync unit: file creation is atomic in cloud storage,
file mutation is not. Sync-safety is a first-class architectural requirement,
not an incidental benefit.

This is the **core** library package. See the [project README](../../README.md)
for the full feature list, design notes, and worked examples, and the
[specification](../../docs/spec/) for the authoritative protocol details.

## Features

- **LSM-Tree storage** with WAL, memtable, and immutable SSTables.
- **Reactive queries** via `KmdbCollection.watch()` with debounced re-execution.
- **Typed documents** through a thin `KmdbCodec<T>` bridge.
- **Filter DSL** with nested dot-paths, array fan-out, and boolean composition.
- **Secondary indexes** with lazy build and live maintenance.
- **Cloud sync** with Last-Write-Wins resolution via HLC timestamps.
- **Cache layer** with namespace-generation invalidation and persisted views.
- **Full-text search** — BM25 lexical, BGE-Small-En-v1.5 semantic, and RRF
  hybrid modes via `KmdbCollection.search()`.
- **Vault** — content-addressable blob store with ref-counted GC.
- **Collection schemas** — optional JSON Schema validation as an admission gate.
- **UUIDv7 keys** — time-ordered identifiers with index locality.

## Installation

```yaml
dependencies:
  kmdb: ^1.0.0
```

```bash
dart pub get
```

## Getting started

```dart
import 'package:kmdb/kmdb.dart';

final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: StorageAdapterNative(),
);

final tasks = db.collection(name: 'tasks', codec: TaskCodec());

// Write
await tasks.insert(Task(title: 'Buy milk'));

// Query
final open = await tasks
    .where(Filter.eq('done', false))
    .orderBy('title')
    .get();

// Watch
tasks
    .where(Filter.eq('done', false))
    .watch()
    .listen((results) => print('open tasks: ${results.length}'));
```

A complete worked example, including codec definition, indexes, and reactive
streams, is in the [top-level README](../../README.md#usage) and the
[`example/`](example/) directory.

## API surface

The primary API lives in `package:kmdb/kmdb.dart`. The diagnostic-only
`package:kmdb/kmdb_analysis.dart` sub-library exposes storage-engine internals
(SSTable readers, footers, bloom filters) for tooling such as `kmdb util`. The
analysis sub-library has **no backwards-compatibility guarantee** beyond the
package's own SemVer commitments.

## Platform support

| Platform                       | Status                                                                                 |
| :----------------------------- | :------------------------------------------------------------------------------------- |
| macOS, Linux, Windows (native) | Full support                                                                           |
| iOS, Android (Flutter)         | Full support                                                                           |
| Web (Wasm/JS)                  | Read-only against native-written stores; Zstd values throw `UnsupportedError` (see §5) |

## Documentation

- [Project README](../../README.md) — overview and worked examples.
- [Specification](../../docs/spec/) — Pandoc-rendered authoritative spec.
- API reference — generated from doc comments via `dart doc`.

## License

Apache-2.0. See [LICENSE](LICENSE).
