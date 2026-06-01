---
title: "§19 Platform Adaptation"
nav_order: 19
---

# §19 Platform Adaptation

## Conditional Exports

The package uses Dart conditional exports to select the correct platform adapter
at compile time. `dart.library.js_interop` is tested (not the deprecated
`dart.library.html`) for correct WASM targeting:

```dart
// packages/kmdb/lib/src/engine/platform/storage_adapter.dart
export 'storage_adapter_impl.dart'
    if (dart.library.io) 'storage_adapter_native.dart'
    if (dart.library.js_interop) 'storage_adapter_sahpool.dart';
```

## Native Platforms (iOS, Android, macOS, Windows, Linux)

- **File I/O:** `dart:io` `RandomAccessFile` for reads/writes, with `fsync` for
  durability.
- **Compression:** Zstd via `dart:ffi` to `libzstd`. Build hooks (Dart 3.10+)
  handle native compilation via `hook/build.dart` with `native_toolchain_c`.
- **File locking:** `flock()` / `LockFileEx()` on the database directory to
  prevent dual-process access.

## Web (OPFS — SAHPool)

The web storage adapter (`StorageAdapterSahPool`) routes all file I/O through a
dedicated Web Worker using the browser's Origin Private File System (OPFS) via
`FileSystemSyncAccessHandle`. This provides 3–4× better throughput than the
async File System Access API.

### Why a Worker?

`FileSystemSyncAccessHandle` — which supports direct byte-level reads and writes
without async overhead — is only available inside a dedicated Web Worker. The
main-thread Dart code communicates with the Worker via `postMessage` round-trips.
This keeps the Dart API fully async (all 14 `StorageAdapter` methods return
`Future<T>`) while the Worker executes I/O synchronously.

### Worker asset loading

The Worker JavaScript source is embedded as a `const String` in
`sahpool_worker_source.dart`. At startup `StorageAdapterSahPool`:

1. Creates a `Blob` from the const string with MIME type `text/javascript`.
2. Calls `URL.createObjectURL(blob)` to obtain a blob URL.
3. Constructs `new Worker(blobUrl)`.

This avoids any Flutter asset-bundle or `base href` dependency and works
identically under `dart compile js` and WASM builds. The only required CSP
directive beyond your app's standard policy is `worker-src blob:`.

The source `.js` file lives at
`lib/src/engine/platform/sahpool_worker.js` and the `const String` companion at
`lib/src/engine/platform/sahpool_worker_source.dart`. **These two files must be
kept in sync manually** — a build step could automate this, but manual sync is
currently required.

### Message protocol — `id`-echo correlation map

Each request from the Dart side has the shape:

```json
{ "id": <int>, "op": "<op_name>", ...args }
```

The Worker executes the operation synchronously (no `await` inside the Worker)
and posts back one of:

```json
{ "id": <int>, "ok": true, "result": <any> }
{ "id": <int>, "ok": false, "error": "<message>" }
```

The Dart adapter maintains a `Map<int, Completer>` keyed by the monotonically
increasing request `id`. A single `onmessage` handler resolves or rejects the
matching `Completer` based on the echoed `id`. There are no `MessagePort`
response channels and no `SharedArrayBuffer` (which would require
`Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` headers).

The Worker also posts `{ "ready": true }` immediately on startup (before any
request arrives). The Dart adapter awaits this message before allowing any
operations.

### Supported operations

| Worker op     | StorageAdapter method | Direction       | Notes                                  |
| ------------- | --------------------- | --------------- | -------------------------------------- |
| `readAll`     | `readFile`            | Worker → Dart   | Transfers `Uint8Array` buffer (zero-copy) |
| `read`        | `readFileRange`       | Worker → Dart   | Read at exact offset — O(length), not O(file size) |
| `write`       | `writeFile`           | Dart → Worker   | Transfers `Uint8Array` buffer (zero-copy) |
| `append`      | `appendFile`          | Dart → Worker   | `getSize()` then `write(at: size)` — true append, no read |
| `getSize`     | `fileSize`            | Worker → Dart   | Returns `number` |
| `list`        | `listFiles`           | Worker → Dart   | Optional extension filter |
| `delete`      | `deleteFile`          | —               | No-op if file missing |
| `rename`      | `renameFile`          | —               | Durability ordering enforced (see below) |
| `exists`      | `fileExists`          | Worker → Dart   | Returns `boolean` |
| `createDir`   | `createDirectory`     | —               | Creates all intermediate directories |
| `acquireLock` | `acquireLock`         | —               | Holds SAH open for session; throws on collision |
| `releaseLock` | `releaseLock`         | —               | Flushes, closes, and deletes lock file |

