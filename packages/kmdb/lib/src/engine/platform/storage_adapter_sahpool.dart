// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// coverage:ignore-file
// This file is compiled only when `dart.library.js_interop` is available
// (i.e. on web targets). It must not import `dart:io`.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'sahpool_worker_source.dart';
import 'storage_adapter_interface.dart';

// ── JS interop helpers ────────────────────────────────────────────────────────

/// Extension type for reading fields from a Worker response.
///
/// Worker responses have the shape:
/// - Ready notification: `{ ready: true }`
/// - Success: `{ id: number, ok: true, result: any }`
/// - Failure: `{ id: number, ok: false, error: string }`
@JS()
extension type _WorkerResponse._(JSObject _) implements JSObject {
  /// The monotonic request id echoed by the Worker.
  external double? get id;

  /// Non-null `true` on the initial ready notification.
  external bool? get ready;

  /// `true` if the operation succeeded.
  external bool? get ok;

  /// Operation result — a `Uint8Array`, `string[]`, `boolean`, `number`,
  /// or `null`, depending on the operation.
  external JSAny? get result;

  /// Error message when [ok] is `false`.
  external JSString? get error;
}

// ─────────────────────────────────────────────────────────────────────────────

/// Web [StorageAdapter] backed by the browser's Origin Private File System
/// (OPFS) using `FileSystemSyncAccessHandle` inside a dedicated Web Worker.
///
/// ## Why a Worker?
///
/// `FileSystemSyncAccessHandle` — which supports direct byte-level reads and
/// writes without async overhead — is only available inside a dedicated Web
/// Worker. The `StorageAdapterSahPool` owns the Worker lifecycle: it spawns
/// the Worker on first use and terminates it on [close].
///
/// ## Performance
///
/// The sync-handle approach provides 3–4× better throughput than the async
/// File System Access API used by the previous `StorageAdapterWeb`:
///
/// - `readFileRange` reads exactly the requested bytes at the given offset
///   (O(length) not O(file size)).
/// - `appendFile` uses `getSize()` then `write(at: size)` — true append
///   without read-concat-rewrite.
///
/// ## Durability contract
///
/// Every write-bearing Worker operation follows the **per-op handle lifecycle**:
/// open → write → `flush()` → close. Because each write flushes-and-closes
/// before the response is posted, [syncFile] and [syncDir] are no-ops — the
/// preceding write has already provided the durability guarantee. This
/// satisfies the v0.02.01 fsync-ordering callers (`CurrentFile`, `WalWriter`,
/// `ManifestWriter`, `LsmEngine`, `CompactionJob`).
///
/// Note: this is a different rationale from the old `StorageAdapterWeb`, which
/// relied on OPFS Writable Streams being durable on `close()`. Sync access
/// handles buffer writes until `flush()` is called explicitly — without the
/// per-op flush the no-op syncFile would be unsafe.
///
/// ## Cross-tab exclusion
///
/// [acquireLock] instructs the Worker to call `createSyncAccessHandle()` on
/// the lock file and hold that handle open for the session. A
/// `FileSystemSyncAccessHandle` is exclusive; if another tab already holds it,
/// the call throws and the adapter surfaces [LockException] with the message
/// "database is already open in another tab." Single-tab-per-database is the
/// documented contract.
///
/// ## Worker asset loading
///
/// The Worker JS is embedded as [kSahPoolWorkerSource] — a `const String` in
/// `sahpool_worker_source.dart`. At startup a `Blob` is built from the string
/// and `URL.createObjectURL()` produces the Worker's script URL. This avoids
/// any Flutter asset-bundle or `base href` dependency and works identically
/// under `dart compile js` and WASM builds. No CSP beyond `worker-src blob:`
/// is required.
///
/// ## Message protocol
///
/// Each request is `{ id, op, ...args }` where `id` is a monotonically
/// increasing integer. The Worker echoes the `id` in its response:
/// `{ id, ok: true, result }` or `{ id, ok: false, error }`. A single
/// `onmessage` handler on the Dart side resolves the matching [Completer]
/// from a `Map<int, Completer>` keyed by `id`. No `MessagePort` response
/// channels are used.
///
/// ## Path conventions
///
/// Paths like `/db/sst/foo.sst` are split on `/`, empty segments are dropped,
/// and each non-final segment is navigated/created as a nested OPFS directory.
/// The final segment is the filename. All paths should be absolute.
///
/// See also: spec §19.
final class StorageAdapterSahPool implements StorageAdapter {
  StorageAdapterSahPool();

  // ── Worker lifecycle ─────────────────────────────────────────────────────

  web.Worker? _worker;
  String? _blobUrl;

  // Completer fulfilled when the Worker posts its initial `{ ready: true }`
  // message. All operations await this before sending their first message.
  Completer<void>? _readyCompleter;

