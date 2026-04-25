# Platform Adaptation

## Conditional Exports

The package uses Dart conditional exports to select the correct platform adapter
at compile time. The dart.library.js_interop condition is required for WASM
compatibility (dart.library.html is deprecated):

dart // lib/src/io/storage_adapter.dart export 'storage_adapter_stub.dart' if
(dart.library.io) 'storage_adapter_native.dart' if (dart.library.js_interop)
'storage_adapter_web.dart';

## Native Platforms (iOS, Android, macOS, Windows, Linux)

- **File I/O:** dart:io RandomAccessFile for reads/writes, with fsync for
  durability.

- **Compression:** Zstd via dart:ffi to libzstd. Build hooks (Dart 3.10+) handle
  native compilation via hook/build.dart with native_toolchain_c.

- **File locking:** flock() / LockFileEx() on database directory to prevent
  dual-process access.

- **Background isolate:** Dedicated isolate for compaction at scale. FFI
  pointers passed as raw int addresses via SendPort.

## Web (OPFS)

- **File I/O:** Origin Private File System via dart:js_interop. SAHPool VFS
  pattern for 3–4x better I/O performance.

- **Compression:** Zstd via WASM (zstandard package), falling back to Deflate
  for older browsers.

- **No file locking:** OPFS sync access handles are exclusively locked by design
  (one handle per file). Multi-tab requires a SharedWorker or BroadcastChannel
  coordination.

- **No dart:isolate on web:** Use Web Workers via isolate_manager (v5+) for
  background compaction.

### Opfs At Scale

At 100MB+ database sizes, OPFS write latency (\~10x native) becomes a
bottleneck. Dedicate a Web Worker to I/O operations, with the query layer
communicating via message passing. Use journal_mode=truncate semantics (faster
than WAL on OPFS) and increase page cache to 8–16MB.

## Package Structure

KMDB is published as a **Pub workspace**. The root `pubspec.yaml` is a workspace
coordinator only; all source code lives under `packages/`:

```
packages/
  kmdb/                    — core library (engine, query, cache, sync,
  |                           search, vault)
  |  lib/src/
  |   engine/              — LSM: WAL, memtable, SSTable, compaction, manifest
  |   cache/               — session cache, materialised views
  |   encoding/            — CBOR + compression pipeline
  |   query/               — KmdbDatabase, KmdbCollection, Filter DSL, indexes
  |   search/              — FtsManager, VecManager, HybridManager (§20–23)
  |   sync/                — SyncEngine, ConsolidationCoordinator
  |   vault/               — VaultStore, VaultGc, VaultRecovery, VaultRef (§24)
  |
  kmdb_cli/                — CLI tool (bin/, lib/, test/)
  |
  kmdb_zstd/               — Zstd FFI compression provider
  |                          (native only; kmdb depends on it conditionally)
  |
  kmdb_ui/                 — Flutter UI widgets
  |
  kmdb_lexical/            — tokenizer pipeline and English stop-word list
  |                          (RegExpTokenizer, IcuTokenizer, Snowball stemmer)
  |                          used by FtsManager (§21) and VecManager (§22)
  |
  kmdb_tokenizer_icu/      — ICU FFI word tokenizer (UAX #29; optional
  |                          substitute for RegExpTokenizer)
  |
  kmdb_inferencing/        — ONNX Runtime + BGE Small En v1.5 embedding model
  |                          used by VecManager (§22); native only
  |
  kmdb_mediatype/          — MIME-type detection by file-signature inspection
                             used by VaultStore (§24)
```

### Conditional Export Pattern

The platform adapter is selected at compile time via Dart conditional exports:

```dart
// packages/kmdb/lib/src/engine/platform/storage_adapter.dart
export 'storage_adapter_impl.dart'
    if (dart.library.io) 'storage_adapter_native.dart'
    if (dart.library.js_interop) 'storage_adapter_web.dart';
```

`dart.library.js_interop` is tested (not the deprecated `dart.library.html`) for
correct WASM targeting.

### Feature Constraints by Platform

| Feature             | Native (iOS/Android/macOS/Windows/Linux) | Web (OPFS)                 |
| :------------------ | :--------------------------------------- | :------------------------- |
| Core LSM engine     | ✓                                        | ✓                          |
| Zstd compression    | ✓ (FFI via kmdb_zstd)                    | ✓ (WASM fallback: Deflate) |
| Sync                | ✓                                        | ✓                          |
| Lexical text search | ✓                                        | ✗ (deferred)               |
| Semantic search     | ✓ (ONNX via kmdb_inferencing)            | ✗ (deferred)               |
| Vault               | ✓                                        | ✗ (deferred)               |