`syncFile` and `syncDir` are no-ops (see Durability below). `truncate` is an
internal Worker helper used by `write` and is not exposed as a Dart-level
operation.

Binary data (`Uint8Array` results from read operations) is transferred via the
structured clone transfer mechanism — `self.postMessage({ … }, [result.buffer])`
— so no copy is made across the Worker boundary in either direction.

### Per-op handle lifecycle (durability contract)

Every write-bearing Worker operation follows the **per-op handle lifecycle**:

```
open handle
  write → flush() → close handle
post response
```

Read operations follow `open → read → close`. Because each write op
flushes-and-closes the `FileSystemSyncAccessHandle` before posting its response,
the engine's fsync callers — `CurrentFile`, `WalWriter`, `ManifestWriter`,
`LsmEngine`, and `CompactionJob` — receive already-durable bytes.

This is the specific reason `syncFile(path)` and `syncDir(dirPath)` are no-ops
in `StorageAdapterSahPool`. Sync access handles buffer writes until `flush()` is
called explicitly; without the per-op flush, a no-op `syncFile` would lose data
on a tab-kill. The per-op flush gives the same guarantee: every acknowledged
write is on durable storage before the caller's `await` completes.

### Rename safety (atomic simulation)

OPFS has no native `rename()` equivalent. The Worker simulates atomic rename
with enforced durability ordering:

```
1. Read source bytes          (opReadAll)
2. Write destination bytes    (opWrite  — includes flush() in per-op lifecycle)
3. Delete source              (opDelete)
```

After step 2, the destination is fully flushed-and-closed before the source is
deleted. A crash between steps 2 and 3 leaves both files intact; a crash after
step 3 leaves only the destination. This satisfies the `CurrentFile.write`
(M3) invariant: a crash leaves either the intact source or the fully-written
destination.

### Cross-tab exclusion (single-tab contract)

`acquireLock(path)` instructs the Worker to call `createSyncAccessHandle()` on
the lock file and **hold that handle open for the session**. A
`FileSystemSyncAccessHandle` is exclusively locked by design — only one context
can hold a sync handle on any given file at a time. If another tab already holds
the handle, `createSyncAccessHandle()` throws a `DOMException`
(`NoModificationAllowedError`). The Dart adapter surfaces this as a
`LockException` with the message "database is already open in another tab."

**Single-tab-per-database is the documented contract.** Multiple tabs
accessing the same OPFS path concurrently will race for the lock; the first tab
wins and subsequent tabs receive `LockException` immediately (no retry, no
timeout).

`releaseLock(path)` flushes and closes the held handle, then deletes the lock
file. `close()` on the adapter terminates the Worker without explicitly releasing
the lock handle — the handle is released by the Worker's termination.

### Platform feature matrix

| Feature             | Native (iOS/Android/macOS/Windows/Linux) | Web (OPFS via SAHPool)           |
| :------------------ | :--------------------------------------- | :------------------------------- |
| Core LSM engine     | ✓                                        | ✓                                |
| Zstd compression    | ✓ (FFI via betto_zstd)                   | ✓ (WASM fallback: Deflate)       |
| Sync                | ✓                                        | ✓                                |
| Lexical text search | ✓                                        | ✗ (deferred)                     |
| Semantic search     | ✓ (ONNX via kmdb_inferencing)            | ✗ (deferred)                     |
| Vault               | ✓                                        | ✗ (deferred)                     |

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
  betto_zstd/              — Zstd FFI compression provider (external repo)
  |                          (native only; kmdb depends on it conditionally)
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
    if (dart.library.js_interop) 'storage_adapter_sahpool.dart';
```

`dart.library.js_interop` is tested (not the deprecated `dart.library.html`) for
correct WASM targeting. The default stub re-exports `storage_adapter_sahpool.dart`
for platforms where neither `dart:io` nor `dart:js_interop` is available —
in practice this should never be reached.
