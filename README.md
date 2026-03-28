A Local-First Document Database for Dart & Flutter

KMDB is a local-first document database for Dart and Flutter applications
targeting mobile, desktop, and web platforms. It provides a typed, reactive
query API over a key-value storage engine, with multi-device sync via commodity
cloud storage (Google Drive, iCloud) without requiring a central server.

The storage layer is a Log-Structured Merge Tree (LSM) with a write-ahead log
(WAL), in-memory memtable, and immutable Sorted String Table (SSTable) files.
This architecture was chosen specifically because immutable SSTables serve as
the natural sync unit for cloud storage — file creation is atomic in cloud
storage, file mutation is not. This sync-safety property is a first-class
architectural requirement, not an incidental benefit.

The query layer provides a typed collection API with lazy evaluation, a
composable filter DSL supporting nested field paths, and reactive watch()
streams with debounced re-execution. Documents are serialized via a thin codec
bridge to freezed/json_serializable, with UUIDv7 keys providing time-ordered
insertion and index locality.

## Features

TODO: List what your package can do. Maybe include images, gifs, or videos.

## Getting started

TODO: List prerequisites and provide or point to information on how to start
using the package.

## Usage

TODO: Include short and useful examples for package users. Add longer examples
to `/example` folder.

```dart
const like = 'sample';
```

## Additional information

Refer to [docs](docs/index.md).
