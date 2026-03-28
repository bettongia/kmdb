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

```
kmdb/

 lib/
  kmdb.dart                    # Public export
  src/
   engine/                     # Platform-agnostic
    btree/
    storage/
     page_manager.dart
     superblock.dart
     compressor.dart
    transaction/
     commit.dart
     recovery.dart
    memtable/
     skip_list.dart
    sstable/
     writer.dart
     reader.dart
     bloom_filter.dart
    compaction/
     merge_iterator.dart
     compaction_job.dart
    sync/
     hlc.dart
     sync_engine.dart
     highwater.dart
    api/
     kv_store.dart
  query/                      # Query layer
   collection.dart
   query.dart
   filter.dart
   field_path.dart
   codec.dart
   watcher.dart
  io/                          # Platform adapters storage_adapter.dart
   storage_adapter_native.dart # Abstract + conditional export
   storage_adapter_web.dart
   storage_adapter_stub.dart
   cloud/
    cloud_adapter.dart      # Abstract google_drive_adapter.dart icloud_adapter.dart
hook/
 build.dart                    # Native build hooks
```
