// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';

/// A fault-injecting [StorageAdapter] that models power-loss durability so the
/// fsync/`syncDir` ordering of the storage engine can be tested deterministically.
///
/// The in-memory adapter cannot exercise the C2/H1/M3 durability bugs because it
/// makes `syncFile`/`syncDir` no-ops and never loses buffered data — a simulated
/// crash there only drops the lock. This adapter instead models the two
/// independent durability dimensions of a real filesystem:
///
/// 1. **File-content durability.** A write lands in a volatile "page cache"
///    ([_live]); only [syncFile] promotes that content to the durable set
///    ([_durable]). An un-synced write is lost on [crash].
/// 2. **Directory-entry durability.** Creating, renaming, or deleting a *name*
///    updates the live directory only; [syncDir] commits those name changes to
///    the durable set. A newly created file whose content was `fsync`'d but whose
///    parent directory was **not** `syncDir`'d still vanishes on [crash] — this
///    is the Linux behaviour that finding H1 depends on.
///
/// [crash] discards everything not made durable: un-synced content reverts to its
/// last durable bytes (or disappears if never synced), and un-committed
/// creations/renames/deletions are rolled back. After [crash], reads observe only
/// the durable state, exactly as a process would after power loss.
///
/// This adapter is test-only and is never shipped. It deliberately uses flat path
/// keys (no real directory objects), mirroring [MemoryStorageAdapter].
final class FaultyStorageAdapter implements StorageAdapter {
  FaultyStorageAdapter();

  /// Current, possibly-volatile content. A file is *visible* iff its path is a
  /// key here. Reads, `listFiles`, and `fileExists` all consult this map.
  final Map<String, Uint8List> _live = {};

  /// Content guaranteed to survive a [crash]. A file *durably exists* iff its
  /// path is a key here, with the durable bytes as its value.
  final Map<String, Uint8List> _durable = {};

  /// Content for which [syncFile] has been called since the last mutation. When a
  /// name is committed by [syncDir], this is the content that becomes durable.
  final Map<String, Uint8List> _syncedContent = {};

  /// Lock paths currently held by this adapter instance.
  final Set<String> _heldLocks = {};

  // ── Fault injection ─────────────────────────────────────────────────────────

  /// Simulates a power-loss crash: discards all state that was not made durable.
  ///
  /// After this call the live view equals the durable view — un-synced writes are
  /// gone, un-committed creations vanish, and un-committed deletions/renames are
  /// rolled back. Held locks are released (the process died without `close()`).
  void crash() {
    _live
      ..clear()
      ..addAll({
        for (final entry in _durable.entries)
          entry.key: Uint8List.fromList(entry.value),
      });
    _syncedContent
      ..clear()
      ..addAll({
        for (final entry in _durable.entries)
          entry.key: Uint8List.fromList(entry.value),
      });
    _heldLocks.clear();
  }

  // ── Content operations ──────────────────────────────────────────────────────

  @override
  Future<Uint8List> readFile(String path) async {
    final data = _live[path];
    if (data == null) throw StorageException('File not found', path: path);
    return Uint8List.fromList(data);
  }

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    final data = _live[path];
    if (data == null) throw StorageException('File not found', path: path);
    if (offset < 0 || offset + length > data.length) {
      throw StorageException(
        'Range [$offset, ${offset + length}) out of bounds '
        '(file length ${data.length})',
        path: path,
      );
    }
    return Uint8List.fromList(data.sublist(offset, offset + length));
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    _live[path] = Uint8List.fromList(bytes);
    // Content changed: it is no longer synced until the next syncFile.
    _syncedContent.remove(path);
  }

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    final existing = _live[path];
    if (existing == null) {
      _live[path] = Uint8List.fromList(bytes);
    } else {
      final combined = Uint8List(existing.length + bytes.length)
        ..setAll(0, existing)
        ..setAll(existing.length, bytes);
      _live[path] = combined;
    }
    // The newly appended tail is not durable until the next syncFile.
    _syncedContent.remove(path);
  }

  @override
  Future<void> syncFile(String path) async {
    final content = _live[path];
    if (content == null) return; // nothing to sync
    final snapshot = Uint8List.fromList(content);
    _syncedContent[path] = snapshot;
    // If the name is already durable, fsync makes the new content durable
    // immediately. If the name is not yet durable (a freshly created file), the
    // content waits for syncDir of the parent directory to be committed.
    if (_durable.containsKey(path)) {
      _durable[path] = snapshot;
    }
  }

  @override
  Future<void> syncDir(String dirPath) async {
    // Commit every pending name operation for direct children of [dirPath].
    final candidates = <String>{
      ..._live.keys,
      ..._durable.keys,
      ..._syncedContent.keys,
    }.where((p) => _isDirectChild(p, dirPath)).toList();

    for (final path in candidates) {
      if (_live.containsKey(path)) {
        // The name exists now → make it durable. Its durable content is the
        // last-synced content, if any; a name committed without a content fsync
        // models metadata-persisted-but-data-lost (empty bytes).
        final synced = _syncedContent[path];
        if (synced != null) {
          _durable[path] = Uint8List.fromList(synced);
        } else {
          _durable[path] ??= Uint8List(0);
        }
      } else {
        // The name was removed (delete or the source side of a rename) → commit
        // the removal.
        _durable.remove(path);
        _syncedContent.remove(path);
      }
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    _live.remove(path);
    _syncedContent.remove(path);
    // The directory entry removal is not durable until syncDir of the parent;
    // _durable retains the file so a crash before that syncDir resurrects it.
  }

  @override
  Future<bool> fileExists(String path) async => _live.containsKey(path);

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final results = <String>[];
    for (final path in _live.keys) {
      if (!path.startsWith(prefix)) continue;
      final remainder = path.substring(prefix.length);
      if (remainder.contains('/')) continue;
      if (extension != null && !remainder.endsWith(extension)) continue;
      results.add(remainder);
    }
    return results;
  }

  @override
  Future<int> fileSize(String path) async {
    final data = _live[path];
    if (data == null) throw StorageException('File not found', path: path);
    return data.length;
  }

  @override
  Future<void> renameFile(String from, String to) async {
    final data = _live.remove(from);
    if (data == null) throw StorageException('File not found', path: from);
    _live[to] = data;
    // The renamed inode carries its synced content to the new name; the
    // destination name's directory entry is not durable until syncDir. The old
    // durable bytes at [to] (e.g. the previous CURRENT) stay until then, so a
    // crash before syncDir leaves the destination at its prior durable content.
    final synced = _syncedContent.remove(from);
    if (synced != null) {
      _syncedContent[to] = synced;
    } else {
      _syncedContent.remove(to);
    }
  }

  @override
  Future<void> createDirectory(String dirPath) async {
    // No-op: flat path keys, no real directory objects.
  }

  @override
  Future<void> acquireLock(String lockPath) async {
    if (_heldLocks.contains(lockPath)) throw LockException(lockPath);
    _heldLocks.add(lockPath);
    _live[lockPath] = Uint8List(0);
  }

  @override
  Future<void> releaseLock(String lockPath) async {
    _heldLocks.remove(lockPath);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Whether [path] is a direct child of [dir] (no intervening subdirectory).
  static bool _isDirectChild(String path, String dir) {
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    if (!path.startsWith(prefix)) return false;
    return !path.substring(prefix.length).contains('/');
  }
}