  // Monotonically increasing request id counter.
  int _nextId = 0;

  // Pending requests keyed by id. Each value is a Completer<JSAny?> that
  // resolves with the operation's `result` field or rejects with a
  // [StorageException].
  final Map<int, Completer<JSAny?>> _pending = {};

  /// Ensures the Worker is spawned and ready.
  ///
  /// Safe to call concurrently — subsequent calls wait on the same
  /// [_readyCompleter] rather than spawning a second Worker.
  Future<void> _ensureWorker() async {
    if (_readyCompleter != null) {
      await _readyCompleter!.future;
      return;
    }

    _readyCompleter = Completer<void>();

    // Build a Blob from the embedded Worker source and obtain a blob URL so
    // the Worker can be spawned without any asset-bundle or base-href lookup.
    final jsSource = kSahPoolWorkerSource.toJS;
    final blobParts = [jsSource as web.BlobPart].toJS;
    final blob = web.Blob(
      blobParts,
      web.BlobPropertyBag(type: 'text/javascript'),
    );
    _blobUrl = web.URL.createObjectURL(blob);

    _worker = web.Worker(_blobUrl!.toJS);

    // A single onmessage handler dispatches all responses by echoed id.
    _worker!.onmessage = (web.MessageEvent event) {
      final data = event.data;
      if (data == null) return;
      // Use as-cast since data is structurally a _WorkerResponse.
      final resp = data as _WorkerResponse;

      // The initial `{ ready: true }` message has no `id` field.
      if (resp.ready == true) {
        if (!(_readyCompleter!.isCompleted)) {
          _readyCompleter!.complete();
        }
        return;
      }

      final rawId = resp.id;
      if (rawId == null) return;
      final id = rawId.toInt();

      final completer = _pending.remove(id);
      if (completer == null) return; // Stale response — ignore.

      if (resp.ok == true) {
        completer.complete(resp.result);
      } else {
        final msg = resp.error?.toDart ?? 'Unknown Worker error';
        completer.completeError(StorageException(msg));
      }
    }.toJS;

    _worker!.onerror = (JSObject event) {
      // Reject all pending requests on unrecoverable Worker error.
      final snapshot = Map<int, Completer<JSAny?>>.from(_pending);
      _pending.clear();
      for (final c in snapshot.values) {
        if (!c.isCompleted) {
          c.completeError(StorageException('Worker error'));
        }
      }
      if (!(_readyCompleter!.isCompleted)) {
        _readyCompleter!.completeError(
          StorageException('Worker failed to start'),
        );
      }
    }.toJS;

    await _readyCompleter!.future;
  }

  /// Sends an operation message to the Worker and awaits its response.
  ///
  /// [msgMap] must contain at least `'op'`. The `'id'` field is added by this
  /// method. If [transferBytes] is provided, the underlying buffer is
  /// transferred (zero-copy) to the Worker.
  ///
  /// Throws [StorageException] if the Worker returns `ok: false`.
  Future<JSAny?> _send(
    Map<String, Object?> msgMap, {
    Uint8List? transferBytes,
  }) async {
    await _ensureWorker();

    final id = _nextId++;
    final completer = Completer<JSAny?>();
    _pending[id] = completer;

    // Add the id to the message map and convert to a JS object.
    final fullMap = {'id': id, ...msgMap};
    final jsMsg = fullMap.jsify()! as JSObject;

    if (transferBytes != null) {
      // Transfer the underlying ArrayBuffer to the Worker without copying.
      // Attach the bytes to the message object as a 'bytes' property using
      // setProperty from dart:js_interop_unsafe.
      final jsBytes = transferBytes.toJS;
      jsMsg.setProperty('bytes'.toJS, jsBytes);
      // Retrieve the backing ArrayBuffer via unsafe property access since
      // JSTypedArray doesn't expose .buffer directly in dart:js_interop.
      final buffer = jsBytes.getProperty<JSArrayBuffer>('buffer'.toJS);
      final transferList = [buffer].toJS;
      _worker!.postMessage(jsMsg, transferList);
    } else {
      _worker!.postMessage(jsMsg);
    }

    return completer.future;
  }

  // ── StorageAdapter ────────────────────────────────────────────────────────

  @override
  Future<Uint8List> readFile(String path) async {
    final result = await _send({'op': 'readAll', 'path': path});
    return _jsResultToUint8List(result, path);
  }

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    // The Worker reads exactly [length] bytes starting at [offset] using a
    // sync access handle's read(buf, {at: offset}) — O(length), not
    // O(file size). This is the primary performance improvement over the old
    // StorageAdapterWeb which read the whole file then sliced in Dart.
    final result = await _send({
      'op': 'read',
      'path': path,
      'offset': offset,
      'length': length,
    });
    return _jsResultToUint8List(result, path);
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    await _send({
      'op': 'write',
      'path': path,
      'offset': 0,
    }, transferBytes: bytes);
  }

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    // The Worker uses getSize() then write(at: size) — true append using sync
    // access handles without read-concat-rewrite.
    await _send({'op': 'append', 'path': path}, transferBytes: bytes);
  }

  /// No-op.
  ///
  /// The per-op handle lifecycle (open → write → flush() → close) already
  /// provides durability: every write op flushes-and-closes the sync access
  /// handle before posting its response. By the time this method is called
  /// by `WalWriter`, `ManifestWriter`, `CurrentFile`, `LsmEngine`, or
  /// `CompactionJob`, the preceding write has already been flushed to
  /// durable storage.
  ///
  /// This is the SAH-specific reason syncFile is a no-op, distinct from the
  /// old `StorageAdapterWeb` where the Writable Stream API provided durability
  /// on `close()`. Sync access handles buffer writes until `flush()` is called
  /// explicitly — without the per-op flush the no-op would be unsafe.
  @override
  Future<void> syncFile(String path) async {
    // Intentional no-op — durability already provided by per-op SAH flush.
  }

  /// No-op.
  ///
  /// OPFS has no directory fsync primitive. The per-op handle lifecycle
  /// satisfies the durability ordering that syncDir callers expect on native
  /// Linux (where it guards against directory entries not being flushed after a
  /// new file is created). No equivalent risk exists on OPFS because file
  /// creation visibility is part of the same origin-scoped OPFS namespace.
  @override
  Future<void> syncDir(String dirPath) async {
    // Intentional no-op — no directory fsync primitive in OPFS.
  }

  @override
  Future<void> deleteFile(String path) async {
    await _send({'op': 'delete', 'path': path});
  }

  @override
  Future<bool> fileExists(String path) async {
    final result = await _send({'op': 'exists', 'path': path});
    final dartVal = result?.dartify();
    return dartVal as bool? ?? false;
  }

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) async {
    final msg = <String, Object?>{'op': 'list', 'dirPath': dirPath};
    if (extension != null) msg['extension'] = extension;
    final result = await _send(msg);
    if (result == null) return const [];
    final dartVal = result.dartify();
    if (dartVal is List) return List<String>.from(dartVal);
    return const [];
  }

  @override
  Future<int> fileSize(String path) async {
    final result = await _send({'op': 'getSize', 'path': path});
    final dartVal = result?.dartify();
    if (dartVal is num) return dartVal.toInt();
    throw StorageException('Unexpected size result from Worker', path: path);
  }

  @override
  Future<void> renameFile(String from, String to) async {
    // The Worker enforces durability ordering: write dest → flush dest →
    // close dest → delete source. This satisfies the CurrentFile.write
    // invariant (M3): the destination is fully flushed before the source is
    // removed, so a crash leaves either the intact source or the fully-written
    // destination.
    await _send({'op': 'rename', 'from': from, 'to': to});
  }

  @override
  Future<void> createDirectory(String dirPath) async {
    // OPFS directories are created lazily on demand by write operations.
    // The Worker exposes an explicit createDir op for callers that need to
    // ensure the directory chain exists (e.g. LsmEngine creating sst/).
    await _send({'op': 'createDir', 'path': dirPath});
  }

  @override
  Future<void> acquireLock(String lockPath) async {
    try {
      await _send({'op': 'acquireLock', 'path': lockPath});
    } on StorageException {
      // A failed acquireLock (Worker error) surfaces as LockException —
      // the exclusive SAH is already held by another tab.
      throw LockException(
        lockPath,
        message: 'database is already open in another tab',
      );
    }
  }

  @override
  Future<void> releaseLock(String lockPath) async {
    await _send({'op': 'releaseLock', 'path': lockPath});
  }

  /// Terminates the Worker and revokes the blob URL.
  ///
  /// After this call the adapter is no longer usable. Callers should call
  /// [releaseLock] before [close] if a lock was acquired; [close] does not
  /// flush the lock handle.
  Future<void> close() async {
    _worker?.terminate();
    _worker = null;
    if (_blobUrl != null) {
      web.URL.revokeObjectURL(_blobUrl!);
      _blobUrl = null;
    }
    // Reject all still-pending requests with a meaningful error.
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StorageException('Adapter closed'));
      }
    }
    _pending.clear();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Converts a Worker result [JSAny?] to a [Uint8List].
  ///
  /// The Worker transfers `Uint8Array` results, so [result] is a [JSUint8Array]
  /// whose underlying buffer is owned by the Dart side after the transfer.
  Uint8List _jsResultToUint8List(JSAny? result, String path) {
    if (result == null) {
      throw StorageException('File not found', path: path);
    }
    if (result.isA<JSUint8Array>()) {
      return (result as JSUint8Array).toDart;
    }
    throw StorageException('Unexpected result type from Worker', path: path);
  }
}
